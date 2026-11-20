import AppKit
import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit

enum RecorderState: Equatable {
    case idle, preparing, selectingArea, countdown(Int), recording, paused, finishing

    var isCapturing: Bool { self == .recording || self == .paused }
    var isStarting: Bool {
        switch self {
        case .preparing, .selectingArea, .countdown: return true
        default: return false
        }
    }
}

struct DisplayChoice: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isMain: Bool
}

struct DeviceChoice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct WindowChoice: Identifiable, Hashable {
    let id: CGWindowID
    let appName: String
    let title: String
    var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

/// Drives a recording from "Start" to the saved file. Everything here runs on the main thread.
@MainActor
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()

    let settings = AppSettings.shared

    // Sources
    @Published private(set) var displays: [DisplayChoice] = []
    @Published private(set) var windows: [WindowChoice] = []
    @Published private(set) var microphones: [DeviceChoice] = []
    @Published private(set) var cameras: [DeviceChoice] = []
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?

    // Status
    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastRecording: URL?
    @Published var errorMessage: String?
    @Published private(set) var needsScreenPermission = false
    @Published private(set) var needsMicrophonePermission = false
    @Published private(set) var needsCameraPermission = false
    @Published var panelVisible = false { didSet { updateCameraBubble() } }

    /// Called right before capture UI appears, so the menu-bar panel can close.
    var onWillCapture: (() -> Void)?

    private let recorder = ScreenRecorder()
    private var content: SCShareableContent?
    private var startTask: Task<Void, Never>?
    private var timer: Timer?
    private var segmentStartedAt: Date?
    private var accumulated: TimeInterval = 0
    private var activity: NSObjectProtocol?
    private var targetScreen: NSScreen?
    private var lastArea: (display: CGDirectDisplayID, rect: CGRect)?
    private var reuseLastArea = false
    private var outputURL: URL?
    private var ticks = 0
    private var cancellables = Set<AnyCancellable>()

