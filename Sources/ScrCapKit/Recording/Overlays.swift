import AppKit
import SwiftUI

// MARK: - Area selection

/// Full-screen overlay to drag out the area to record. Returns the rect in screen points
/// (AppKit coordinates, origin bottom-left), or nil if cancelled with Esc.
@MainActor
enum AreaSelector {
    private static var window: NSWindow?
    private static var continuation: CheckedContinuation<CGRect?, Never>?

    static func select(on screen: NSScreen) async -> CGRect? {
        finish(nil)
        return await withCheckedContinuation { c in
            continuation = c
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onDone = { local in
                finish(local.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) })
            }
            w.contentView = view
            w.setFrame(screen.frame, display: true)
            window = w
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(view)
            NSCursor.crosshair.push()
        }
    }

    /// Closes the overlay as if the user pressed Esc.
    static func cancel() { finish(nil) }

    private static func finish(_ rect: CGRect?) {
        if window != nil { NSCursor.pop() }
        window?.orderOut(nil)
        window = nil
        continuation?.resume(returning: rect)
        continuation = nil
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        var onDone: ((CGRect?) -> Void)?
        private var start: NSPoint?
        private var current: NSPoint?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var selection: NSRect? {
            guard let start, let current else { return nil }
            return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(start.x - current.x), height: abs(start.y - current.y)).integral
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            if let sel = selection {
                NSColor.clear.setFill()
                sel.fill(using: .copy)
                let border = NSBezierPath(rect: sel.insetBy(dx: -1, dy: -1))
                border.lineWidth = 2
                Theme.nsAccent.setStroke()
                border.stroke()
                let label = "\(Int(sel.width)) × \(Int(sel.height))" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                let size = label.size(withAttributes: attrs)
                let box = NSRect(x: sel.minX, y: max(sel.minY - size.height - 10, 4), width: size.width + 12, height: size.height + 6)
                NSColor.black.withAlphaComponent(0.75).setFill()
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                label.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
            } else {
                let hint = "Drag to select the area to record  ·  Esc to cancel" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let size = hint.size(withAttributes: attrs)
                let box = NSRect(x: bounds.midX - size.width / 2 - 16, y: bounds.midY - size.height / 2 - 10,
                                 width: size.width + 32, height: size.height + 20)
                NSColor.black.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
                hint.draw(at: NSPoint(x: box.minX + 16, y: box.minY + 10), withAttributes: attrs)
            }
        }

        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            current = start
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            current = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            current = convert(event.locationInWindow, from: nil)
            if let sel = selection, sel.width >= 64, sel.height >= 64 {
                onDone?(sel)
            } else {
                start = nil
                current = nil
                needsDisplay = true
            }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53: onDone?(nil)                                  // Esc
            case 36, 76: onDone?(bounds)                           // Return: whole screen
            default: super.keyDown(with: event)
            }
        }
    }
}

/// Dashed outline around the recorded area (outside it, so it isn't in the video).
@MainActor
enum AreaOutline {
    private static var window: NSWindow?

    static func show(_ rect: CGRect) {
        hide()
        let frame = rect.insetBy(dx: -4, dy: -4)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = OutlineView(frame: NSRect(origin: .zero, size: frame.size))
        w.orderFrontRegardless()
        window = w
    }

    static func hide() {
        window?.orderOut(nil)
        window = nil
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            Theme.nsAccent.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }
}

// MARK: - Countdown

@MainActor
enum CountdownOverlay {
    private static var window: NSWindow?
    private static let model = CountdownModel()

    static func show(_ n: Int, on screen: NSScreen, onCancel: @escaping () -> Void) {
        model.value = n
        model.onCancel = onCancel
        if window == nil {
            let size = NSSize(width: 220, height: 220)
            let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                               width: size.width, height: size.height)
            let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .screenSaver
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: CountdownView(model: model))
            w.orderFrontRegardless()
            window = w
        }
    }

    static func hide() {
        window?.orderOut(nil)
        window = nil
    }

    final class CountdownModel: ObservableObject {
        @Published var value = 3
        var onCancel: (() -> Void)?
    }

    struct CountdownView: View {
        @ObservedObject var model: CountdownModel
        var body: some View {
            VStack(spacing: 6) {
                Text("\(model.value)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: model.value)
                Text("Click to cancel").font(.callout).opacity(0.8)
            }
            .foregroundStyle(.white)
            .frame(width: 200, height: 200)
            .background(Circle().fill(.black.opacity(0.72)))
            .contentShape(Circle())
            .onTapGesture { model.onCancel?() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording starts in \(model.value)")
            .accessibilityAddTraits(.isButton)
        }
    }
}
