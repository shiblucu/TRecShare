import CryptoKit
import Foundation
import Testing
@testable import TRecShare

private func utc(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.date(from: s)!
}

@Suite("AWS Signature V4 (official test vectors)")
struct SigV4Tests {
    let suite = SigV4(accessKey: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                      region: "us-east-1", service: "service")
    let s3 = SigV4(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")

    @Test func getVanilla() {
        let h = suite.sign(method: "GET", path: "/", headers: ["host": "example.amazonaws.com"],
                           payloadHash: SigV4.emptyPayloadHash, date: utc("20150830T123600Z"))
        #expect(h["authorization"] == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func queryOrder() {
        let h = suite.sign(method: "GET", path: "/", query: [("Param2", "value2"), ("Param1", "value1")],
                           headers: ["host": "example.amazonaws.com"], payloadHash: SigV4.emptyPayloadHash, date: utc("20150830T123600Z"))
        #expect(h["authorization"]?.hasSuffix("Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500") == true)
    }

    @Test func s3PutObject() {
        let hash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        let h = s3.sign(method: "PUT", path: "/test%24file.text",
                        headers: ["host": "examplebucket.s3.amazonaws.com", "date": "Fri, 24 May 2013 00:00:00 GMT",
                                  "x-amz-storage-class": "REDUCED_REDUNDANCY", "x-amz-content-sha256": hash],
                        payloadHash: hash, date: utc("20130524T000000Z"))
        #expect(h["authorization"]?.hasSuffix("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd") == true)
    }

    @Test func s3Presign() {
        let url = s3.presignedURL(host: "examplebucket.s3.amazonaws.com", path: "/test.txt", expires: 86400, date: utc("20130524T000000Z"))
        #expect(url?.absoluteString.hasSuffix("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404") == true)
    }

    @Test func presignExpiryIsCappedAtSevenDays() {
        let url = s3.presignedURL(host: "h", path: "/k", expires: 10_000_000)
        #expect(url?.absoluteString.contains("X-Amz-Expires=604800") == true)
    }

    @Test func s3KeyEncoding() {
        let c = S3Client(endpoint: "nyc3.digitaloceanspaces.com", bucket: "b", pathStyle: false, signer: s3)
        #expect(c.path(for: "rec/2026-11/a b+c.mp4") == "/rec/2026-11/a%20b%2Bc.mp4")
        #expect(c.host == "b.nyc3.digitaloceanspaces.com")
        let p = S3Client(endpoint: "minio.local", bucket: "b", pathStyle: true, signer: s3)
        #expect(p.path(for: "x.mp4") == "/b/x.mp4")
        #expect(p.host == "minio.local")
    }
}

@Suite("File names and IDs")
struct NamingTests {
    @Test func sanitizeRemovesPathTricks() {
        #expect(FileNames.sanitize("../../etc/passwd") == "-..-etc-passwd")
        #expect(!FileNames.sanitize("a/b:c\\d").contains("/"))
        #expect(FileNames.sanitize("   ") == "Recording")
        #expect(FileNames.sanitize(".hidden") == "hidden")
        #expect(FileNames.sanitize(String(repeating: "x", count: 300)).count == 120)
    }

    @Test func slugIsURLSafe() {
        #expect(FileNames.slug("Héllo Wörld — Demo #1!") == "hello-world-demo-1")
        #expect(FileNames.slug("日本語") == "recording")
        #expect(FileNames.slug("<script>alert(1)</script>") == "script-alert-1-script")
    }

    @Test func randomIDsAreUniqueAndSafe() {
        let ids = (0..<500).map { _ in RandomID.make(length: 14) }
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.count == 14 && $0.allSatisfy { $0.isLetter || $0.isNumber } })
    }

    @Test func uniqueFileName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sck-test-\(RandomID.make())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FileNames.unique(in: dir, base: "Rec", ext: "mp4")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        #expect(FileNames.unique(in: dir, base: "Rec", ext: "mp4").lastPathComponent == "Rec 2.mp4")
    }
}

