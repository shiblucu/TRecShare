import AppKit
import Combine

@main
enum TRecShareMain {
    @MainActor static let delegate = AppDelegate()   // NSApplication.delegate is weak: keep a strong reference

    @MainActor
    static func main() {
        AppSettings.migrateFromOldName()                // before anything reads settings or folders
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
        ProcessInfo.processInfo.disableAutomaticTermination("TRecShare menu-bar app")
        ProcessInfo.processInfo.disableSuddenTermination()

        MainMenu.install()
        Notifier.shared.setUp()
        let model = RecorderModel.shared
        statusItem = StatusItemController(model: model)
        NotificationCenter.default.addObserver(forName: .showRecorderPanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusItem?.showPopover() }
        }
        model.onWillCapture = { [weak self] in self?.statusItem?.closePopover() }

        AppSettings.shared.$hotkeysEnabled
            .receive(on: RunLoop.main)
            .sink { enabled in Self.configureHotKeys(enabled) }
            .store(in: &cancellables)

        RecordingLibrary.shared.refresh()
        Task { await model.refreshSources() }
        Task { await Self.recoverInterruptedRecordings() }
        UpdateChecker.shared.startAutomaticChecks()

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

    /// Saves recordings that were cut off by a crash or force-quit (see `RecordingRecovery`).
    private static func recoverInterruptedRecordings() async {
        let folders = [AppSettings.shared.recordingsFolder, AppSettings.defaultRecordingsFolder]
        let recovered = await RecordingRecovery.recoverInterruptedRecordings(in: folders)
        guard !recovered.isEmpty else { return }
        RecordingLibrary.shared.refresh()
        Notifier.shared.recordingSaved(recovered[0], title: recovered.count == 1
            ? "Recovered an unfinished recording"
            : "Recovered \(recovered.count) unfinished recordings")
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
                // Saving may have started an automatic upload: ask before cutting it off.
                NSApp.reply(toApplicationShouldTerminate: Self.confirmQuitDuringUpload())
            }
            return .terminateLater
        }
        return Self.confirmQuitDuringUpload() ? .terminateNow : .terminateCancel
    }

    /// True when it's fine to quit: no upload is running, or the user chose to stop it.
    private static func confirmQuitDuringUpload() -> Bool {
        guard UploadManager.shared.hasActiveUploads else { return true }
        let alert = NSAlert()
        alert.messageText = "An upload is still running"
        alert.informativeText = "If you quit now the upload stops. Your recording is saved on this Mac, and you can upload it again later from the Library."
        alert.addButton(withTitle: "Keep Uploading")
        alert.addButton(withTitle: "Quit Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() != .alertFirstButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        CameraBubble.shared.hide()
        HotKeys.shared.unregisterAll()
        Log.app.info("will terminate")
    }
}
