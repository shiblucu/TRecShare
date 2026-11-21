import Foundation
import ServiceManagement
import SwiftUI

// MARK: - Option types

enum CaptureMode: String, CaseIterable, Identifiable {
    case screen, window, area
    var id: String { rawValue }
    var title: String {
        switch self {
        case .screen: return "Screen"
        case .window: return "Window"
        case .area: return "Area"
        }
    }
    var icon: String {
        switch self {
        case .screen: return "display"
        case .window: return "macwindow"
        case .area: return "rectangle.dashed"
        }
    }
}

enum RecordingQuality: String, CaseIterable, Identifiable {
    case small = "720p · Small"
    case balanced = "1080p · Balanced"
    case medium = "1440p · Detailed"
    case best = "4K · Best"
    case native = "Native · Sharpest"

    var id: String { rawValue }
    /// Rough file size per minute. Busy screens run larger, still screens much smaller.
    var sizeHint: String {
        switch self {
        case .small: return "~5 MB/min"
        case .balanced: return "~10 MB/min"
        case .medium: return "~18 MB/min"
        case .best: return "~30 MB/min"
        case .native: return "~25–45 MB/min"
        }
    }
    var maxHeight: Int {
        switch self {
        case .small: return 720
        case .balanced: return 1080
        case .medium: return 1440
        case .best: return 2160
        case .native: return Int.max
        }
    }
}

/// Size of the copy that gets uploaded (the original always stays on this Mac).
enum UploadQuality: String, CaseIterable, Identifiable {
    case original, hd1440, hd1080, hd720
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original (largest)"
        case .hd1440: return "1440p · Sharpest"
        case .hd1080: return "1080p · Sharp (recommended)"
        case .hd720: return "720p · Light"
        }
    }
    var shortTitle: String {
        switch self {
        case .original: return "Original"
        case .hd1440: return "1440p"
        case .hd1080: return "1080p"
        case .hd720: return "720p"
        }
    }
    var maxHeight: Int? {
        switch self {
        case .original: return nil
        case .hd1440: return 1440
        case .hd1080: return 1080
        case .hd720: return 720
        }
    }
    /// Average H.264 bitrate, tuned so text stays crisp.
    var bitrate: Int {
        switch self {
        case .original: return 0
        case .hd1440: return 9_000_000
        case .hd1080: return 6_000_000
        case .hd720: return 3_000_000
        }
    }
    static var copyChoices: [UploadQuality] { [.hd1440, .hd1080, .hd720] }
}

enum UploadDestination: String, CaseIterable, Identifiable {
    case none, spaces, drive, server
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Don't upload (keep on this Mac)"
        case .spaces: return "DigitalOcean Spaces / S3"
        case .drive: return "Google Drive"
        case .server: return "My own server (VPS)"
        }
    }
    var shortTitle: String {
        switch self {
        case .none: return "This Mac"
        case .spaces: return "Spaces"
        case .drive: return "Google Drive"
        case .server: return "My server"
        }
    }
    var icon: String {
        switch self {
        case .none: return "internaldrive"
        case .spaces: return "cloud"
        case .drive: return "externaldrive.connected.to.line.below"
        case .server: return "server.rack"
        }
    }
}

enum LinkAccess: String, CaseIterable, Identifiable {
    case publicLink, expiring
    var id: String { rawValue }
    var title: String {
        switch self {
        case .publicLink: return "Anyone with the link (permanent)"
        case .expiring: return "Private, link expires after 7 days"
        }
    }
}

enum ServerMethod: String, CaseIterable, Identifiable {
    case sftp, http
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sftp: return "SFTP (SSH key)"
        case .http: return "HTTPS PUT / WebDAV"
        }
    }
}

/// macOS system typefaces only (no fonts are bundled or downloaded).
enum AppFontStyle: String, CaseIterable, Identifiable {
    case standard, rounded, serif, monospaced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "SF Pro (default)"
        case .rounded: return "SF Pro Rounded"
        case .serif: return "New York"
        case .monospaced: return "SF Mono"
        }
    }
    var design: Font.Design {
        switch self {
        case .standard: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

enum AppTextSize: String, CaseIterable, Identifiable {
    case small, standard, large, extraLarge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Default"
        case .large: return "Large"
        case .extraLarge: return "Extra large"
        }
    }
    /// Base size for body text, in points (macOS default is 13).
    var bodySize: CGFloat {
        switch self {
        case .small: return 12
        case .standard: return 13
        case .large: return 15
        case .extraLarge: return 17
        }
    }
    /// Multiplier relative to the default (13 pt) body size.
    var scale: CGFloat { bodySize / 13 }
    var controlSize: ControlSize {
        switch self {
        case .small: return .small
        case .standard: return .regular
        case .large, .extraLarge: return .large
        }
    }
}

