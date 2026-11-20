import Foundation

/// Minimal S3 client (DigitalOcean Spaces, AWS S3, Cloudflare R2, MinIO, Backblaze B2…).
struct S3Client: Sendable {
    let endpoint: String      // host only, e.g. "nyc3.digitaloceanspaces.com"
    let bucket: String
    let pathStyle: Bool
    let signer: SigV4
    /// Always https in the app; tests point it at a local mock server.
    var scheme = "https"

    static let partSize = 16 * 1024 * 1024
    static let multipartThreshold = 32 * 1024 * 1024
    static let parallelParts = 4

    var host: String { pathStyle ? endpoint : "\(bucket).\(endpoint)" }

    func path(for key: String) -> String {
        (pathStyle ? "/\(SigV4.encode(bucket))/" : "/") + SigV4.encode(key, keepSlash: true)
    }

    func objectURL(_ key: String) -> URL { URL(string: "\(scheme)://\(host)\(path(for: key))")! }

    func presignedURL(_ key: String, expires: Int) -> URL? {
        signer.presignedURL(host: host, path: path(for: key), expires: expires)
    }

    // MARK: Requests

    private func request(_ method: String, key: String, query: [(String, String)] = [],
                         headers: [String: String] = [:], payloadHash: String) -> URLRequest {
        let p = path(for: key)
        var url = "\(scheme)://\(host)\(p)"
        if !query.isEmpty {
            url += "?" + query.map { $0.1.isEmpty ? SigV4.encode($0.0) : "\(SigV4.encode($0.0))=\(SigV4.encode($0.1))" }
                .joined(separator: "&")
        }
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        var toSign = headers
        toSign["host"] = host
        toSign["x-amz-content-sha256"] = payloadHash
        let signed = signer.sign(method: method, path: p, query: query, headers: toSign, payloadHash: payloadHash)
        for (k, v) in signed where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    private func check(_ data: Data, _ response: HTTPURLResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = Self.xmlValue("Code", in: body) ?? "HTTP \(response.statusCode)"
            let message = Self.xmlValue("Message", in: body) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            let error = UploadError(Self.friendly(code: code, message: message))
            if HTTP.isRetryable(status: response.statusCode) { throw HTTP.RetryableError(underlying: error) }
            throw error
        }
    }

    static func friendly(code: String, message: String) -> String {
        switch code {
        case "InvalidAccessKeyId": return "The access key is not recognised. Check it in Settings → Uploads."
        case "SignatureDoesNotMatch": return "The secret key doesn't match the access key. Check both in Settings → Uploads."
        case "NoSuchBucket": return "The bucket wasn't found. Check the bucket name and endpoint."
        case "AccessDenied": return "Access denied. The key may not have write permission for this bucket."
        default: return "\(code): \(message)"
        }
    }

    static func xmlValue(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"), let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    func putData(_ data: Data, key: String, contentType: String, acl: String?, extraHeaders: [String: String] = [:]) async throws {
        try await HTTP.withRetry {
            var headers = extraHeaders
            headers["content-type"] = contentType
            if let acl { headers["x-amz-acl"] = acl }
            let req = request("PUT", key: key, headers: headers, payloadHash: SigV4.sha256Hex(data))
            let (body, resp) = try await HTTP.send(req, body: .data(data))
            try check(body, resp)
        }
    }

    func delete(key: String) async throws {
        let req = request("DELETE", key: key, payloadHash: SigV4.emptyPayloadHash)
        let (body, resp) = try await HTTP.send(req)
        try check(body, resp)
    }