@Suite("Share page and URLs")
struct SharePageTests {
    @Test func escapesUserContent() {
        let html = SharePage.html(title: "<img src=x onerror=alert(1)> & \"quote\"", videoURL: "https://x/v.mp4?a=1&b=\"2\"",
                                  posterURL: nil, downloadName: "a\".mp4", duration: 65, recordedAt: Date(), width: 1920, height: 1080)
        #expect(!html.contains("<img src=x"))
        #expect(html.contains("&lt;img src=x onerror=alert(1)&gt; &amp; &quot;quote&quot;"))
        #expect(html.contains("v.mp4?a=1&amp;b=&quot;2&quot;"))
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("01:05"))
        #expect(html.contains("href=\"https://github.com/shiblucu/TRecShare\""))
    }

    @Test func copyLinkScriptIsAllowedByCSP() throws {
        let html = SharePage.html(title: "t", videoURL: "https://x/v.mp4", posterURL: nil, downloadName: "t.mp4",
                                  duration: 1, recordedAt: Date(), width: 1920, height: 1080)
        let start = try #require(html.range(of: "<script>"))
        let end = try #require(html.range(of: "</script>", range: start.upperBound..<html.endIndex))
        let script = String(html[start.upperBound..<end.lowerBound])
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        #expect(html.contains("script-src 'sha256-\(hash)'"))
        #expect(html.components(separatedBy: "<script").count == 2)   // exactly one script
    }

    @Test func joinsURLs() {
        #expect(joinURL("https://a.com/", "/b/c") == "https://a.com/b/c")
        #expect(joinURL("https://a.com", "b") == "https://a.com/b")
    }

    @Test func requiresHTTPS() {
        #expect(throws: UploadError.self) { try HTTP.validatedURL("http://example.com", what: "URL") }
        #expect(throws: UploadError.self) { try HTTP.validatedURL("not a url", what: "URL") }
        #expect((try? HTTP.validatedURL("https://example.com/x", what: "URL")) != nil)
        #expect((try? HTTP.validatedURL("http://localhost:8080", what: "URL")) != nil)
    }
}

@Suite("Video math")
struct MediaTests {
    @Test func outputSizeKeepsAspectAndIsEven() {
        #expect(Transcoder.outputSize(for: CGSize(width: 2992, height: 1934), maxHeight: 1080) == CGSize(width: 1670, height: 1080))
        #expect(Transcoder.outputSize(for: CGSize(width: 3840, height: 2160), maxHeight: 1080) == CGSize(width: 1920, height: 1080))
        #expect(Transcoder.outputSize(for: CGSize(width: 1280, height: 720), maxHeight: 1080) == CGSize(width: 1280, height: 720))
        #expect(Transcoder.outputSize(for: CGSize(width: 1001, height: 777), maxHeight: 2000) == CGSize(width: 1000, height: 776))
    }

    @Test func durationFormat() {
        #expect(Format.duration(0) == "00:00")
        #expect(Format.duration(61.9) == "01:01")
        #expect(Format.duration(3725) == "1:02:05")
        #expect(Format.duration(.nan) == "–")
    }
}

@Suite("Voice levelling")
struct AudioLevelerTests {
    private func power(_ db: Double) -> Double { pow(10, db / 10) }

    @Test func quietSpeechIsBoostedToTarget() {
        let blocks = (0..<40).map { _ in power(-34) }
        let g = AudioLeveler.gain(forBlockPowers: blocks)
        #expect(abs(20 * log10(g) - 13) < 0.1)          // -34 → -21 dB
    }

    @Test func aSinglePopDoesNotSkewTheLevel() {
        var blocks = (0..<40).map { _ in power(-34) }
        blocks[0] = power(-12)
        let g = AudioLeveler.gain(forBlockPowers: blocks)
        #expect(abs(20 * log10(g) - 13) < 0.1)
    }

