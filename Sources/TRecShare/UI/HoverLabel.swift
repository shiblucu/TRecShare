import AppKit
import SwiftUI

/// A small label that appears next to the pointer when it rests on a control, so icon-only buttons say what they do.
/// It's drawn by TRecShare itself (a tiny click-through window), because macOS's built-in tooltips don't appear
/// reliably in menu-bar panels and non-active windows.
@MainActor
final class HoverLabelWindow {
    static let shared = HoverLabelWindow()

    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var monitor: Any?

    func schedule(_ text: String) {
        cancel()
        guard !text.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.show(text) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func show(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12 * AppSettings.shared.textSize.scale)
        label.textColor = .white
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 300
        label.maximumNumberOfLines = 4
        label.sizeToFit()

        let padding = NSSize(width: 10, height: 6)
        let size = NSSize(width: label.frame.width + padding.width * 2, height: label.frame.height + padding.height * 2)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        content.layer?.cornerRadius = 6
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        label.frame.origin = NSPoint(x: padding.width, y: padding.height)
        content.addSubview(label)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: mouse.x + 10, y: mouse.y - size.height - 18)   // below and to the right of the pointer
        if origin.y < visible.minY { origin.y = mouse.y + 20 }                 // no room below: show above
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)

        let p = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.setAccessibilityElement(false)   // controls already expose their own accessibility label
        p.contentView = content
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.orderFrontRegardless()
        panel = p

        // Any click, key press or scroll dismisses it.
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.cancel() }
                return event
            }
        }
    }
}

private struct HoverLabelModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside { HoverLabelWindow.shared.schedule(text) } else { HoverLabelWindow.shared.cancel() }
            }
            .onDisappear { HoverLabelWindow.shared.cancel() }
    }
}

extension View {
    /// Shows `text` in a small label when the pointer rests on this view.
    func hoverLabel(_ text: String) -> some View { modifier(HoverLabelModifier(text: text)) }
}

/// A `Picker` with slightly larger text and a roomier select box than the macOS default.
struct AppPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    @ViewBuilder let content: () -> Content
    @Environment(\.controlSize) private var controlSize

    init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._selection = selection
        self.content = content
    }

    private var larger: ControlSize {
        switch controlSize {
        case .mini: return .small
        case .small: return .regular
        case .regular: return .large
        default: return .extraLarge
        }
    }

    var body: some View {
        Picker(title, selection: $selection, content: content)
            .font(.appSize(14))
            .controlSize(larger)
    }
}
