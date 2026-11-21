import Foundation

/// What gets uploaded: the (possibly re-encoded) video plus details for the share page.
struct UploadItem: Sendable {
    let file: URL
    let title: String
    let poster: URL?
    let duration: TimeInterval
    let width: Int
    let height: Int
    let recordedAt: Date
}

struct UploadResult: Codable, Equatable, Sendable {
    var destination: String
    var link: URL
    var videoURL: URL?
    var remoteID: String?
    var uploadedAt: Date
    var expiresAt: Date?
    /// Which bucket / account / server received it, so a later delete can't hit a different one if Settings changed.
    /// nil for uploads made before this was recorded.
    var account: String?
}

protocol Uploader: Sendable {
    func upload(_ item: UploadItem, progress: @escaping @Sendable (Double) -> Void) async throws -> UploadResult
    /// Checks the settings with a tiny request. Returns a short success message.
    func testConnection() async throws -> String
    /// Removes what `upload` created. A copy that is already gone counts as deleted.
    func deleteUpload(_ result: UploadResult) async throws
}

extension UploadError {
    /// Refuses to delete when Settings now point somewhere else than where the copy was uploaded.
    static func checkAccount(saved: String?, current: String, what: String) throws {
        guard let saved, !saved.isEmpty, saved != current else { return }
        throw UploadError("This copy was uploaded to \(what) “\(saved)”, but Settings now use “\(current)”. Switch Settings back to delete it.")
    }
}

struct UploadError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Shared HTTP plumbing: a dedicated session, upload progress and retries.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60 * 6
        // Fail fast when offline (withRetry tries again a few times) instead of silently waiting for hours.
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpAdditionalHeaders = ["User-Agent": "\(AppInfo.userAgentName)/\(AppInfo.version)"]
        return URLSession(configuration: config)
    }()

    /// Reports bytes sent for one request.
    final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let onSent: @Sendable (Int64) -> Void
        init(_ onSent: @escaping @Sendable (Int64) -> Void) { self.onSent = onSent }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            onSent(totalBytesSent)
        }
    }

    enum Body: Sendable {
        case none
        case data(Data)
        case file(URL)
    }

    static func send(_ request: URLRequest, body: Body = .none,
                     onSent: (@Sendable (Int64) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        let delegate = onSent.map { ProgressDelegate($0) }
        let result: (Data, URLResponse)
        switch body {
        case .none:
            result = try await session.data(for: request, delegate: delegate)
        case .data(let data):
            result = try await session.upload(for: request, from: data, delegate: delegate)
        case .file(let url):
            result = try await session.upload(for: request, fromFile: url, delegate: delegate)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw UploadError("The server sent an invalid response.") }
        return (result.0, http)
    }

    /// Retries network failures and 5xx/429 responses with backoff. `make` builds a fresh, signed request each time.
    static func withRetry<T>(attempts: Int = 4, _ operation: () async throws -> T) async throws -> T {
        var delay: UInt64 = 1
        var lastError: Error = UploadError("Upload failed.")
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch let error as RetryableError {
                lastError = error.underlying
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                                                  .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
                lastError = error
            }
            if attempt < attempts {
                Log.upload.info("retrying in \(delay)s (attempt \(attempt) failed: \(lastError.localizedDescription))")
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay *= 2
            }
        }
        throw lastError
    }

    struct RetryableError: Error { let underlying: Error }

    static func isRetryable(status: Int) -> Bool { status == 429 || (500...599).contains(status) }

    /// Makes sure a user-entered URL is HTTPS (plain HTTP only for localhost testing).
    static func validatedURL(_ string: String, what: String) throws -> URL {
        let s = string.trimmed
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            throw UploadError("\(what) is not a valid URL.")
        }
        let local = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && local) else {
            throw UploadError("\(what) must start with https:// so uploads are encrypted.")
        }
        return url
    }
}

/// Joins a base URL and a relative path with exactly one slash.
func joinURL(_ base: String, _ path: String) -> String {
    var b = base.trimmed
    while b.hasSuffix("/") { b.removeLast() }
    var p = path
    while p.hasPrefix("/") { p.removeFirst() }
    return "\(b)/\(p)"
}