    private init() {
        recorder.onUnexpectedStop = { [weak self] error, userStopped in
            self?.handleUnexpectedStop(error: error, userStopped: userStopped)
        }
        Publishers.CombineLatest4(settings.$cameraEnabled, settings.$cameraID, settings.$cameraSize, settings.$cameraShape)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateCameraBubble() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in Task { await self?.refreshSources() } }
            .store(in: &cancellables)
    }

    var isBusy: Bool { state != .idle }
    var elapsedText: String { Format.duration(elapsed) }

    // MARK: - Sources

    /// Reloads displays, windows, microphones and cameras. The first call also triggers the Screen Recording prompt.
    func refreshSources(followCursor: Bool = false) async {
        loadDevices()
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            content = c
            needsScreenPermission = false
            let mainID = CGMainDisplayID()
            displays = c.displays.map { DisplayChoice(id: $0.displayID, name: Self.displayName(for: $0.displayID), isMain: $0.displayID == mainID) }
                .sorted { $0.isMain && !$1.isMain }
            let myID = Bundle.main.bundleIdentifier
            windows = c.windows
                .filter { w in
                    w.windowLayer == 0 && w.isOnScreen && w.frame.width >= 120 && w.frame.height >= 80
                        && w.owningApplication != nil && w.owningApplication?.bundleIdentifier != myID
                        && !["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter"].contains(w.owningApplication?.bundleIdentifier ?? "")
                }
                .map { WindowChoice(id: $0.windowID, appName: $0.owningApplication?.applicationName ?? "App", title: $0.title ?? "") }
                .sorted { ($0.appName, $0.title) < ($1.appName, $1.title) }

            if selectedDisplayID == nil || !displays.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = displays.first(where: { $0.isMain })?.id ?? displays.first?.id
            }
            if followCursor, !isBusy, let id = Self.displayUnderCursor(), displays.contains(where: { $0.id == id }) {
                selectedDisplayID = id
            }
            if let wid = selectedWindowID, !windows.contains(where: { $0.id == wid }) { selectedWindowID = nil }
            if selectedWindowID == nil { selectedWindowID = windows.first?.id }
        } catch {
            content = nil
            displays = []
            windows = []
            needsScreenPermission = !Permissions.hasScreenAccess
            if needsScreenPermission { Permissions.requestScreenAccess() }
        }
    }

    private func loadDevices() {
        let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                    position: .unspecified).devices
        microphones = mics.map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        if settings.microphoneID == nil || !microphones.contains(where: { $0.id == settings.microphoneID }) {
            settings.microphoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.id
        }
        cameras = CameraBubble.cameras().map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        if settings.cameraID == nil || !cameras.contains(where: { $0.id == settings.cameraID }) {
            settings.cameraID = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras.first?.id
        }
        needsMicrophonePermission = settings.microphoneEnabled && Permissions.status(for: .audio) == .denied
        needsCameraPermission = settings.cameraEnabled && Permissions.status(for: .video) == .denied
    }

    static func displayName(for id: CGDirectDisplayID) -> String {
        screen(for: id)?.localizedName ?? "Display \(id)"
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
    }

    private static func displayUnderCursor() -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
        return (screen?.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    // MARK: - File changes

    func fileRenamed(from old: URL, to new: URL) {
        if lastRecording == old { lastRecording = new }
    }

    func fileDeleted(_ url: URL) {
        if lastRecording == url { lastRecording = nil }
    }

    // MARK: - Camera

    func setCameraEnabled(_ on: Bool) {
        guard on else {
            settings.cameraEnabled = false
            return
        }
        Task {
            let allowed = await Permissions.request(.video)
            needsCameraPermission = !allowed
            if allowed {
                settings.cameraEnabled = true
            } else {
                errorMessage = "Camera access is off. Turn it on in System Settings → Privacy & Security → Camera."
            }
        }
    }

    func setMicrophoneEnabled(_ on: Bool) {
        settings.microphoneEnabled = on
        guard on else { needsMicrophonePermission = false; return }
        Task {
            let allowed = await Permissions.request(.audio)
            needsMicrophonePermission = !allowed
            if !allowed {
                errorMessage = "Microphone access is off. Turn it on in System Settings, or switch the microphone off."
            }
        }
    }

    func updateCameraBubble() {
        let active = state.isStarting || state.isCapturing
        let wanted = settings.cameraEnabled && Permissions.status(for: .video) == .granted && (panelVisible || active)
        if wanted {
            let screen = targetScreen ?? selectedDisplayID.flatMap(Self.screen(for:))
            CameraBubble.shared.show(deviceID: settings.cameraID, size: settings.cameraSize, on: screen)
        } else if CameraBubble.shared.isVisible {
            CameraBubble.shared.hide()
        }
    }

    // MARK: - Recording controls

    func toggleRecording() {
        switch state {
        case .idle: startRecording()
        case .preparing, .countdown, .selectingArea: cancelStart()
        case .recording, .paused: stopRecording()
        case .finishing: break
        }
    }

    func startRecording() {
        guard state == .idle else { return }
        errorMessage = nil
        startTask = Task { await runStart() }
    }

    /// Cancels before anything is recorded (during the countdown or area selection).
    func cancelStart() {
        startTask?.cancel()
        startTask = nil
        CountdownOverlay.hide()
        if state == .selectingArea { AreaSelector.cancel() }
        if state.isStarting { state = .idle }
        targetScreen = nil
        updateCameraBubble()
    }

    func togglePause() {
        if state == .recording { pause() } else if state == .paused { resume() }
    }

    func pause() {
        guard state == .recording else { return }
        state = .paused
        accumulateElapsed()
        stopTimer()
        Task { await recorder.pause() }
    }

    func resume() {
        guard state == .paused else { return }
        Task {
            do {
                try await recorder.resume()
                state = .recording
                segmentStartedAt = Date()
                startTimer()
            } catch {
                errorMessage = "Could not resume: \(error.localizedDescription). The part recorded so far is being saved."
                stopRecording()
            }
        }
    }

    func stopRecording() {
        guard state.isCapturing else { return }
        Task { await finishRecording() }
    }

    /// Throws away the current recording.
    func discardRecording() {
        guard state.isCapturing else { return }
        state = .finishing
        tearDownCaptureUI()
        Task {
            await recorder.cancel()
            state = .idle
            targetScreen = nil
            updateCameraBubble()
        }
    }

    /// Throws away the current recording and starts again (same source and area).
    func restartRecording() {
        guard state.isCapturing else { return }
        state = .finishing
        tearDownCaptureUI()
        Task {
            await recorder.cancel()
            state = .idle
            reuseLastArea = true
            startRecording()
        }
    }

    /// Used when the app quits or the Mac logs out: saves what was recorded.
    func stopForTermination() async {
        if state.isStarting { cancelStart() }
        if state.isCapturing { await finishRecording() }
    }

    // MARK: - Start

    private func runStart() async {
        state = .preparing
        defer { reuseLastArea = false }

        // Disk space
        let folder = settings.recordingsFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fail("Can't use the recordings folder (\(folder.path)): \(error.localizedDescription). Choose another in Settings.")
            return
        }
        if let free = Self.freeSpace(at: folder), free < 1_000_000_000 {
            fail("Less than 1 GB is free on the disk with your recordings folder. Free up space or choose another folder in Settings.")
            return
        }

        // Permissions
        if settings.microphoneEnabled {
            let allowed = await Permissions.request(.audio)
            needsMicrophonePermission = !allowed
            if !allowed {
                fail("Microphone access is off. Turn it on in System Settings, or switch the microphone off here.")
                return
            }
        }
        if settings.cameraEnabled, Permissions.status(for: .video) != .granted {
            let allowed = await Permissions.request(.video)
            needsCameraPermission = !allowed
            if !allowed { settings.cameraEnabled = false }
        }

        await refreshSources()
        guard let content else {
            fail("ScrCapKit needs Screen Recording permission. Turn it on in System Settings, then quit and reopen ScrCapKit.")
            return
        }
        if Task.isCancelled { return }

        // Resolve what to record.
        let mode = settings.captureMode
        var display: SCDisplay?
        var window: SCWindow?
        var areaRect: CGRect?   // global AppKit points
        switch mode {
        case .screen, .area:
            guard let id = selectedDisplayID, let d = content.displays.first(where: { $0.displayID == id }) else {
                fail("No display is available to record.")
                return
            }
            display = d
            targetScreen = Self.screen(for: id)
        case .window:
            guard let id = selectedWindowID, let w = content.windows.first(where: { $0.windowID == id }) else {
                fail("Pick a window to record. If it isn't listed, bring it on screen and open this menu again.")
                return
            }
            window = w
            let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let appKitCenter = NSPoint(x: center.x, y: primaryHeight - center.y)
            targetScreen = NSScreen.screens.first { $0.frame.contains(appKitCenter) } ?? NSScreen.main
        }

        if mode == .area, let display, let screen = targetScreen {
            if reuseLastArea, let last = lastArea, last.display == display.displayID {
                areaRect = last.rect
            } else {
                onWillCapture?()
                state = .selectingArea
                guard let rect = await AreaSelector.select(on: screen), !Task.isCancelled else {
                    if state == .selectingArea { state = .idle }
                    return
                }
                areaRect = rect
                lastArea = (display.displayID, rect)
            }
        }

        onWillCapture?()
        updateCameraBubble()

        // Countdown
        if settings.countdownEnabled, let screen = targetScreen ?? NSScreen.main {
            for n in stride(from: 3, through: 1, by: -1) {
                state = .countdown(n)
                CountdownOverlay.show(n, on: screen) { [weak self] in self?.cancelStart() }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { CountdownOverlay.hide(); return }
            }
            CountdownOverlay.hide()
        }
        if Task.isCancelled { return }

        // Build the capture filter now that the camera bubble is on screen.
        let fresh = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) ?? content
        let filter: SCContentFilter
        if let window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display {
            let myID = Bundle.main.bundleIdentifier
            let camera = CameraBubble.shared.isVisible
                ? fresh.windows.first { $0.windowID == CameraBubble.shared.windowID } : nil
            if let me = fresh.applications.first(where: { $0.bundleIdentifier == myID }) {
                filter = SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: camera.map { [$0] } ?? [])
            } else {
                let mine = fresh.windows.filter { $0.owningApplication?.bundleIdentifier == myID && $0.windowID != camera?.windowID }
                filter = SCContentFilter(display: display, excludingWindows: mine)
            }
        } else {
            fail("Nothing to record.")
            return
        }

        let config = makeConfiguration(filter: filter, display: display, areaRect: areaRect)
        let base = "ScrCapKit \(FileNames.timestamp())"
        let url = FileNames.unique(in: folder, base: base, ext: "mp4")

        do {
            try await recorder.start(filter: filter, configuration: config, near: url)
        } catch {
            fail("Could not start recording: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled {
            await recorder.cancel()
            return
        }

        outputURL = url
        accumulated = 0
        elapsed = 0
        segmentStartedAt = Date()
        state = .recording
        startTimer()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled],
                                                         reason: "Screen recording in progress")
        if let screen = targetScreen { ControlBar.show(model: self, on: screen) }
        if let areaRect { AreaOutline.show(areaRect) }
        Log.recorder.info("recording started (\(mode.rawValue))")
    }

    private func makeConfiguration(filter: SCContentFilter, display: SCDisplay?, areaRect: CGRect?) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var pointSize = filter.contentRect.size
        if let areaRect, let display, let screen = Self.screen(for: display.displayID) {
            // sourceRect is in the display's own points, origin top-left.
            let local = CGRect(x: areaRect.minX - screen.frame.minX, y: screen.frame.maxY - areaRect.maxY,
                               width: areaRect.width, height: areaRect.height)
            config.sourceRect = local
            pointSize = local.size
        }
        var width = Double(pointSize.width * scale)
        var height = Double(pointSize.height * scale)
        let maxHeight = settings.quality.maxHeight
        if maxHeight < Int.max, height > Double(maxHeight) {
            width = width * Double(maxHeight) / height
            height = Double(maxHeight)
        }
        config.width = max(Int(width.rounded()) & ~1, 2)
        config.height = max(Int(height.rounded()) & ~1, 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        config.queueDepth = settings.frameRate > 30 ? 8 : 6
        config.captureResolution = .best
        config.showsCursor = settings.showCursor
        config.showMouseClicks = settings.highlightClicks
        config.capturesAudio = settings.systemAudioEnabled
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = settings.microphoneEnabled
        if display == nil { config.ignoreShadowsSingleWindow = true }   // window recordings: no drop-shadow margin
        if settings.microphoneEnabled, let id = settings.microphoneID { config.microphoneCaptureDeviceID = id }
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    // MARK: - Screenshots

    /// Takes a still image (PNG) of the selected screen, window or area, saves it and copies it to the clipboard.
    func takeScreenshot() {
        guard state == .idle else { return }
        errorMessage = nil
        Task { await runScreenshot() }
    }

    private func runScreenshot() async {
        guard state == .idle else { return }
        state = .preparing
        defer { if state == .preparing || state == .selectingArea { state = .idle } }

        await refreshSources()
        guard let content else {
            errorMessage = "ScrCapKit needs Screen Recording permission. Turn it on in System Settings, then quit and reopen ScrCapKit."
            return
        }

        let mode = settings.captureMode
        var display: SCDisplay?
        var window: SCWindow?
        var areaRect: CGRect?   // global AppKit points
        var screen: NSScreen?
        switch mode {
        case .screen, .area:
            guard let id = selectedDisplayID, let d = content.displays.first(where: { $0.displayID == id }) else {
                errorMessage = "No display is available to capture."
                return
            }
            display = d
            screen = Self.screen(for: id)
        case .window:
            guard let id = selectedWindowID, let w = content.windows.first(where: { $0.windowID == id }) else {
                errorMessage = "Pick a window to capture. If it isn't listed, bring it on screen and open this menu again."
                return
            }
            window = w
        }

        if mode == .area, let screen {
            onWillCapture?()
            state = .selectingArea
            guard let rect = await AreaSelector.select(on: screen) else { return }
            areaRect = rect
        }
        onWillCapture?()
        try? await Task.sleep(for: .milliseconds(150))   // let the panel finish disappearing

        let fresh = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) ?? content
        let filter: SCContentFilter
        if let window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let display {
            let myID = Bundle.main.bundleIdentifier
            let mine = fresh.windows.filter { $0.owningApplication?.bundleIdentifier == myID }
            filter = SCContentFilter(display: display, excludingWindows: mine)
        } else {
            return
        }

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        var pointSize = filter.contentRect.size
        if let areaRect, let display, let screen = Self.screen(for: display.displayID) {
            let local = CGRect(x: areaRect.minX - screen.frame.minX, y: screen.frame.maxY - areaRect.maxY,
                               width: areaRect.width, height: areaRect.height)
            config.sourceRect = local
            pointSize = local.size
        }
        config.width = max(Int((pointSize.width * scale).rounded()), 2)
        config.height = max(Int((pointSize.height * scale).rounded()), 2)
        config.showsCursor = settings.showCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.sRGB
        if window != nil { config.ignoreShadowsSingleWindow = true }

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let folder = settings.recordingsFolder.appendingPathComponent("Screenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = FileNames.unique(in: folder, base: "ScrCapKit Screenshot \(FileNames.timestamp())", ext: "png")
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale,
                                                                                    height: CGFloat(image.height) / scale))])
            Notifier.shared.screenshotSaved(url)
            Log.recorder.info("screenshot saved")
        } catch {
            errorMessage = "Could not take the screenshot: \(error.localizedDescription)"
            Log.recorder.error("screenshot failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Finish

    private func finishRecording() async {
        guard state.isCapturing, let url = outputURL else { return }
        state = .finishing
        accumulateElapsed()
        tearDownCaptureUI()
        do {
            let saved = try await recorder.finish(to: url)
            lastRecording = saved
            Log.recorder.info("recording saved")
            afterRecording(saved)
        } catch {
            errorMessage = "Could not save the recording: \(error.localizedDescription)"
            Log.recorder.error("save failed: \(error.localizedDescription)")
        }
        outputURL = nil
        state = .idle
        targetScreen = nil
        updateCameraBubble()
    }

    private func afterRecording(_ url: URL) {
        RecordingLibrary.shared.refresh()
        if settings.autoUpload, settings.canUpload {
            UploadManager.shared.upload(url)
        }
        if settings.openReviewAfterRecording {
            WindowRouter.shared.showReview(url)
        } else {
            Notifier.shared.recordingSaved(url)
        }
    }

    private func handleUnexpectedStop(error: Error?, userStopped: Bool) {
        guard state == .recording else { return }
        if let error, !userStopped {
            errorMessage = "Recording stopped: \(error.localizedDescription). What was captured has been saved."
        }
        Task { await finishRecording() }
    }

    private func tearDownCaptureUI() {
        stopTimer()
        ControlBar.hide()
        AreaOutline.hide()
        CountdownOverlay.hide()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func fail(_ message: String) {
        errorMessage = message
        state = .idle
        targetScreen = nil
        CountdownOverlay.hide()
        updateCameraBubble()
        Log.recorder.error("start failed: \(message)")
    }

    static func freeSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Timer

    private func accumulateElapsed() {
        if let start = segmentStartedAt { accumulated += Date().timeIntervalSince(start) }
        segmentStartedAt = nil
        elapsed = accumulated
    }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // keeps ticking while menus are open
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let start = segmentStartedAt else { return }
        elapsed = accumulated + Date().timeIntervalSince(start)
        ticks += 1
        // Every ~30 s: stop safely before the disk fills up.
        if ticks % 60 == 0, let free = Self.freeSpace(at: settings.recordingsFolder), free < 300_000_000 {
            errorMessage = "Your disk is almost full, so the recording was stopped and saved."
            stopRecording()
        }
    }
}
