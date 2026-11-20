import AppKit
import AVFoundation
import CoreGraphics

/// Screen Recording, Microphone and Camera permission helpers.
enum Permissions {
    enum Status { case granted, denied, notAsked }

    static func status(for media: AVMediaType) -> Status {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// Asks the first time; afterwards returns the saved answer.
    static func request(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    /// True once the user has allowed Screen Recording for this app.
    static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (only the first time) and adds the app to the Settings list.
    @discardableResult
    static func requestScreenAccess() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    static func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
