import AppKit
import SwiftUI

/// Opens the app's regular windows (Library, Review, Settings, Welcome). While any is open the app
/// shows in the Dock and ⌘-Tab; when all are closed it goes back to being a menu-bar-only app.
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    static let shared = WindowRouter()
    private var windows: [String: NSWindow] = [:]

    func showLibrary() {
        RecordingLibrary.shared.refresh()
        show(id: "library", title: "TRecShare Library", size: NSSize(width: 900, height: 620), minSize: NSSize(width: 560, height: 400)) {
            LibraryView()
        }
    }

    func showReview(_ url: URL) {
        let window = show(id: "review", title: url.deletingPathExtension().lastPathComponent,
                          size: NSSize(width: 960, height: 700), minSize: NSSize(width: 640, height: 480)) {
            ReviewView(url: url)
        }
        // Replace the content when another recording is opened in the same window.
        (window.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(Self.wrap(ReviewView(url: url).id(url)))
        window.title = url.deletingPathExtension().lastPathComponent
    }

    func showSettings(tab: SettingsView.Tab? = nil) {
        if let tab { SettingsNav.shared.tab = tab }
        show(id: "settings", title: "TRecShare Settings", size: NSSize(width: 640, height: 600),
                          minSize: NSSize(width: 560, height: 480)) {
            SettingsView()
        }
    }

    func showWelcome() {
        show(id: "welcome", title: "Welcome to TRecShare", size: NSSize(width: 560, height: 600), minSize: NSSize(width: 520, height: 560),
             resizable: false) {
            WelcomeView()
        }
    }

    func close(_ id: String) {
        windows[id]?.close()
    }

    func updateTitle(_ id: String, _ title: String) {
        windows[id]?.title = title
    }

    @discardableResult
    private func show<V: View>(id: String, title: String, size: NSSize, minSize: NSSize, resizable: Bool = true,
                               @ViewBuilder content: () -> V) -> NSWindow {
        NSApp.setActivationPolicy(.regular)
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        let host = NSHostingController(rootView: AnyView(Self.wrap(content())))
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = title
        window.titlebarAppearsTransparent = false
        window.setContentSize(size)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.setFrameAutosaveName("TRecShare.\(id)")
        if !window.setFrameUsingName("TRecShare.\(id)") { window.center() }
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private static func wrap<V: View>(_ view: V) -> some View {
        view
            .appAppearance()
            .tint(Theme.accent)
            .environmentObject(AppSettings.shared)
            .environmentObject(RecorderModel.shared)
            .environmentObject(UploadManager.shared)
            .environmentObject(RecordingLibrary.shared)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        if id == "welcome" { AppSettings.shared.hasCompletedOnboarding = true }
        if windows.isEmpty {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
