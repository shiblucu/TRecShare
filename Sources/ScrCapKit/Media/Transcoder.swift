import AVFoundation
import Foundation

/// Re-encodes or remuxes a recording to MP4 with one AAC audio track.
/// - `.encode`: H.264 at a lower resolution and a set bitrate (for sharing).
/// - `.passthrough`: video copied untouched, only audio tracks mixed (fast).
enum Transcoder {
    enum VideoMode: Equatable {
        case passthrough
        case encode(maxHeight: Int, bitrate: Int)
    }

    enum TranscodeError: LocalizedError {
        case noVideo, setup(String), failed(String), cancelled
        var errorDescription: String? {
            switch self {
            case .noVideo: return "The recording has no video track."
            case .setup(let s), .failed(let s): return s
            case .cancelled: return "Cancelled."
            }
        }
    }

    /// Output size for `.encode`: fit to `maxHeight`, keep the aspect ratio, even numbers only, never upscale.
    static func outputSize(for natural: CGSize, maxHeight: Int) -> CGSize {
        var w = Double(abs(natural.width)), h = Double(abs(natural.height))
        if h > Double(maxHeight) {
            w = w * Double(maxHeight) / h
            h = Double(maxHeight)
        }
        return CGSize(width: Int(w.rounded()) & ~1, height: Int(h.rounded()) & ~1)
    }

    /// - Parameter levelAudio: even out the voice volume (see `AudioLeveler`). Use for upload copies only.
    static func transcode(source: URL, dest: URL, video mode: VideoMode, levelAudio: Bool = false,
                          progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw TranscodeError.noVideo }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        let transform = try await videoTrack.load(.preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: dest, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true   // "fast start": playback begins before the download finishes

        // Video
        let videoOut: AVAssetReaderTrackOutput
        let videoIn: AVAssetWriterInput
        switch mode {
        case .passthrough:
            videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            let hint = try await videoTrack.load(.formatDescriptions).first
            videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        case .encode(let maxHeight, let bitrate):
            let natural = try await videoTrack.load(.naturalSize)
            let fps = max(Double(try await videoTrack.load(.nominalFrameRate)), 30)
            let size = outputSize(for: natural, maxHeight: maxHeight)
            videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                    AVVideoExpectedSourceFrameRateKey: Int(fps),
                ] as [String: Any],
            ])
        }
        videoOut.alwaysCopiesSampleData = false
        videoIn.expectsMediaDataInRealTime = false
        videoIn.transform = transform
        guard reader.canAdd(videoOut), writer.canAdd(videoIn) else { throw TranscodeError.setup("Could not set up the video encoder.") }
        reader.add(videoOut)
        writer.add(videoIn)

        // Audio: all tracks mixed into one stereo AAC track.
        var audioPipe: Pipe?
        if !audioTracks.isEmpty {
            var gain = 1.0
            if levelAudio, let measured = await AudioLeveler.measure(asset: asset, tracks: audioTracks) {
                gain = measured
                Log.upload.info("voice levelling gain: \(String(format: "%.1f", 20 * log10(measured))) dB")
            }
            let mix = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: AudioLeveler.floatSettings)
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            audioIn.expectsMediaDataInRealTime = false
            if reader.canAdd(mix), writer.canAdd(audioIn) {
                reader.add(mix)
                writer.add(audioIn)
                audioPipe = Pipe(out: mix, input: audioIn, duration: 0, progress: nil)
                if levelAudio {
                    let g = gain
                    var done = 0
                    audioPipe?.transform = { AudioLeveler.apply(gain: g, to: $0, framesDone: &done) }
                }
            }
        }

        guard reader.startReading() else {
            throw TranscodeError.setup(reader.error?.localizedDescription ?? "Could not read the recording.")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw TranscodeError.setup(writer.error?.localizedDescription ?? "Could not write the new file.")
        }
        writer.startSession(atSourceTime: .zero)

        let videoPipe = Pipe(out: videoOut, input: videoIn, duration: duration, progress: progress)
        let pipes = [videoPipe] + (audioPipe.map { [$0] } ?? [])
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for (i, pipe) in pipes.enumerated() {
                    group.addTask { await pipe.run(queue: DispatchQueue(label: "scrcapkit.transcode.\(i)")) }
                }
            }
        } onCancel: {
            pipes.forEach { $0.cancel() }
        }

        if Task.isCancelled || pipes.contains(where: { $0.isCancelled }) {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: dest)
            throw TranscodeError.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: dest)
            throw TranscodeError.failed(reader.error?.localizedDescription ?? "Reading the recording failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: dest)
            throw TranscodeError.failed(writer.error?.localizedDescription ?? "Writing the new file failed.")
        }
        progress?(1)
    }

    /// Copies samples from one reader output to one writer input until the output runs out.
    private final class Pipe: @unchecked Sendable {
        let out: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let duration: Double
        let progress: (@Sendable (Double) -> Void)?
        /// Optional in-place edit of each sample before it is written (used for audio levelling).
        var transform: ((CMSampleBuffer) -> Void)?
        private let lock = NSLock()
        private var cancelledFlag = false
        private var lastReported = -1.0

        init(out: AVAssetReaderOutput, input: AVAssetWriterInput, duration: Double, progress: (@Sendable (Double) -> Void)?) {
            self.out = out
            self.input = input
            self.duration = duration
            self.progress = progress
        }

        var isCancelled: Bool { lock.withLock { cancelledFlag } }
        func cancel() { lock.withLock { cancelledFlag = true } }

        func run(queue: DispatchQueue) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                var finished = false
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        if isCancelled {
                            finished = true
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                        guard let sample = out.copyNextSampleBuffer() else {
                            finished = true
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                        transform?(sample)
                        if let progress, duration > 0 {
                            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            let p = min(max(t / duration, 0), 1)
                            if p - lastReported >= 0.01 {
                                lastReported = p
                                progress(p)
                            }
                        }
                        if !input.append(sample) {
                            finished = true
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                    }
                }
            }
        }
    }
}
