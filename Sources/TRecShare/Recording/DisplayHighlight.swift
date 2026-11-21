import AppKit

/// A blue border around a whole display that fades out after a moment, so the user can see which screen
/// they just selected. Click-through, and never part of a recording because it is gone before one starts.
@MainActor
enum DisplayHighlight {
    private static var panel: NSPanel?
    private static var generation = 0

    static func flash(on screen: NSScreen, duration: TimeInterval = 1.6) {
        hide()
        generation += 1
        let current = generation

        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.setAccessibilityElement(false)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.borderColor = Theme.nsAccent.cgColor
        view.layer?.borderWidth = 5
        view.layer?.backgroundColor = Theme.nsAccent.withAlphaComponent(0.06).cgColor
        p.contentView = view
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard current == generation, let p = panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                p.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { if current == generation { hide() } }
            })
        }
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