    /// Uploads a file, in parallel parts when it is large. `progress` gets 0…1.
    func putFile(_ file: URL, key: String, contentType: String, acl: String?, contentDisposition: String?,
                 progress: @escaping @Sendable (Double) -> Void) async throws {
        let size = Int(file.fileSize)
        var headers: [String: String] = ["content-type": contentType, "cache-control": "public, max-age=31536000"]
        if let acl { headers["x-amz-acl"] = acl }
        if let contentDisposition { headers["content-disposition"] = contentDisposition }

        if size < Self.multipartThreshold {
            try await HTTP.withRetry {
                let req = request("PUT", key: key, headers: headers, payloadHash: SigV4.unsignedPayload)
                let (body, resp) = try await HTTP.send(req, body: .file(file)) { sent in
                    progress(size > 0 ? Double(sent) / Double(size) : 1)
                }
                try check(body, resp)
            }
            progress(1)
            return
        }

        // Multipart: create → upload parts → complete (abort on failure).
        let uploadID: String = try await HTTP.withRetry {
            let req = request("POST", key: key, query: [("uploads", "")], headers: headers, payloadHash: SigV4.emptyPayloadHash)
            let (body, resp) = try await HTTP.send(req)
            try check(body, resp)
            guard let id = Self.xmlValue("UploadId", in: String(data: body, encoding: .utf8) ?? "") else {
                throw UploadError("The storage service didn't start the upload.")
            }
            return id
        }

        do {
            let partSize = max(Self.partSize, (size + 9_999) / 10_000)
            let partCount = (size + partSize - 1) / partSize
            let tracker = ProgressTracker(total: Int64(size), report: progress)
            var etags = [Int: String]()

            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var next = 1
                func addPart(_ number: Int) {
                    group.addTask {
                        let offset = (number - 1) * partSize
                        let length = min(partSize, size - offset)
                        let data = try Self.read(file, offset: offset, length: length)
                        let etag: String = try await HTTP.withRetry {
                            tracker.set(part: number, sent: 0)
                            let req = request("PUT", key: key,
                                              query: [("partNumber", String(number)), ("uploadId", uploadID)],
                                              payloadHash: SigV4.sha256Hex(data))
                            let (body, resp) = try await HTTP.send(req, body: .data(data)) { sent in
                                tracker.set(part: number, sent: sent)
                            }
                            try check(body, resp)
                            guard let etag = resp.value(forHTTPHeaderField: "ETag") else {
                                throw UploadError("The storage service didn't confirm part \(number).")
                            }
                            return etag
                        }
                        tracker.set(part: number, sent: Int64(length))
                        return (number, etag)
                    }
                }
                while next <= min(Self.parallelParts, partCount) { addPart(next); next += 1 }
                for try await (number, etag) in group {
                    etags[number] = etag
                    if next <= partCount { addPart(next); next += 1 }
                }
            }

            let parts = (1...partCount).map { "<Part><PartNumber>\($0)</PartNumber><ETag>\(HTML.escape(etags[$0] ?? ""))</ETag></Part>" }.joined()
            let xml = Data("<CompleteMultipartUpload>\(parts)</CompleteMultipartUpload>".utf8)
            try await HTTP.withRetry {
                let req = request("POST", key: key, query: [("uploadId", uploadID)],
                                  headers: ["content-type": "application/xml"], payloadHash: SigV4.sha256Hex(xml))
                let (body, resp) = try await HTTP.send(req, body: .data(xml))
                try check(body, resp)
                // S3 can answer 200 with an error inside the body.
                if let text = String(data: body, encoding: .utf8), text.contains("<Error>") {
                    throw UploadError(Self.friendly(code: Self.xmlValue("Code", in: text) ?? "Error",
                                                    message: Self.xmlValue("Message", in: text) ?? text))
                }
            }
            progress(1)
        } catch {
            let req = request("DELETE", key: key, query: [("uploadId", uploadID)], payloadHash: SigV4.emptyPayloadHash)
            _ = try? await HTTP.send(req)
            throw error
        }
    }

    static func read(_ file: URL, offset: Int, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw UploadError("Could not read the video file.")
        }
        return data
    }
}

/// Thread-safe sum of bytes sent across parallel parts.
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Int: Int64] = [:]
    private let total: Int64
    private let report: @Sendable (Double) -> Void

    init(total: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.report = report
    }

    func set(part: Int, sent bytes: Int64) {
        let value: Double = lock.withLock {
            sent[part] = bytes
            return total > 0 ? Double(sent.values.reduce(0, +)) / Double(total) : 0
        }
        report(min(value, 1))
    }
}

/// Uploads to DigitalOcean Spaces (or any S3-compatible storage) with a share page next to the video.
struct SpacesUploader: Uploader {
    let client: S3Client
    let prefix: String
    let publicBaseURL: String
    let access: LinkAccess
    let createSharePage: Bool

    static let expirySeconds = 7 * 24 * 3600