    @Test func silenceAndAlreadyGoodAudioAreLeftAlone() {
        #expect(AudioLeveler.gain(forBlockPowers: (0..<20).map { _ in power(-80) }) == 1)
        #expect(AudioLeveler.gain(forBlockPowers: (0..<20).map { _ in power(-21.5) }) == 1)
        #expect(AudioLeveler.gain(forBlockPowers: []) == 1)
    }

    @Test func gainIsCapped() {
        let boost = AudioLeveler.gain(forBlockPowers: (0..<20).map { _ in power(-52) })
        #expect(20 * log10(boost) <= AudioLeveler.maxBoostDB + 0.001)
        let cut = AudioLeveler.gain(forBlockPowers: (0..<20).map { _ in power(-3) })
        #expect(20 * log10(cut) >= AudioLeveler.maxCutDB - 0.001)
    }

    @Test func limiterNeverExceedsCeilingAndKeepsQuietSoundUntouched() {
        for x in stride(from: Float(0), through: 40, by: 0.5) {
            #expect(AudioLeveler.limit(x) <= AudioLeveler.ceiling)
            #expect(AudioLeveler.limit(-x) >= -AudioLeveler.ceiling)
        }
        #expect(AudioLeveler.limit(0.3) == 0.3)
        #expect(AudioLeveler.limit(0.9) > AudioLeveler.limit(0.7))   // still monotonic
    }
}

@Suite("Storage settings validation")
struct S3ValidationTests {
    @Test func acceptsNormalSettings() throws {
        #expect(try S3Validation.bucket("my-videos") == "my-videos")
        #expect(try S3Validation.endpoint("nyc3.digitaloceanspaces.com", bucket: "b") == "nyc3.digitaloceanspaces.com")
        #expect(try S3Validation.endpoint("https://NYC3.digitaloceanspaces.com/", bucket: "b") == "nyc3.digitaloceanspaces.com")
        #expect(try S3Validation.endpoint("my-videos.nyc3.digitaloceanspaces.com", bucket: "my-videos") == "nyc3.digitaloceanspaces.com")
        #expect(try S3Validation.endpoint("minio.example.com:9000", bucket: "b") == "minio.example.com:9000")
        #expect(try S3Validation.region("", endpoint: "fra1.digitaloceanspaces.com") == "fra1")
        #expect(try S3Validation.prefix("/recordings/clients/") == "recordings/clients")
        #expect(try S3Validation.prefix("") == "")
    }

    @Test func rejectsHostTricksAndPathTraversal() {
        #expect(throws: UploadError.self) { try S3Validation.endpoint("http://nyc3.digitaloceanspaces.com", bucket: "b") }
        #expect(throws: UploadError.self) { try S3Validation.endpoint("evil.com@nyc3.digitaloceanspaces.com", bucket: "b") }
        #expect(throws: UploadError.self) { try S3Validation.endpoint("nyc3.digitaloceanspaces.com/path", bucket: "b") }
        #expect(throws: UploadError.self) { try S3Validation.endpoint("nyc3.digitaloceanspaces.com#x", bucket: "b") }
        #expect(throws: UploadError.self) { try S3Validation.endpoint("localhost", bucket: "b") }
        #expect(throws: UploadError.self) { try S3Validation.bucket("My_Bucket") }
        #expect(throws: UploadError.self) { try S3Validation.bucket("a..b") }
        #expect(throws: UploadError.self) { try S3Validation.region("nyc3/../x", endpoint: "e.com") }
        #expect(throws: UploadError.self) { try S3Validation.prefix("recordings/../secrets") }
        #expect(throws: UploadError.self) { try S3Validation.prefix("a/b?c") }
    }
}

