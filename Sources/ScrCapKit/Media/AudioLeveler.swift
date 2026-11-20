import AVFoundation
import Foundation

/// Evens out the voice volume of upload copies so clients don't have to turn the volume up.
/// The original recording is never changed.
///
/// 1. Measure: split the audio into 400 ms blocks, ignore silence and background noise, and take the
///    average level of the blocks where someone is actually speaking. One loud pop can't skew this.
/// 2. Gain: raise (or lower) that level to the target.
/// 3. Limit: a soft limiter keeps peaks below -2 dBFS so nothing clips.
enum AudioLeveler {
    /// Target level of speech (median block RMS, dBFS). Lands around -16 LUFS, the common level for web video.
    static let targetDB = -21.0
    static let maxBoostDB = 24.0
    static let maxCutDB = -6.0
    static let silenceFloorDB = -55.0
    /// Gains within ±1 dB are skipped (already fine).
    static let deadZoneDB = 1.0
    static let fadeInSeconds = 0.1

    /// Linear gain to apply for the given per-block mean-square powers (1.0 = unchanged).
    static func gain(forBlockPowers powers: [Double]) -> Double {
        let dbs = powers.map { 10 * log10(max($0, 1e-12)) }
        let audible = dbs.filter { $0 > silenceFloorDB }
        guard audible.count >= 2 else { return 1 }
        // Speech blocks: within 12 dB of the loud end (90th percentile), which excludes pauses and background noise.
        let sorted = audible.sorted()
        let p90 = sorted[min(Int(Double(sorted.count - 1) * 0.9), sorted.count - 1)]
        let speech = audible.filter { $0 >= p90 - 12 }.sorted()
        // Median (not average): a single loud click or pop can't pull the measured level up.
        let levelDB = speech[speech.count / 2]
        let gainDB = min(max(targetDB - levelDB, maxCutDB), maxBoostDB)
        return abs(gainDB) < deadZoneDB ? 1 : pow(10, gainDB / 20)
    }

    /// Highest level the limiter lets through (0.78 = -2.2 dBFS), leaving room for AAC encoding overshoot.
    static let ceiling: Float = 0.78

    /// Soft limiter: transparent below 0.6, rounds off smoothly toward the ceiling.
    @inline(__always)
    static func limit(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.6 { return x }
        let y = 0.6 + (ceiling - 0.6) * tanh((a - 0.6) / (ceiling - 0.6))
        return x < 0 ? -y : y
    }

    /// Reads all audio tracks as one stereo stream and returns the gain to apply. Nil on failure.
    static func measure(asset: AVAsset, tracks: [AVAssetTrack]) async -> Double? {
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: floatSettings)
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }

        let blockFrames = 48_000 * 4 / 10
        var powers: [Double] = []
        var sum = 0.0
        var frames = 0
        while let sample = out.copyNextSampleBuffer() {
            withFloats(sample) { p, count in
                var i = 0
                while i + 1 < count {                       // interleaved stereo
                    let m = Double(p[i] + p[i + 1]) * 0.5
                    sum += m * m
                    frames += 1
                    if frames == blockFrames {
                        powers.append(sum / Double(frames))
                        sum = 0
                        frames = 0
                    }
                    i += 2
                }
            }
        }
        if reader.status == .failed { return nil }
        if frames > blockFrames / 2 { powers.append(sum / Double(frames)) }
        return gain(forBlockPowers: powers)
    }

    /// Applies gain, limiter and a short fade-in to one buffer in place. `framesDone` counts frames already processed.
    static func apply(gain: Double, to sample: CMSampleBuffer, framesDone: inout Int) {
        let g = Float(gain)
        let fadeFrames = Int(fadeInSeconds * 48_000)
        var done = framesDone
        withFloats(sample) { p, count in
            var i = 0
            while i + 1 < count {
                var f: Float = 1
                if done < fadeFrames { f = Float(done) / Float(fadeFrames) }
                p[i] = limit(p[i] * g * f)
                p[i + 1] = limit(p[i + 1] * g * f)
                done += 1
                i += 2
            }
        }
        framesDone = done
    }

    static let floatSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
    ]

    private static func withFloats(_ sample: CMSampleBuffer, _ body: (UnsafeMutablePointer<Float>, Int) -> Void) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { return }
        pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { body($0, length / 4) }
    }
}
