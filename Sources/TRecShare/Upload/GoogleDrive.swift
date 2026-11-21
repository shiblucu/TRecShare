import AppKit
import CryptoKit
import Foundation
import Network

/// Google sign-in for desktop apps: OAuth 2.0 with PKCE and a one-time loopback redirect on 127.0.0.1.
/// Only the `drive.file` scope is requested, so the app can see just the files it uploads.
enum GoogleAuth {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    struct Tokens: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
    }

    /// Opens the browser, waits for the redirect and stores the refresh token in the Keychain.
    /// Returns the account email.
    @MainActor
    static func signIn(clientID: String, clientSecret: String?) async throws -> String {
        let verifier = RandomID.make(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = RandomID.make(length: 24)
        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }
        let port = try await receiver.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: authURL)!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        NSWorkspace.shared.open(comps.url!)

        let params = try await receiver.waitForRedirect(timeout: 300)
        guard params["state"] == state else { throw UploadError("Sign-in was interrupted (state mismatch). Please try again.") }
        if let error = params["error"] { throw UploadError("Google sign-in was cancelled (\(error)).") }
        guard let code = params["code"] else { throw UploadError("Google didn't return a sign-in code.") }

        var form: [String: String] = [
            "code": code, "client_id": clientID, "redirect_uri": redirect,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ]
        if let clientSecret, !clientSecret.isEmpty { form["client_secret"] = clientSecret }
        let tokens = try await postForm(tokenURL, form)
        guard let refresh = tokens.refresh_token else {
            throw UploadError("Google didn't grant offline access. Remove TRecShare from your Google account's third-party access and sign in again.")
        }
        Keychain.set(refresh, for: .driveRefreshToken)
        await TokenStore.shared.set(tokens.access_token, expiresIn: tokens.expires_in ?? 3600)
        let email = (try? await DriveClient(clientID: clientID, clientSecret: clientSecret).accountEmail()) ?? "Google account"
        return email
    }

    @MainActor
    static func signOut() {
        if let token = Keychain.get(.driveRefreshToken) {
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = formBody(["token": token])
            Task { _ = try? await HTTP.send(req) }
        }
        Keychain.delete(.driveRefreshToken)
        Task { await TokenStore.shared.clear() }
    }

    static func postForm(_ url: URL, _ form: [String: String]) async throws -> Tokens {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody(form)
        let (data, resp) = try await HTTP.send(req)
        guard (200...299).contains(resp.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error_description"] as? String) ?? ($0["error"] as? String) } ?? "HTTP \(resp.statusCode)"
            if message.contains("invalid_grant") || message.lowercased().contains("expired or revoked") {
                Keychain.delete(.driveRefreshToken)
                throw UploadError("Your Google sign-in has expired. Sign in again in Settings → Uploads.")
            }
            throw UploadError("Google sign-in failed: \(message)")
        }
        return try JSONDecoder().decode(Tokens.self, from: data)
    }

    static func formBody(_ form: [String: String]) -> Data {
        Data(form.map { "\(SigV4.encode($0.key))=\(SigV4.encode($0.value))" }.joined(separator: "&").utf8)
    }
}

/// Caches the short-lived access token in memory only.
actor TokenStore {
    static let shared = TokenStore()
    private var token: String?
    private var expiry = Date.distantPast

    func set(_ token: String, expiresIn: Int) {
        self.token = token
        expiry = Date().addingTimeInterval(TimeInterval(max(expiresIn - 60, 30)))
    }

    func clear() { token = nil; expiry = .distantPast }

    func valid() -> String? { Date() < expiry ? token : nil }
}

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth redirect's query string.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "trecshare.oauth-loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if once.claim() { c.resume(returning: self.listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { c.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { c in
                    self.lock.withLock { self.continuation = c }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw UploadError("Google sign-in timed out. Please try again.")
            }
            defer { group.cancelAll() }
            let result = try await group.next()!
            return result
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            var params: [String: String] = [:]
            if parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: String(parts[1])) {
                for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
            }
            let isCallback = params["code"] != nil || params["error"] != nil
            let body = isCallback
                ? "<!doctype html><meta charset=utf-8><title>TRecShare</title><body style=\"font:16px -apple-system,sans-serif;text-align:center;padding:60px\"><h2>You're signed in.</h2><p>You can close this tab and go back to TRecShare.</p></body>"
                : "Not found"
            let status = isCallback ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(body)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isCallback {
                self.lock.withLock {
                    self.continuation?.resume(returning: params)
                    self.continuation = nil
                }
            }
        }
    }
}

