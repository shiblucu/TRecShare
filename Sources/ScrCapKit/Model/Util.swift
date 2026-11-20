import AppKit
import Foundation
import os
import Security

/// Shared loggers. View them in Console.app with subsystem "com.tawfiq.scrcapkit".
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.tawfiq.scrcapkit"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let recorder = Logger(subsystem: subsystem, category: "recorder")
    static let upload = Logger(subsystem: subsystem, category: "upload")
}

enum AppInfo {
    static var name: String { "ScrCapKit" }
    /// HTTP User-Agent product token (no spaces allowed).
    static var userAgentName: String { "ScrCapKit" }
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

enum FileNames {
    /// Turns a user-typed title into a safe file name (no slashes, colons, control characters or leading dots).
    static func sanitize(_ title: String, fallback: String = "Recording") -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var cleaned = title.unicodeScalars.map { banned.contains($0) ? "-" : String($0) }.joined()
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// ASCII-only, lowercase, dash-separated version of a title, for URLs.
    static func slug(_ title: String, maxLength: Int = 48) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
        var out = ""
        var lastDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
            if out.count >= maxLength { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "recording" : out.lowercased()
    }

    /// A URL in `folder` named `base.ext` that does not exist yet ("base 2.ext", "base 3.ext", …).
    static func unique(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: date)
    }
}

enum RandomID {
    private static let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// Cryptographically random, URL-safe ID (used to make share links unguessable).
    static func make(length: Int = 16) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No secure random source")
        // Rejection sampling avoids modulo bias.
        let limit = UInt8(256 - 256 % alphabet.count)
        var out = ""
        var i = 0
        while out.count < length {
            if i == bytes.count {
                _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                i = 0
            }
            let b = bytes[i]
            i += 1
            if b < limit { out.append(alphabet[Int(b) % alphabet.count]) }
        }
        return out
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}

extension URL {
    var fileSize: Int64 {
        Int64((try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    var creationDate: Date {
        (try? resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}

/// Spoken feedback for VoiceOver users (recording started, paused, errors…).
enum Accessibility {
    @MainActor
    static func announce(_ text: String) {
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

enum HTML {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }
}
