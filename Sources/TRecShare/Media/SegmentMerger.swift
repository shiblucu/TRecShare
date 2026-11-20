import AVFoundation
import Foundation

/// Joins the files of a paused/resumed recording into one MP4 without re-encoding,
/// and mixes several audio tracks (microphone + system audio) into one so every player hears both.
enum SegmentMerger {
    enum MergeError: LocalizedError {
        case exportFailed(String)
        var errorDescription: String? {
            switch self { case .exportFailed(let s): return "Could not join the recording parts: \(s)" }
        }
    }

    static func merge(_ segments: [URL], to dest: URL) async throws {
        precondition(!segments.isEmpty)
        let fm = FileManager.default
        let staging = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.deletingPathExtension().lastPathComponent)-\(RandomID.make(length: 6)).mp4")
        defer { try? fm.removeItem(at: staging) }

        if segments.count == 1 {
            try fm.moveItem(at: segments[0], to: staging)
        } else {
            try await concatenate(segments, to: staging)
        }

        if try await AVURLAsset(url: staging).loadTracks(withMediaType: .audio).count > 1 {
            let mixed = staging.deletingPathExtension().appendingPathExtension("mixed.mp4")
            defer { try? fm.removeItem(at: mixed) }
            try await Transcoder.transcode(source: staging, dest: mixed, video: .passthrough)
            try fm.removeItem(at: staging)
            try fm.moveItem(at: mixed, to: staging)
        }

        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: staging, to: dest)
        // Recordings can contain private screen content: owner-only access.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
    }

    private static func concatenate(_ segments: [URL], to dest: URL) async throws {
        let composition = AVMutableComposition()
        var videoTrack: AVMutableCompositionTrack?
        var audioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero

        for url in segments {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration > .zero else { continue }

            if let source = try await asset.loadTracks(withMediaType: .video).first {
                if videoTrack == nil {
                    videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    videoTrack?.preferredTransform = try await source.load(.preferredTransform)
                }
                let range = try await source.load(.timeRange)
                try videoTrack?.insertTimeRange(range, of: source, at: cursor)
            }
            for (i, source) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
                while audioTracks.count <= i {
                    guard let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { break }
                    audioTracks.append(t)
                }
                let range = try await source.load(.timeRange)
                try audioTracks[i].insertTimeRange(range, of: source, at: cursor)
            }
            cursor = cursor + duration
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw MergeError.exportFailed("export is not available")
        }
        session.shouldOptimizeForNetworkUse = true
        do {
            try await session.export(to: dest, as: .mp4)
        } catch {
            throw MergeError.exportFailed(error.localizedDescription)
        }
    }
}