/// Thread-safe "only once" flag.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

/// Google Drive v3 REST client (resumable uploads, sharing).
struct DriveClient: Sendable {
    let clientID: String
    let clientSecret: String?

    static let chunkSize = 8 * 1024 * 1024   // must be a multiple of 256 KiB

    func accessToken() async throws -> String {
        if let token = await TokenStore.shared.valid() { return token }
        guard let refresh = Keychain.get(.driveRefreshToken) else {
            throw UploadError("Sign in to Google Drive in Settings → Uploads.")
        }
        var form = ["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"]
        if let clientSecret, !clientSecret.isEmpty { form["client_secret"] = clientSecret }
        let tokens = try await GoogleAuth.postForm(GoogleAuth.tokenURL, form)
        await TokenStore.shared.set(tokens.access_token, expiresIn: tokens.expires_in ?? 3600)
        return tokens.access_token
    }

    func json(_ method: String, _ url: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        var payload: HTTP.Body = .none
        if let body {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            payload = .data(try JSONSerialization.data(withJSONObject: body))
        }
        let (data, resp) = try await HTTP.send(req, body: payload)
        guard (200...299).contains(resp.statusCode) else { throw Self.apiError(data, resp) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func apiError(_ data: Data, _ resp: HTTPURLResponse) -> Error {
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let message = obj?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: resp.statusCode)
        if resp.statusCode == 401 { Task { await TokenStore.shared.clear() } }
        if resp.statusCode == 403, message.lowercased().contains("api has not been used") || message.lowercased().contains("disabled") {
            return UploadError("The Google Drive API is turned off for your Google Cloud project. Enable it, then try again.")
        }
        let error = UploadError("Google Drive: \(message)")
        return HTTP.isRetryable(status: resp.statusCode) ? HTTP.RetryableError(underlying: error) : error
    }

    func accountEmail() async throws -> String {
        let about = try await json("GET", "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress,displayName)")
        let user = about["user"] as? [String: Any]
        return user?["emailAddress"] as? String ?? user?["displayName"] as? String ?? "Google account"
    }

    /// Returns the ID of the "TRecShare" › "Recordings" folder where uploads go, creating whichever folders are missing.
    /// Existing folders are reused (TRecShare can only see folders it created itself).
    func ensureFolder(knownID: String) async throws -> String {
        if !knownID.isEmpty, knownID.range(of: #"^[A-Za-z0-9_-]{10,200}$"#, options: .regularExpression) != nil,
           let file = try? await json("GET", "https://www.googleapis.com/drive/v3/files/\(knownID)?fields=id,trashed"),
           (file["trashed"] as? Bool) == false {
            return knownID
        }
        let root = try await findOrCreateFolder(named: "TRecShare", in: "root")
        return try await findOrCreateFolder(named: "Recordings", in: root)
    }

    private func findOrCreateFolder(named name: String, in parent: String) async throws -> String {
        let query = "name = '\(name)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false and '\(parent)' in parents"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let found = try await json("GET", "https://www.googleapis.com/drive/v3/files?q=\(encoded)&fields=files(id)&pageSize=1&orderBy=createdTime")
        if let id = (found["files"] as? [[String: Any]])?.first?["id"] as? String { return id }
        let created = try await json("POST", "https://www.googleapis.com/drive/v3/files?fields=id",
                                     body: ["name": name, "mimeType": "application/vnd.google-apps.folder", "parents": [parent]])
        guard let id = created["id"] as? String else { throw UploadError("Could not create the \(name) folder in Drive.") }
        return id
    }

    /// Resumable upload in 8 MB chunks. Returns (fileID, webViewLink).
    func uploadFile(_ file: URL, name: String, folderID: String,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> (String, String?) {
        let size = Int(file.fileSize)
        // 1. Start a resumable session.
        let sessionURL: URL = try await HTTP.withRetry {
            var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
            req.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            let meta = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [folderID], "mimeType": "video/mp4"])
            let (data, resp) = try await HTTP.send(req, body: .data(meta))
            guard (200...299).contains(resp.statusCode), let loc = resp.value(forHTTPHeaderField: "Location"),
                  let url = URL(string: loc) else { throw Self.apiError(data, resp) }
            return url
        }

        // 2. Send chunks; on a network error ask the server how much it has and continue from there.
        var offset = 0
        var failures = 0
        while true {
            try Task.checkCancellation()
            let length = min(Self.chunkSize, size - offset)
            var req = URLRequest(url: sessionURL)
            req.httpMethod = "PUT"
            let body: Data
            if length > 0 {
                body = try S3Client.read(file, offset: offset, length: length)
                req.setValue("bytes \(offset)-\(offset + length - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            } else {
                body = Data()
                req.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
            }
            let base = offset
            do {
                let (data, resp) = try await HTTP.send(req, body: .data(body)) { sent in
                    progress(size > 0 ? Double(base + Int(sent)) / Double(size) : 1)
                }
                switch resp.statusCode {
                case 200, 201:
                    let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                    guard let id = obj["id"] as? String else { throw UploadError("Google Drive didn't return the file.") }
                    progress(1)
                    return (id, obj["webViewLink"] as? String)
                case 308:
                    offset = Self.nextOffset(resp) ?? (offset + length)
                    failures = 0
                case 404, 410:
                    throw UploadError("The Google Drive upload session expired. Please upload again.")
                default:
                    throw Self.apiError(data, resp)
                }
            } catch let error as HTTP.RetryableError {
                failures += 1
                if failures > 5 { throw error.underlying }
                try await Task.sleep(for: .seconds(Double(1 << min(failures, 5))))
                offset = try await queryOffset(sessionURL, size: size) ?? offset
            } catch let error as URLError where error.code != .cancelled {
                failures += 1
                if failures > 5 { throw error }
                try await Task.sleep(for: .seconds(Double(1 << min(failures, 5))))
                offset = try await queryOffset(sessionURL, size: size) ?? offset
            }
        }
    }

    private static func nextOffset(_ resp: HTTPURLResponse) -> Int? {
        // "Range: bytes=0-12345" → next byte is 12346
        guard let range = resp.value(forHTTPHeaderField: "Range"), let last = range.split(separator: "-").last,
              let end = Int(last) else { return nil }
        return end + 1
    }

    private func queryOffset(_ sessionURL: URL, size: Int) async throws -> Int? {
        var req = URLRequest(url: sessionURL)
        req.httpMethod = "PUT"
        req.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
        let (_, resp) = try await HTTP.send(req, body: .data(Data()))
        return resp.statusCode == 308 ? (Self.nextOffset(resp) ?? 0) : nil
    }

    func shareWithAnyone(fileID: String) async throws {
        _ = try await json("POST", "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions?fields=id",
                           body: ["role": "reader", "type": "anyone"])
    }
}

struct DriveUploader: Uploader {
    let client: DriveClient
    let folderID: String
    let anyoneWithLink: Bool
    let onFolderID: @Sendable (String) -> Void

    @MainActor
    static func fromSettings() throws -> DriveUploader {
        let s = AppSettings.shared
        guard !s.driveClientID.trimmed.isEmpty else { throw UploadError("Add your Google OAuth client ID in Settings → Uploads.") }
        guard Keychain.has(.driveRefreshToken) else { throw UploadError("Sign in to Google Drive in Settings → Uploads.") }
        return DriveUploader(client: DriveClient(clientID: s.driveClientID.trimmed, clientSecret: Keychain.get(.driveClientSecret)),
                             folderID: s.driveFolderID, anyoneWithLink: s.driveAnyoneWithLink,
                             onFolderID: { id in Task { @MainActor in AppSettings.shared.driveFolderID = id } })
    }

    func upload(_ item: UploadItem, progress: @escaping @Sendable (Double) -> Void) async throws -> UploadResult {
        let folder = try await client.ensureFolder(knownID: folderID)
        if folder != folderID { onFolderID(folder) }
        let name = FileNames.sanitize(item.title) + ".mp4"
        let (id, webLink) = try await client.uploadFile(item.file, name: name, folderID: folder) { progress($0 * 0.98) }
        if anyoneWithLink { try await client.shareWithAnyone(fileID: id) }
        progress(1)
        let fallback = "https://drive.google.com/file/d/\(SigV4.encode(id))/view"
        guard let link = webLink.flatMap(URL.init(string:)).flatMap({ $0.scheme == "https" ? $0 : nil }) ?? URL(string: fallback) else {
            throw UploadError("Google Drive didn't return a usable link.")
        }
        return UploadResult(destination: UploadDestination.drive.rawValue, link: link, videoURL: nil,
                            remoteID: id, uploadedAt: Date(), expiresAt: nil)
    }

    func testConnection() async throws -> String {
        let email = try await client.accountEmail()
        return "Connected to Google Drive as \(email)."
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
