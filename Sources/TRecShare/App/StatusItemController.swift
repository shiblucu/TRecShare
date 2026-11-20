import AppKit
import Combine
import SwiftUI

/// The menu-bar icon and its drop-down panel.
///
/// The panel is our own window (not NSPopover) so its behaviour is predictable:
/// it always sits right under the icon, grows downward when its content changes, and closes on
/// any click outside it, on Esc, when another app becomes active, or when a TRecShare window opens.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: RecorderModel
    private var panel: DropDownPanel?
    private var host: NSHostingView<AnyView>?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(model: RecorderModel) {
        self.model = model
        super.init()

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityTitle("TRecShare")
        }

        model.$state.combineLatest(model.$elapsed)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
        UploadManager.shared.$jobs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
        // Close when the user switches to another app.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.closePopover() }
            .store(in: &cancellables)
        // Close when any regular TRecShare window (Settings, Library, Review…) comes forward.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window !== self.panel,
                      window.styleMask.contains(.titled) else { return }
                self.closePopover()
            }
            .store(in: &cancellables)
        updateButton()
    }

    var isPanelShown: Bool { panel?.isVisible ?? false }

    // MARK: - Menu-bar button

    private func updateButton() {
        guard let button = item.button else { return }
        let symbol: String
        var title = ""
        var tint: NSColor?
        switch model.state {
        case .idle, .preparing, .selectingArea:
            if let p = UploadManager.shared.activeProgress {
                symbol = "arrow.up.circle"
                title = " \(Int(p * 100))%"
            } else {
                symbol = "video.circle"
            }
        case .countdown(let n):
            symbol = "timer"
            title = " \(n)"
        case .recording:
            symbol = "record.circle.fill"
            tint = Theme.nsAccent
            title = " \(model.elapsedText)"
        case .paused:
            symbol = "pause.circle.fill"
            tint = .systemOrange
            title = " \(model.elapsedText)"
        case .finishing:
            symbol = "hourglass"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TRecShare")
        if let tint, let image {
            button.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
            button.image?.isTemplate = false
        } else {
            image?.isTemplate = true
            button.image = image
        }
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.title = title
        button.toolTip = model.state.isCapturing ? "Click to finish or pause the recording" : "TRecShare — click to record"
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRight {
            closePopover()
            showMenu()
        } else if isPanelShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    // MARK: - Panel

    func showPopover() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.panelVisible = true

        // Measure first, then place, so the panel never appears at a wrong position.
        host?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? NSSize(width: 360, height: 400)
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrame(frame(for: size, under: anchor), display: true)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        installMonitors()
    }

    func closePopover() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        removeMonitors()
        model.panelVisible = false
    }

    /// Keeps the top edge under the icon and grows/shrinks downward when the content changes.
    private func contentSizeChanged(_ size: CGSize) {
        guard let panel, panel.isVisible, let button = item.button, let buttonWindow = button.window,
              size.width > 0, size.height > 0 else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let target = frame(for: size, under: anchor)
        if abs(target.height - panel.frame.height) > 0.5 || abs(target.width - panel.frame.width) > 0.5 {
            panel.setFrame(target, display: true)
        }
    }

    private func frame(for size: NSSize, under anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(size.height, visible.height - 12)
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let top = min(anchor.minY - 4, visible.maxY)
        return NSRect(x: x.rounded(), y: (top - height).rounded(), width: size.width, height: height)
    }

    private func makePanel() -> DropDownPanel {
        let root = RecorderPanel()
            .tint(Theme.accent)
            .environmentObject(model)
            .environmentObject(AppSettings.shared)
            .environmentObject(UploadManager.shared)
            .background(SizeReader { [weak self] size in self?.contentSizeChanged(size) })
            .background(VisualEffect(material: .popover))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = [.intrinsicContentSize]
        self.host = host

        let panel = DropDownPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                                  styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = host
        panel.setAccessibilityLabel("TRecShare recorder")
        panel.onEscape = { [weak self] in self?.closePopover() }
        return panel
    }

    // MARK: - Outside clicks

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps / the desktop.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
        // Clicks in our own other windows. The camera bubble is allowed (you drag it into place).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let w = event.window
                let isStatusButton = w === self.item.button?.window
                let isCamera = w.map { CGWindowID($0.windowNumber) } == CameraBubble.shared.windowID
                if w !== self.panel, !isStatusButton, !isCamera { self.closePopover() }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    // MARK: - Right-click menu

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, handler: action))
        }
        switch model.state {
        case .recording, .paused:
            add("Finish Recording") { [model] in model.stopRecording() }
            add(model.state == .paused ? "Resume" : "Pause") { [model] in model.togglePause() }
            add("Delete Recording") { [model] in model.discardRecording() }
        case .idle:
            add("Start Recording") { [model] in model.startRecording() }
        default:
            add("Cancel") { [model] in model.cancelStart() }
        }
        menu.addItem(.separator())
        if model.state == .idle { add("Take Screenshot") { [model] in model.takeScreenshot() } }
        add("Library…") { WindowRouter.shared.showLibrary() }
        add("Open Recordings Folder") { NSWorkspace.shared.open(RecordingLibrary.shared.folder) }
        add("Settings…") { WindowRouter.shared.showSettings() }
        menu.addItem(.separator())
        add("Quit TRecShare") { NSApp.terminate(nil) }
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}

/// Borderless panel that can take keyboard focus (for pickers) and closes on Esc.
final class DropDownPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Reports the SwiftUI content size so the panel can follow it.
private struct SizeReader: View {
    let onChange: (CGSize) -> Void
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { onChange(geo.size) }
                .onChange(of: geo.size) { _, size in onChange(size) }
        }
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