@Suite("Crash recovery")
@MainActor
struct RecoveryTests {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trecshare-test-\(RandomID.make(length: 8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func sessionFolderIsHiddenAndRemovedCleanly() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try RecordingRecovery.makeSessionFolder(for: folder.appendingPathComponent("Rec A.mp4"))
        let b = try RecordingRecovery.makeSessionFolder(for: folder.appendingPathComponent("Rec B.mp4"))
        #expect(a.deletingLastPathComponent().lastPathComponent == RecordingRecovery.partsFolderName)
        RecordingRecovery.removeSessionFolder(a)
        // The other running session must survive.
        #expect(FileManager.default.fileExists(atPath: b.path))
        RecordingRecovery.removeSessionFolder(b)
        #expect(!FileManager.default.fileExists(atPath: b.deletingLastPathComponent().path))
    }

    @Test func unreadablePartsAreCleanedUpWithoutOutput() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = try RecordingRecovery.makeSessionFolder(for: folder.appendingPathComponent("Broken.mp4"))
        try Data("not a video".utf8).write(to: session.appendingPathComponent("segment-001.mp4"))
        let recovered = await RecordingRecovery.recoverInterruptedRecordings(in: [folder])
        #expect(recovered.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: session.path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: folder.path)).isEmpty)
    }

    @Test func audioFormatKeyHandlesMissingDescriptions() {
        #expect(AudioFormatKey(nil) == AudioFormatKey(nil))
    }
}

@Suite("Update check")
@MainActor
struct UpdateCheckTests {
    @Test func comparesVersionsNumerically() {
        #expect(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        #expect(UpdateChecker.isNewer("v1.10", than: "1.9.9"))
        #expect(UpdateChecker.isNewer("2", than: "1.9"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateChecker.isNewer("1.0.0", than: "1.0.1"))
        #expect(!UpdateChecker.isNewer("v1.2.0-beta", than: "1.2.0"))
    }

    @Test func readsReleaseFromRedirectAndOnlyTrustsGitHub() {
        let tagged = URL(string: "https://github.com/shiblucu/TRecShare/releases/tag/v1.2.0")
        #expect(UpdateChecker.release(from: tagged)?.version == "1.2.0")
        // No releases yet: GitHub lands on the list instead of a tag.
        #expect(UpdateChecker.release(from: URL(string: "https://github.com/shiblucu/TRecShare/releases")) == nil)
        #expect(UpdateChecker.release(from: URL(string: "https://evil.example/shiblucu/TRecShare/releases/tag/v9")) == nil)
        #expect(UpdateChecker.release(from: URL(string: "https://github.com/other/repo/releases/tag/v9")) == nil)
        #expect(UpdateChecker.release(from: URL(string: "https://github.com/shiblucu/TRecShare/releases/tag/latest-build")) == nil)
    }
}

@Suite("Deleting online copies")
struct DeleteOnlineTests {
    @Test func findsTheUploadFolderFromTheVideoKey() throws {
        #expect(try S3Validation.uploadFolder(forKey: "recordings/2026-11/demo-Ab3dE5/demo.mp4") == "recordings/2026-11/demo-Ab3dE5")
        #expect(try S3Validation.uploadFolder(forKey: "demo-Ab3dE5/demo.mp4") == "demo-Ab3dE5")
    }

    @Test func refusesKeysThatCouldReachOtherFiles() {
        for bad in [nil, "", "demo.mp4", "/demo.mp4", "../secret/demo.mp4", "a/../b/demo.mp4", "a//demo.mp4",
                    "a/./demo.mp4", "a/b?x=1/demo.mp4", "a/b\\c/demo.mp4"] as [String?] {
            #expect(throws: (any Error).self) { try S3Validation.uploadFolder(forKey: bad) }
        }
    }

    @Test func refusesToDeleteFromADifferentAccount() throws {
        try UploadError.checkAccount(saved: nil, current: "bucket@nyc3", what: "bucket")            // older upload: allowed
        try UploadError.checkAccount(saved: "bucket@nyc3", current: "bucket@nyc3", what: "bucket")  // same place
        #expect(throws: (any Error).self) {
            try UploadError.checkAccount(saved: "old-bucket@nyc3", current: "new-bucket@nyc3", what: "bucket")
        }
    }

    @Test func oldHistoryFilesStillLoad() throws {
        let json = #"{"destination":"spaces","link":"https://x.example/a","uploadedAt":"2026-11-21T10:00:00Z","remoteID":"a/b.mp4"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(UploadResult.self, from: Data(json.utf8))
        #expect(result.account == nil)
    }
}
