import AppKit
import Foundation

/// Checks GitHub Releases for a newer version of TRecShare.
///
/// One anonymous request to `github.com/<repo>/releases/latest`, which redirects to the newest release's tag page
/// (or to the releases list when nothing is published). The public page is used instead of the REST API because the
/// API allows only 60 anonymous requests an hour per network. Nothing about the user is sent besides the
/// app's name and version in the User-Agent. Installing stays manual: the download page opens in the browser.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repository = "shiblucu/TRecShare"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    private static let latestPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    private static let lastCheckKey = "updates.lastCheck"
    private static let interval: TimeInterval = 24 * 3600

    struct Release: Equatable {
        let version: String
        let page: URL
        let notes: String
    }

    enum Status: Equatable {
        case idle, checking, upToDate, noReleases
        case available(Release)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
    private var timer: Timer?
    private var notifiedVersion: String?

    /// Starts the daily background check (when it's turned on in Settings).
    func startAutomaticChecks() {
        timer?.invalidate()
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Shortly after launch, so it never slows down starting the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard AppSettings.shared.checkForUpdatesAutomatically else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < Self.interval { return }
        Task { await check(userInitiated: false) }
    }

    /// Checks now. `userInitiated` shows the result in an alert; background checks only notify about new versions.
    func check(userInitiated: Bool) async {
        guard status != .checking else { return }
        status = .checking
        do {
            var request = URLRequest(url: Self.latestPage)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 20
            let (_, response) = try await HTTP.send(request)   // follows the redirect
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckKey)
            switch response.statusCode {
            case 200:
                guard let release = Self.release(from: response.url) else {
                    status = .noReleases
                    break
                }
                if Self.isNewer(release.version, than: AppInfo.version) {
                    status = .available(release)
                    if !userInitiated, notifiedVersion != release.version {
                        notifiedVersion = release.version
                        Notifier.shared.updateAvailable(version: release.version, page: release.page)
                    }
                } else {
                    status = .upToDate
                }
            case 404:
                status = .noReleases
            case 403, 429:
                throw UploadError("GitHub is limiting requests right now. Try again later.")
            default:
                throw UploadError("GitHub answered \(response.statusCode).")
            }
        } catch {
            status = .failed(error.localizedDescription)
            Log.app.error("update check failed: \(error.localizedDescription)")
        }
        if userInitiated { showResultAlert() }
    }

    private func showResultAlert() {
        let alert = NSAlert()
        switch status {
        case .available(let release):
            alert.messageText = "TRecShare \(release.version) is available"
            alert.informativeText = "You have \(AppInfo.version). Download the new version from GitHub (the release notes are on that page), then replace the app in your Applications folder."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
            return
        case .upToDate:
            alert.messageText = "You're up to date"
            alert.informativeText = "TRecShare \(AppInfo.version) is the newest version."
        case .noReleases:
            alert.messageText = "No releases published yet"
            alert.informativeText = "There's no downloadable version of TRecShare on GitHub yet. You're using \(AppInfo.version)."
        case .failed(let message):
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
        case .idle, .checking:
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Parsing (internal for tests)

    /// Reads the release from the page GitHub redirected to: `https://github.com/<repo>/releases/tag/<tag>`.
    /// Returns nil when there is no release yet (GitHub then lands on the releases list).
    static func release(from finalURL: URL?) -> Release? {
        guard let url = finalURL, url.scheme == "https", url.host == "github.com" else { return nil }
        let parts = url.pathComponents   // ["/", owner, repo, "releases", "tag", tag]
        guard parts.count >= 6, parts[3] == "releases", parts[4] == "tag",
              "\(parts[1])/\(parts[2])".lowercased() == repository.lowercased() else { return nil }
        let tag = parts[5].removingPercentEncoding ?? parts[5]
        guard tag.range(of: #"^v?[0-9]+(\.[0-9]+)*([-+][A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil else { return nil }
        return Release(version: normalized(tag), page: url, notes: "")
    }

    /// "v1.2.0" → "1.2.0"
    static func normalized(_ tag: String) -> String {
        var t = tag.trimmed
        if t.lowercased().hasPrefix("v") { t.removeFirst() }
        return t
    }

    /// Compares dotted version numbers: 1.10 > 1.9, 1.0.1 > 1.0, "1.0" == "1.0.0".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            normalized(s).split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [0]
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
