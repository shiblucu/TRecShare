import Foundation

/// Uploads to your own server (VPS) and builds the link from your public URL.
/// - SFTP: runs macOS's `/usr/bin/sftp` in batch mode with your SSH key (no passwords stored).
/// - HTTPS: PUTs files (WebDAV-style) with an optional bearer token from the Keychain.
struct ServerUploader: Uploader {
    enum Method: Sendable {
        case sftp(host: String, port: Int, user: String, remotePath: String, keyPath: String?)
        case http(uploadURL: URL, token: String?)
    }

    let method: Method
    let publicBaseURL: String
    let createSharePage: Bool

    @MainActor
    static func fromSettings() throws -> ServerUploader {
        let s = AppSettings.shared
        let base = try HTTP.validatedURL(s.serverPublicBaseURL, what: "The public URL").absoluteString
        switch s.serverMethod {
        case .sftp:
            let host = s.serverHost.trimmed, user = s.serverUser.trimmed, path = s.serverRemotePath.trimmed
            guard host.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]*$|^\[[0-9A-Fa-f:]+\]$"#, options: .regularExpression) != nil else {
                throw UploadError("The server host isn't valid. Use a name like example.com or an IP address.")
            }
            guard user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._\-]*$"#, options: .regularExpression) != nil else {
                throw UploadError("The SSH user name isn't valid.")
            }
            guard !path.isEmpty, path.rangeOfCharacter(from: CharacterSet(charactersIn: "\"\n\r\\")) == nil else {
                throw UploadError("The server folder can't be empty or contain quotes.")
            }
            var key: String?
            let keyPath = (s.serverKeyPath.trimmed as NSString).expandingTildeInPath
            if !s.serverKeyPath.trimmed.isEmpty {
                guard FileManager.default.isReadableFile(atPath: keyPath) else { throw UploadError("The SSH key file can't be read.") }
                key = keyPath
            }
            return ServerUploader(method: .sftp(host: host, port: s.serverPort, user: user, remotePath: path, keyPath: key),
                                  publicBaseURL: base, createSharePage: s.createSharePage)
        case .http:
            let url = try HTTP.validatedURL(s.serverUploadURL, what: "The upload URL")
            return ServerUploader(method: .http(uploadURL: url, token: Keychain.get(.serverToken)),
                                  publicBaseURL: base, createSharePage: s.createSharePage)
        }
    }

    func upload(_ item: UploadItem, progress: @escaping @Sendable (Double) -> Void) async throws -> UploadResult {
        let slug = FileNames.slug(item.title)
        let folder = "\(item.recordedAt.formatted(.iso8601.year().month()))-\(slug)-\(RandomID.make(length: 14))"
        let videoName = "\(slug).mp4"
        let downloadName = FileNames.sanitize(item.title) + ".mp4"
        let videoURL = URL(string: joinURL(publicBaseURL, "\(folder)/\(videoName)"))!

        // Stage files under safe names (the original name may contain any characters).
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("scrcapkit-upload-\(RandomID.make(length: 8))")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        var files: [(local: URL, remote: String, type: String)] = []
        let stagedVideo = stage.appendingPathComponent(videoName)
        try FileManager.default.copyItem(at: item.file, to: stagedVideo)   // APFS clone: instant, no extra space
        files.append((stagedVideo, videoName, "video/mp4"))
        if let poster = item.poster {
            let p = stage.appendingPathComponent("poster.jpg")
            try FileManager.default.copyItem(at: poster, to: p)
            files.append((p, "poster.jpg", "image/jpeg"))
        }
        var link = videoURL
        if createSharePage {
            let page = SharePage.html(title: item.title, videoURL: videoName, posterURL: item.poster == nil ? nil : "poster.jpg",
                                      downloadName: downloadName, duration: item.duration, recordedAt: item.recordedAt,
                                      width: item.width, height: item.height)
            let p = stage.appendingPathComponent("index.html")
            try Data(page.utf8).write(to: p)
            files.append((p, "index.html", "text/html; charset=utf-8"))
            link = URL(string: joinURL(publicBaseURL, "\(folder)/index.html"))!
        }

        switch method {
        case let .sftp(host, port, user, remotePath, keyPath):
            progress(-1)   // sftp batch mode can't report progress
            var commands = ["-mkdir \"\(remotePath)/\(folder)\"", "-chmod 755 \"\(remotePath)/\(folder)\""]
            for f in files {
                commands.append("put \"\(f.local.path)\" \"\(remotePath)/\(folder)/\(f.remote)\"")
                commands.append("-chmod 644 \"\(remotePath)/\(folder)/\(f.remote)\"")
            }
            try await SFTP.run(commands, host: host, port: port, user: user, keyPath: keyPath)
        case let .http(uploadURL, token):
            let folderURL = URL(string: joinURL(uploadURL.absoluteString, folder + "/"))!
            var mk = URLRequest(url: folderURL)
            mk.httpMethod = "MKCOL"
            if let token, !token.isEmpty { mk.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            _ = try? await HTTP.send(mk)   // fine if the server creates folders on PUT
            let total = files.reduce(Int64(0)) { $0 + $1.local.fileSize }
            var done: Int64 = 0
            for f in files {
                let size = f.local.fileSize
                let base = done
                try await HTTP.withRetry {
                    var req = URLRequest(url: URL(string: joinURL(folderURL.absoluteString, f.remote))!)
                    req.httpMethod = "PUT"
                    req.setValue(f.type, forHTTPHeaderField: "Content-Type")
                    if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                    let (data, resp) = try await HTTP.send(req, body: .file(f.local)) { sent in
                        progress(total > 0 ? Double(base + sent) / Double(total) : 1)
                    }
                    try Self.check(data, resp)
                }
                done += size
            }
        }
        progress(1)
        return UploadResult(destination: UploadDestination.server.rawValue, link: link, videoURL: videoURL,
                            remoteID: folder, uploadedAt: Date(), expiresAt: nil)
    }

    static func check(_ data: Data, _ resp: HTTPURLResponse) throws {
        guard (200...299).contains(resp.statusCode) else {
            let detail = String(data: data.prefix(300), encoding: .utf8)?.trimmed ?? ""
            let message: String
            switch resp.statusCode {
            case 401, 403: message = "The server refused the upload (\(resp.statusCode)). Check the access token."
            case 404: message = "The upload URL wasn't found on the server (404)."
            case 405: message = "The server doesn't accept uploads at this URL (405). Enable WebDAV/PUT."
            case 413: message = "The server says the file is too large (413). Raise its upload size limit."
            default: message = "The server answered \(resp.statusCode). \(detail)"
            }
            let error = UploadError(message)
            if HTTP.isRetryable(status: resp.statusCode) { throw HTTP.RetryableError(underlying: error) }
            throw error
        }
    }

    func testConnection() async throws -> String {
        switch method {
        case let .sftp(host, port, user, remotePath, keyPath):
            try await SFTP.run(["cd \"\(remotePath)\"", "pwd"], host: host, port: port, user: user, keyPath: keyPath)
            return "Connected to \(host) and found \(remotePath)."
        case let .http(uploadURL, token):
            let url = URL(string: joinURL(uploadURL.absoluteString, ".scrcapkit-check-\(RandomID.make(length: 8)).txt"))!
            var put = URLRequest(url: url)
            put.httpMethod = "PUT"
            put.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            if let token, !token.isEmpty { put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, resp) = try await HTTP.send(put, body: .data(Data("ok".utf8)))
            try Self.check(data, resp)
            var del = URLRequest(url: url)
            del.httpMethod = "DELETE"
            if let token, !token.isEmpty { del.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            _ = try? await HTTP.send(del)
            return "Upload test to \(uploadURL.host ?? "your server") worked."
        }
    }
}

/// Runs `/usr/bin/sftp -b` with arguments passed directly (no shell), so nothing can be injected.
enum SFTP {
    static func run(_ commands: [String], host: String, port: Int, user: String, keyPath: String?) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scrcapkit-sftp-\(RandomID.make(length: 8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let batch = dir.appendingPathComponent("batch.txt")
        try Data((commands.joined(separator: "\n") + "\n").utf8).write(to: batch)

        var args = ["-b", batch.path, "-P", String(port),
                    "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15"]
        if let keyPath { args += ["-i", keyPath, "-o", "IdentitiesOnly=yes"] }
        args.append("\(user)@\(host)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                process.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { c.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        if status != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmed ?? ""
            let lower = err.lowercased()
            if lower.contains("permission denied (publickey") {
                throw UploadError("The server didn't accept your SSH key. Add the key in Settings or to ssh-agent.")
            } else if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
                throw UploadError("The server's SSH host key changed. Check ~/.ssh/known_hosts before trying again.")
            } else if lower.contains("could not resolve") || lower.contains("connection refused") || lower.contains("timed out") {
                throw UploadError("Couldn't reach \(host):\(port). Check the host and port.")
            }
            let lastLine = err.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? "exit code \(status)"
            throw UploadError("SFTP failed: \(lastLine)")
        }
    }
}