    @MainActor
    static func fromSettings() throws -> SpacesUploader {
        let s = AppSettings.shared
        var endpoint = s.spacesEndpoint.trimmed.lowercased()
        if endpoint.hasPrefix("http://") { throw UploadError("The Spaces endpoint must use https.") }
        if endpoint.hasPrefix("https://") { endpoint.removeFirst("https://".count) }
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        let bucket = s.spacesBucket.trimmed
        guard !endpoint.isEmpty, !endpoint.contains("/"), !bucket.isEmpty else {
            throw UploadError("Enter the Spaces endpoint (like nyc3.digitaloceanspaces.com) and bucket name.")
        }
        // A "bucket.endpoint" entry is a common mistake: strip the bucket part.
        if endpoint.hasPrefix(bucket.lowercased() + ".") { endpoint.removeFirst(bucket.count + 1) }
        guard let secret = Keychain.get(.spacesSecret), !s.spacesAccessKey.trimmed.isEmpty else {
            throw UploadError("Add your Spaces access key and secret in Settings → Uploads.")
        }
        var region = s.spacesRegion.trimmed
        if region.isEmpty { region = endpoint.components(separatedBy: ".").first ?? "us-east-1" }
        let signer = SigV4(accessKey: s.spacesAccessKey.trimmed, secretKey: secret, region: region)
        if !s.spacesPublicBaseURL.trimmed.isEmpty {
            _ = try HTTP.validatedURL(s.spacesPublicBaseURL, what: "The public / CDN URL")
        }
        var prefix = s.spacesPrefix.trimmed
        while prefix.hasPrefix("/") { prefix.removeFirst() }
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return SpacesUploader(client: S3Client(endpoint: endpoint, bucket: bucket, pathStyle: s.spacesPathStyle, signer: signer),
                              prefix: prefix, publicBaseURL: s.spacesPublicBaseURL.trimmed,
                              access: s.spacesLinkAccess, createSharePage: s.createSharePage)
    }

    private func publicURL(_ key: String) -> URL {
        if publicBaseURL.isEmpty { return client.objectURL(key) }
        return URL(string: joinURL(publicBaseURL, SigV4.encode(key, keepSlash: true)))!
    }

    func upload(_ item: UploadItem, progress: @escaping @Sendable (Double) -> Void) async throws -> UploadResult {
        let slug = FileNames.slug(item.title)
        let month = item.recordedAt.formatted(.iso8601.year().month())
        let folder = [prefix, month, "\(slug)-\(RandomID.make(length: 14))"].filter { !$0.isEmpty }.joined(separator: "/")
        let videoKey = "\(folder)/\(slug).mp4"
        let posterKey = "\(folder)/poster.jpg"
        let pageKey = "\(folder)/index.html"
        let isPublic = access == .publicLink
        let acl = isPublic ? "public-read" : "private"
        let downloadName = FileNames.sanitize(item.title) + ".mp4"
        let disposition = "inline; filename=\"\(slug).mp4\"; filename*=UTF-8''\(SigV4.encode(downloadName))"

        try await client.putFile(item.file, key: videoKey, contentType: "video/mp4", acl: acl,
                                 contentDisposition: disposition) { progress($0 * 0.97) }

        var posterURL: URL?
        if let poster = item.poster, let data = try? Data(contentsOf: poster) {
            try await client.putData(data, key: posterKey, contentType: "image/jpeg", acl: acl)
            posterURL = isPublic ? publicURL(posterKey) : client.presignedURL(posterKey, expires: Self.expirySeconds)
        }
        guard let videoURL = isPublic ? publicURL(videoKey) : client.presignedURL(videoKey, expires: Self.expirySeconds) else {
            throw UploadError("Could not make the video link.")
        }
        var link = videoURL
        if createSharePage {
            let page = SharePage.html(title: item.title, videoURL: videoURL.absoluteString, posterURL: posterURL?.absoluteString,
                                      downloadName: downloadName, duration: item.duration, recordedAt: item.recordedAt,
                                      width: item.width, height: item.height)
            try await client.putData(Data(page.utf8), key: pageKey, contentType: "text/html; charset=utf-8", acl: acl,
                                     extraHeaders: ["cache-control": "public, max-age=300"])
            if let pageURL = isPublic ? publicURL(pageKey) : client.presignedURL(pageKey, expires: Self.expirySeconds) {
                link = pageURL
            }
        }
        progress(1)
        return UploadResult(destination: UploadDestination.spaces.rawValue, link: link, videoURL: videoURL,
                            remoteID: videoKey, uploadedAt: Date(),
                            expiresAt: isPublic ? nil : Date().addingTimeInterval(TimeInterval(Self.expirySeconds)))
    }

    func testConnection() async throws -> String {
        let key = [prefix, ".scrcapkit-check-\(RandomID.make(length: 8)).txt"].filter { !$0.isEmpty }.joined(separator: "/")
        try await client.putData(Data("ok".utf8), key: key, contentType: "text/plain", acl: "private")
        try? await client.delete(key: key)
        return "Connected to \(client.bucket). Uploads will work."
    }
}
