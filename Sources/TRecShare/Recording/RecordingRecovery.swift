import AVFoundation
import Foundation

/// Keeps recording parts in a hidden folder inside the recordings folder, and recovers them after a crash.
///
/// Layout: `<recordings>/.trecshare-parts/<session>/segment-001.mp4 …` plus `name.txt` (the intended file name).
/// A session folder only exists while a recording runs; a folder found at launch means the app was killed.
@MainActor
enum RecordingRecovery {
    static let partsFolderName = ".trecshare-parts"
    private static let nameFile = "name.txt"

    static func makeSessionFolder(for outputURL: URL) throws -> URL {
        let fm = FileManager.default
        let root = outputURL.deletingLastPathComponent().appendingPathComponent(partsFolderName, isDirectory: true)
        let dir = root.appendingPathComponent("session-\(FileNames.timestamp())-\(RandomID.make(length: 6))", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data(outputURL.deletingPathExtension().lastPathComponent.utf8).write(to: dir.appendingPathComponent(nameFile))
        return dir
    }

    static func removeSessionFolder(_ dir: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        // rmdir only removes an empty folder, so a session started meanwhile is never touched.
        rmdir(dir.deletingLastPathComponent().path)
    }

    /// Joins the readable parts of every interrupted session into "<name> (recovered).mp4".
    /// Returns the recovered files. Call at launch, before any recording starts.
    static func recoverInterruptedRecordings(in folders: [URL]) async -> [URL] {
        let fm = FileManager.default
        var recovered: [URL] = []
        for folder in Set(folders.map(\.standardizedFileURL)) {
            let root = folder.appendingPathComponent(partsFolderName, isDirectory: true)
            guard let sessions = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for session in sessions where session.lastPathComponent.hasPrefix("session-") {
                if let url = await recover(session, into: folder) { recovered.append(url) }
                removeSessionFolder(session)
            }
            rmdir(root.path)
        }
        return recovered
    }

    private static func recover(_ session: URL, into folder: URL) async -> URL? {
        let fm = FileManager.default
        let parts = ((try? fm.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mp4" && $0.fileSize > 0 }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // The part being written when the app died has no index and can't be read: skip unreadable parts.
        var usable: [URL] = []
        for part in parts {
            if let info = await MediaInfo.load(part), info.duration > 0.1 { usable.append(part) }
        }
        guard !usable.isEmpty else {
            Log.recorder.info("interrupted recording had no readable parts")
            return nil
        }
        let name = (try? String(contentsOf: session.appendingPathComponent(nameFile), encoding: .utf8))
            .map { FileNames.sanitize($0) } ?? "TRecShare \(FileNames.timestamp())"
        let dest = FileNames.unique(in: folder, base: "\(name) (recovered)", ext: "mp4")
        do {
            try await SegmentMerger.merge(usable, to: dest)
            Log.recorder.info("recovered an interrupted recording from \(usable.count) parts")
            return dest
        } catch {
            // Joining failed: keep the parts as separate files rather than lose them.
            var first: URL?
            for (i, part) in usable.enumerated() {
                let target = FileNames.unique(in: folder, base: "\(name) (recovered part \(i + 1))", ext: "mp4")
                if (try? fm.moveItem(at: part, to: target)) != nil, first == nil { first = target }
            }
            Log.recorder.error("recovery join failed: \(error.localizedDescription)")
            return first
        }
    }
}