enum CameraShape: String, CaseIterable, Identifiable {
    case portrait, circle
    var id: String { rawValue }
    var title: String { self == .portrait ? "Portrait (rounded corners)" : "Circle" }
}

enum CameraSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Frame size in points for the given shape: portrait is 3:4, circle is square.
    func frame(for shape: CameraShape) -> CGSize {
        switch shape {
        case .portrait: return CGSize(width: width, height: (width * 4 / 3).rounded())
        case .circle: return CGSize(width: circleDiameter, height: circleDiameter)
        }
    }

    private var circleDiameter: CGFloat {
        switch self { case .small: return 150; case .medium: return 210; case .large: return 290 }
    }

    /// Width of the portrait frame in points.
    var width: CGFloat {
        switch self {
        case .small: return 140
        case .medium: return 190
        case .large: return 250
        }
    }
}

// MARK: - Settings store

/// All user preferences, saved in UserDefaults. Secrets live in the Keychain (see `Keychain`).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Recording
    @Published var captureMode: CaptureMode { didSet { d.set(captureMode.rawValue, forKey: "captureMode") } }
    @Published var microphoneEnabled: Bool { didSet { d.set(microphoneEnabled, forKey: "microphoneEnabled") } }
    @Published var microphoneID: String? { didSet { d.set(microphoneID, forKey: "microphoneID") } }
    @Published var systemAudioEnabled: Bool { didSet { d.set(systemAudioEnabled, forKey: "systemAudioEnabled") } }
    @Published var cameraEnabled: Bool { didSet { d.set(cameraEnabled, forKey: "cameraEnabled") } }
    @Published var cameraID: String? { didSet { d.set(cameraID, forKey: "cameraID") } }
    @Published var cameraShape: CameraShape { didSet { d.set(cameraShape.rawValue, forKey: "cameraShape") } }
    @Published var cameraSize: CameraSize { didSet { d.set(cameraSize.rawValue, forKey: "cameraSize") } }
    @Published var countdownEnabled: Bool { didSet { d.set(countdownEnabled, forKey: "countdownEnabled") } }
    @Published var quality: RecordingQuality { didSet { d.set(quality.rawValue, forKey: "quality_v2") } }
    @Published var frameRate: Int { didSet { d.set(frameRate, forKey: "frameRate") } }
    @Published var showCursor: Bool { didSet { d.set(showCursor, forKey: "showCursor") } }
    @Published var highlightClicks: Bool { didSet { d.set(highlightClicks, forKey: "highlightClicks") } }
    @Published var saveFolderPath: String? { didSet { d.set(saveFolderPath, forKey: "saveFolderPath") } }

    // After recording
    @Published var openReviewAfterRecording: Bool { didSet { d.set(openReviewAfterRecording, forKey: "openReview") } }
    @Published var hotkeysEnabled: Bool { didSet { d.set(hotkeysEnabled, forKey: "hotkeysEnabled") } }

    // Upload
    @Published var uploadDestination: UploadDestination { didSet { d.set(uploadDestination.rawValue, forKey: "uploadDestination") } }
    @Published var autoUpload: Bool { didSet { d.set(autoUpload, forKey: "autoUpload") } }
    @Published var uploadQuality: UploadQuality { didSet { d.set(uploadQuality.rawValue, forKey: "uploadQuality") } }
    @Published var createSharePage: Bool { didSet { d.set(createSharePage, forKey: "createSharePage") } }
    @Published var openLinkAfterUpload: Bool { didSet { d.set(openLinkAfterUpload, forKey: "openLinkAfterUpload") } }
    /// Evens out the voice volume of uploaded and smaller copies (never the original). On by default.
    @Published var levelVoice: Bool { didSet { d.set(levelVoice, forKey: "levelVoice") } }

    // DigitalOcean Spaces / S3-compatible
    @Published var spacesEndpoint: String { didSet { d.set(spacesEndpoint, forKey: "spaces.endpoint") } }
    @Published var spacesRegion: String { didSet { d.set(spacesRegion, forKey: "spaces.region") } }
    @Published var spacesBucket: String { didSet { d.set(spacesBucket, forKey: "spaces.bucket") } }
    @Published var spacesAccessKey: String { didSet { d.set(spacesAccessKey, forKey: "spaces.accessKey") } }
    @Published var spacesPrefix: String { didSet { d.set(spacesPrefix, forKey: "spaces.prefix") } }
    @Published var spacesPublicBaseURL: String { didSet { d.set(spacesPublicBaseURL, forKey: "spaces.publicBaseURL") } }
    @Published var spacesLinkAccess: LinkAccess { didSet { d.set(spacesLinkAccess.rawValue, forKey: "spaces.linkAccess") } }
    @Published var spacesPathStyle: Bool { didSet { d.set(spacesPathStyle, forKey: "spaces.pathStyle") } }

    // Google Drive
    @Published var driveClientID: String { didSet { d.set(driveClientID, forKey: "drive.clientID") } }
    @Published var driveAccount: String { didSet { d.set(driveAccount, forKey: "drive.account") } }
    @Published var driveFolderID: String { didSet { d.set(driveFolderID, forKey: "drive.recordingsFolderID") } }
    @Published var driveAnyoneWithLink: Bool { didSet { d.set(driveAnyoneWithLink, forKey: "drive.anyoneWithLink") } }

    // Own server
    @Published var serverMethod: ServerMethod { didSet { d.set(serverMethod.rawValue, forKey: "server.method") } }
    @Published var serverHost: String { didSet { d.set(serverHost, forKey: "server.host") } }
    @Published var serverPort: Int { didSet { d.set(serverPort, forKey: "server.port") } }
    @Published var serverUser: String { didSet { d.set(serverUser, forKey: "server.user") } }
    @Published var serverRemotePath: String { didSet { d.set(serverRemotePath, forKey: "server.remotePath") } }
    @Published var serverKeyPath: String { didSet { d.set(serverKeyPath, forKey: "server.keyPath") } }
    @Published var serverUploadURL: String { didSet { d.set(serverUploadURL, forKey: "server.uploadURL") } }
    @Published var serverPublicBaseURL: String { didSet { d.set(serverPublicBaseURL, forKey: "server.publicBaseURL") } }

    @Published var hasCompletedOnboarding: Bool { didSet { d.set(hasCompletedOnboarding, forKey: "onboarded") } }

    // Appearance
    @Published var fontStyle: AppFontStyle { didSet { d.set(fontStyle.rawValue, forKey: "appearance.fontStyle") } }
    @Published var textSize: AppTextSize { didSet { d.set(textSize.rawValue, forKey: "appearance.textSize") } }

    // Updates
    @Published var checkForUpdatesAutomatically: Bool { didSet { d.set(checkForUpdatesAutomatically, forKey: "updates.automatic") } }

    private init() {
        let d = UserDefaults.standard
        captureMode = CaptureMode(rawValue: d.string(forKey: "captureMode") ?? "") ?? .screen
        microphoneEnabled = d.object(forKey: "microphoneEnabled") as? Bool ?? true
        microphoneID = d.string(forKey: "microphoneID")
        systemAudioEnabled = d.object(forKey: "systemAudioEnabled") as? Bool ?? false
        cameraEnabled = d.object(forKey: "cameraEnabled") as? Bool ?? false
        cameraID = d.string(forKey: "cameraID")
        cameraShape = CameraShape(rawValue: d.string(forKey: "cameraShape") ?? "") ?? .portrait
        cameraSize = CameraSize(rawValue: d.string(forKey: "cameraSize") ?? "") ?? .medium
        countdownEnabled = d.object(forKey: "countdownEnabled") as? Bool ?? true
        quality = RecordingQuality(rawValue: d.string(forKey: "quality_v2") ?? "") ?? .native
        let fps = d.integer(forKey: "frameRate")
        frameRate = [30, 60].contains(fps) ? fps : 30
        showCursor = d.object(forKey: "showCursor") as? Bool ?? true
        highlightClicks = d.object(forKey: "highlightClicks") as? Bool ?? false
        saveFolderPath = d.string(forKey: "saveFolderPath")
        openReviewAfterRecording = d.object(forKey: "openReview") as? Bool ?? true
        hotkeysEnabled = d.object(forKey: "hotkeysEnabled") as? Bool ?? true

        uploadDestination = UploadDestination(rawValue: d.string(forKey: "uploadDestination") ?? "") ?? .none
        autoUpload = d.object(forKey: "autoUpload") as? Bool ?? true
        uploadQuality = UploadQuality(rawValue: d.string(forKey: "uploadQuality") ?? "") ?? .hd1080
        createSharePage = d.object(forKey: "createSharePage") as? Bool ?? true
        openLinkAfterUpload = d.object(forKey: "openLinkAfterUpload") as? Bool ?? false
        levelVoice = d.object(forKey: "levelVoice") as? Bool ?? true

        spacesEndpoint = d.string(forKey: "spaces.endpoint") ?? "nyc3.digitaloceanspaces.com"
        spacesRegion = d.string(forKey: "spaces.region") ?? "nyc3"
        spacesBucket = d.string(forKey: "spaces.bucket") ?? ""
        spacesAccessKey = d.string(forKey: "spaces.accessKey") ?? ""
        spacesPrefix = d.string(forKey: "spaces.prefix") ?? "recordings"
        spacesPublicBaseURL = d.string(forKey: "spaces.publicBaseURL") ?? ""
        spacesLinkAccess = LinkAccess(rawValue: d.string(forKey: "spaces.linkAccess") ?? "") ?? .publicLink
        spacesPathStyle = d.object(forKey: "spaces.pathStyle") as? Bool ?? false

        driveClientID = d.string(forKey: "drive.clientID") ?? ""
        driveAccount = d.string(forKey: "drive.account") ?? ""
        driveFolderID = d.string(forKey: "drive.recordingsFolderID") ?? ""
        driveAnyoneWithLink = d.object(forKey: "drive.anyoneWithLink") as? Bool ?? true

        serverMethod = ServerMethod(rawValue: d.string(forKey: "server.method") ?? "") ?? .sftp
        serverHost = d.string(forKey: "server.host") ?? ""
        let port = d.integer(forKey: "server.port")
        serverPort = (1...65535).contains(port) ? port : 22
        serverUser = d.string(forKey: "server.user") ?? ""
        serverRemotePath = d.string(forKey: "server.remotePath") ?? ""
        serverKeyPath = d.string(forKey: "server.keyPath") ?? ""
        serverUploadURL = d.string(forKey: "server.uploadURL") ?? ""
        serverPublicBaseURL = d.string(forKey: "server.publicBaseURL") ?? ""

        hasCompletedOnboarding = d.bool(forKey: "onboarded")

        fontStyle = AppFontStyle(rawValue: d.string(forKey: "appearance.fontStyle") ?? "") ?? .standard
        textSize = AppTextSize(rawValue: d.string(forKey: "appearance.textSize") ?? "") ?? .standard
        checkForUpdatesAutomatically = d.object(forKey: "updates.automatic") as? Bool ?? true
    }

    /// One-time move from the app's previous name (ScrCapKit): copies its settings and renames its
    /// default recordings folder. Secrets are not copied, because the old Keychain items belong to
    /// the old app identity and reading them would trigger a Keychain prompt.
    static func migrateFromOldName() {
        let d = UserDefaults.standard
        let doneKey = "migratedFromScrCapKit"
        guard !d.bool(forKey: doneKey) else { return }
        defer { d.set(true, forKey: doneKey) }

        let oldDomain = "com.tawfiq.scrcapkit"
        if let current = Bundle.main.bundleIdentifier, current != oldDomain,
           let old = d.persistentDomain(forName: oldDomain), !old.isEmpty,
           d.persistentDomain(forName: current)?.isEmpty ?? true {
            for (key, value) in old { d.set(value, forKey: key) }
            Log.app.info("Copied \(old.count) settings from ScrCapKit")
        }

        // Recordings folder and upload history (Application Support).
        let fm = FileManager.default
        var parents = [defaultRecordingsFolder.deletingLastPathComponent()]
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first { parents.append(support) }
        for parent in parents {
            let old = parent.appendingPathComponent("ScrCapKit", isDirectory: true)
            let new = parent.appendingPathComponent("TRecShare", isDirectory: true)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            do {
                try fm.moveItem(at: old, to: new)
                Log.app.info("Moved \(old.path) to the new name")
            } catch {
                Log.app.error("Could not move \(old.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Derived

    static var defaultRecordingsFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("TRecShare", isDirectory: true)
    }

    var recordingsFolder: URL {
        if let path = saveFolderPath, !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return Self.defaultRecordingsFolder
    }

    /// What is still missing before uploads to `destination` can work (nil = ready).
    func missingSetup(for destination: UploadDestination) -> String? {
        switch destination {
        case .none:
            return "Choose where to upload in Settings → Uploads."
        case .spaces:
            if spacesEndpoint.trimmed.isEmpty || spacesBucket.trimmed.isEmpty || spacesAccessKey.trimmed.isEmpty
                || !Keychain.has(.spacesSecret) {
                return "Add your Spaces endpoint, bucket and access keys in Settings → Uploads."
            }
        case .drive:
            if driveClientID.trimmed.isEmpty || !Keychain.has(.driveRefreshToken) {
                return "Sign in to Google Drive in Settings → Uploads."
            }
        case .server:
            switch serverMethod {
            case .sftp:
                if serverHost.trimmed.isEmpty || serverUser.trimmed.isEmpty || serverRemotePath.trimmed.isEmpty
                    || serverPublicBaseURL.trimmed.isEmpty {
                    return "Add your server's host, user, folder and public URL in Settings → Uploads."
                }
            case .http:
                if serverUploadURL.trimmed.isEmpty || serverPublicBaseURL.trimmed.isEmpty {
                    return "Add your server's upload URL and public URL in Settings → Uploads."
                }
            }
        }
        return nil
    }

    var canUpload: Bool { uploadDestination != .none && missingSetup(for: uploadDestination) == nil }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("Launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
