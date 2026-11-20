import Foundation
import Testing
@testable import ScrCapKit

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
