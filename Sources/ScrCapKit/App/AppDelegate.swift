import AppKit
import Combine

@main
enum ScrCapKitMain {
    @MainActor static let delegate = AppDelegate()   // NSApplication.delegate is weak: keep a strong reference

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)          // menu-bar app: no Dock icon until a window opens
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app has no windows, so macOS could otherwise end it as "idle".
        ProcessInfo.processInfo.disableAutomaticTermination("ScrCapKit menu-bar app")
        ProcessInfo.processInfo.disableSuddenTermination()

        MainMenu.install()
        Notifier.shared.setUp()
        let model = RecorderModel.shared
        statusItem = StatusItemController(model: model)
        model.onWillCapture = { [weak self] in self?.statusItem?.closePopover() }

        AppSettings.shared.$hotkeysEnabled
            .receive(on: RunLoop.main)
            .sink { enabled in Self.configureHotKeys(enabled) }
            .store(in: &cancellables)

        RecordingLibrary.shared.refresh()
        Task { await model.refreshSources() }

        if !AppSettings.shared.hasCompletedOnboarding {
            WindowRouter.shared.showWelcome()
        }
        Log.app.info("launched \(AppInfo.version, privacy: .public) (\(AppInfo.build, privacy: .public))")
    }

    private static func configureHotKeys(_ enabled: Bool) {
        let keys = HotKeys.shared
        keys.unregisterAll()
        guard enabled else { return }
        let model = RecorderModel.shared
        keys.register(HotKeys.toggleRecording) { model.toggleRecording() }
        keys.register(HotKeys.togglePause) { model.togglePause() }
        keys.register(HotKeys.screenshot) { model.takeScreenshot() }
        keys.register(HotKeys.cancelRecording) {
            if model.state.isStarting { model.cancelStart() } else if model.state.isCapturing { model.discardRecording() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { statusItem?.showPopover() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = RecorderModel.shared
        if model.state.isCapturing || model.state.isStarting {
            Log.app.info("quit requested while recording: saving first")
            Task {
                await model.stopForTermination()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        if UploadManager.shared.hasActiveUploads {
            let alert = NSAlert()
            alert.messageText = "An upload is still running"
            alert.informativeText = "If you quit now the upload stops. You can upload it again later from the Library."
            alert.addButton(withTitle: "Keep Uploading")
            alert.addButton(withTitle: "Quit Anyway")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        CameraBubble.shared.hide()
        HotKeys.shared.unregisterAll()
        Log.app.info("will terminate")
    }
}
