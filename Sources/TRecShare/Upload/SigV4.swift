import CryptoKit
import Foundation

/// AWS Signature Version 4, used by DigitalOcean Spaces and other S3-compatible storage.
struct SigV4 {
    let accessKey: String
    let secretKey: String
    let region: String
    var service: String = "s3"

    static let emptyPayloadHash = sha256Hex(Data())
    static let unsignedPayload = "UNSIGNED-PAYLOAD"

    /// Characters S3 leaves unencoded (RFC 3986 "unreserved").
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ s: String, keepSlash: Bool = false) -> String {
        var allowed = unreserved
        if keepSlash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func amzDate(_ date: Date) -> (full: String, day: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let full = f.string(from: date)
        return (full, String(full.prefix(8)))
    }

    /// Signs `headers` (must include "host") and returns them with `x-amz-date` and `Authorization` added.
    /// `path` must already be URI-encoded; `query` items are raw and get encoded here.
    func sign(method: String, path: String, query: [(String, String)] = [], headers: [String: String],
              payloadHash: String, date: Date = Date()) -> [String: String] {
        let (amzDate, day) = Self.amzDate(date)
        var all = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        all["x-amz-date"] = amzDate
        let signedNames = all.keys.sorted()
        let canonicalHeaders = signedNames.map { "\($0):\(all[$0]!.trimmed)\n" }.joined()
        let signedHeaders = signedNames.joined(separator: ";")

        let canonicalRequest = [method, path.isEmpty ? "/" : path, canonicalQuery(query), canonicalHeaders,
                                signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            Self.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = hex(hmac(signingKey(day: day), stringToSign))

        all["authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return all
    }

    /// A pre-signed GET URL that works without credentials until it expires (max 7 days).
    func presignedURL(scheme: String = "https", host: String, path: String, expires: Int,
                      date: Date = Date()) -> URL? {
        let (amzDate, day) = Self.amzDate(date)
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let query: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(accessKey)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(min(max(expires, 1), 604_800))),
            ("X-Amz-SignedHeaders", "host"),
        ]
        let canonicalRequest = ["GET", path, canonicalQuery(query), "host:\(host)\n", "host",
                                Self.unsignedPayload].joined(separator: "\n")
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            Self.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = hex(hmac(signingKey(day: day), stringToSign))
        return URL(string: "\(scheme)://\(host)\(path)?\(canonicalQuery(query))&X-Amz-Signature=\(signature)")
    }

    func canonicalQuery(_ items: [(String, String)]) -> String {
        let encoded: [(key: String, value: String)] = items.map { (key: Self.encode($0.0), value: Self.encode($0.1)) }
        let sorted = encoded.sorted { a, b in a.key == b.key ? a.value < b.value : a.key < b.key }
        return sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    }

    private func signingKey(day: String) -> SymmetricKey {
        let kDate = hmac(SymmetricKey(data: Data("AWS4\(secretKey)".utf8)), day)
        let kRegion = hmac(SymmetricKey(data: kDate), region)
        let kService = hmac(SymmetricKey(data: kRegion), service)
        return SymmetricKey(data: hmac(SymmetricKey(data: kService), "aws4_request"))
    }

    private func hmac(_ key: SymmetricKey, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
