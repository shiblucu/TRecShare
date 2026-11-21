import AppKit
import UserNotifications

/// macOS notifications: recording saved, upload finished (link copied), upload failed.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()

    private enum Category {
        static let recording = "recordingSaved"
        static let upload = "uploadFinished"
        static let screenshot = "screenshotSaved"
        static let update = "updateAvailable"
    }

    func setUp() {
        center.delegate = self
        let show = UNNotificationAction(identifier: "show", title: "Show in Finder", options: [.foreground])
        let play = UNNotificationAction(identifier: "play", title: "Play", options: [.foreground])
        let open = UNNotificationAction(identifier: "open", title: "Open Link", options: [.foreground])
        let openImage = UNNotificationAction(identifier: "play", title: "Open", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.recording, actions: [show, play], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.upload, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.screenshot, actions: [show, openImage], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.update,
                                   actions: [UNNotificationAction(identifier: "open", title: "Download", options: [.foreground])],
                                   intentIdentifiers: []),
        ])
        // Permission is asked for in the Welcome window (where it's explained), not at launch.
        if AppSettings.shared.hasCompletedOnboarding { requestPermissionIfNeeded() }
    }

    /// Shows the system prompt the first time; does nothing once the user has answered.
    func requestPermissionIfNeeded(then done: (@Sendable () -> Void)? = nil) {
        center.getNotificationSettings { [center] settings in
            guard settings.authorizationStatus == .notDetermined else { done?(); return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if !granted { Log.app.info("notifications not allowed") }
                done?()
            }
        }
    }

    func recordingSaved(_ url: URL, title: String = "Recording saved") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = url.lastPathComponent
        content.sound = .default
        content.categoryIdentifier = Category.recording
        content.userInfo = ["path": url.path]
        post(content)
    }

    func screenshotSaved(_ url: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Screenshot saved · copied to clipboard"
        content.body = url.lastPathComponent
        content.sound = .default
        content.categoryIdentifier = Category.screenshot
        content.userInfo = ["path": url.path]
        post(content)
    }

    func uploadFinished(link: URL, title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Uploaded · link copied"
        content.body = title
        content.sound = .default
        content.categoryIdentifier = Category.upload
        content.userInfo = ["link": link.absoluteString]
        post(content)
    }

    func updateAvailable(version: String, page: URL) {
        let content = UNMutableNotificationContent()
        content.title = "TRecShare \(version) is available"
        content.body = "Click to open the download page."
        content.categoryIdentifier = Category.update
        content.userInfo = ["link": page.absoluteString]
        post(content)
    }

    func uploadsFinished(done: Int, failed: Int) {
        let content = UNMutableNotificationContent()
        content.title = failed == 0 ? "\(done) \(done == 1 ? "upload" : "uploads") finished" : "Uploads finished with \(failed) \(failed == 1 ? "error" : "errors")"
        content.body = failed == 0 ? "Open the Library to copy the links." : "\(done) uploaded, \(failed) failed. Open the Library to retry."
        content.sound = .default
        post(content)
    }

    func uploadFailed(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Upload failed"
        content.body = "\(title): \(message)"
        content.sound = .default
        post(content)
    }

    private func post(_ content: UNNotificationContent) {
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler handler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let path = info["path"] as? String
        let link = info["link"] as? String
        Task { @MainActor in
            if let link, let url = URL(string: link), ["https", "http"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            } else if let path {
                let url = URL(fileURLWithPath: path)
                switch action {
                case "play": NSWorkspace.shared.open(url)
                case "show": NSWorkspace.shared.activateFileViewerSelecting([url])
                default:
                    if url.pathExtension.lowercased() == "png" { NSWorkspace.shared.open(url) } else { WindowRouter.shared.showReview(url) }
                }
            }
            handler()
        }
    }
}
