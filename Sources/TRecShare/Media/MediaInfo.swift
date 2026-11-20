import AppKit
import AVFoundation
import Foundation

/// Facts about a video file, loaded asynchronously.
struct MediaInfo: Equatable {
    var duration: TimeInterval
    var width: Int
    var height: Int
    var audioTracks: Int

    var resolutionText: String { "\(width)×\(height)" }

    static func load(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            let video = try await asset.loadTracks(withMediaType: .video).first
            let audio = try await asset.loadTracks(withMediaType: .audio)
            var size = CGSize.zero
            if let video {
                let natural = try await video.load(.naturalSize)
                let t = try await video.load(.preferredTransform)
                let r = CGRect(origin: .zero, size: natural).applying(t)
                size = CGSize(width: abs(r.width), height: abs(r.height))
            }
            return MediaInfo(duration: duration, width: Int(size.width), height: Int(size.height), audioTracks: audio.count)
        } catch {
            return nil
        }
    }
}

enum MediaTools {
    /// A still frame from the video (used for library thumbnails and the share-page poster).
    static func thumbnail(for url: URL, maxSize: CGSize = CGSize(width: 640, height: 640),
                          at seconds: Double = 1) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let t = CMTime(seconds: min(seconds, max(duration / 2, 0)), preferredTimescale: 600)
        return try? await generator.image(at: t).image
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Cuts the recording to `range` without re-encoding (like QuickTime's Trim).
    static func trim(_ source: URL, range: CMTimeRange, to dest: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.featureUnsupported)
        }
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: dest, as: .mp4)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
    }
}

/// Small in-memory cache of library thumbnails.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL) async -> NSImage? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(mtime)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let cg = await MediaTools.thumbnail(for: url, maxSize: CGSize(width: 480, height: 480)) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}
