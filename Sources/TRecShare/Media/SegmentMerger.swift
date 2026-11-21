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
        // Audio tracks are matched by format, not position: a muted part has fewer tracks (no microphone),
        // so "track 0" can be the mic in one part and system audio in the next. Matching by format keeps
        // every composition track uniform, which passthrough export needs. All tracks are mixed afterwards.
        var audioTracks: [(track: AVMutableCompositionTrack, format: AudioFormatKey)] = []
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
            var usedThisPart = Set<Int>()
            for source in try await asset.loadTracks(withMediaType: .audio) {
                let format = AudioFormatKey(try await source.load(.formatDescriptions).first)
                let index: Int
                if let match = audioTracks.indices.first(where: { audioTracks[$0].format == format && !usedThisPart.contains($0) }) {
                    index = match
                } else {
                    guard let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    audioTracks.append((t, format))
                    index = audioTracks.count - 1
                }
                usedThisPart.insert(index)
                let range = try await source.load(.timeRange)
                try audioTracks[index].track.insertTimeRange(range, of: source, at: cursor)
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

/// What has to match for two audio tracks to share one composition track.
struct AudioFormatKey: Equatable {
    let formatID: AudioFormatID
    let sampleRate: Double
    let channels: UInt32

    init(_ description: CMFormatDescription?) {
        let asbd = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        formatID = asbd?.mFormatID ?? 0
        sampleRate = asbd?.mSampleRate ?? 0
        channels = asbd?.mChannelsPerFrame ?? 0
    }
}
