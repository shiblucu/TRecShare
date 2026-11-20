import AVFoundation
import Foundation
import ScreenCaptureKit

/// Records with ScreenCaptureKit's recording output (macOS 15+), using the Mac's hardware encoder.
///
/// Pause is done by closing the current file ("segment") and starting a new one on resume;
/// `finish(to:)` joins the segments into one MP4. This keeps each file valid even if the app
/// is killed mid-recording.
@MainActor
final class ScreenRecorder: NSObject {
    enum RecorderError: LocalizedError {
        case alreadyRunning, notStarted, noFileWritten
        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "A recording is already running."
            case .notStarted: return "Nothing is being recorded."
            case .noFileWritten: return "Nothing was recorded, so no file was saved."
            }
        }
    }

    /// Called when capture stops on its own: the display was unplugged, the window closed,
    /// or the user clicked "Stop" in the macOS screen-sharing menu. `userStopped` is true for the last case.
    var onUnexpectedStop: ((_ error: Error?, _ userStopped: Bool) -> Void)?

    private(set) var isCapturing = false
    private var filter: SCContentFilter?
    private var streamConfig: SCStreamConfiguration?
    private var workDir: URL?
    private var segments: [URL] = []

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var segmentFinished = true
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var segmentError: Error?
    private var stoppingOnPurpose = false
    private let sampleQueue = DispatchQueue(label: "scrcapkit.screen-samples")

    var hasSession: Bool { workDir != nil }

    // MARK: - Public API

    /// Starts a new recording session. `outputURL` is only used to place the temporary files on the same disk.
    func start(filter: SCContentFilter, configuration: SCStreamConfiguration, near outputURL: URL) async throws {
        guard workDir == nil else { throw RecorderError.alreadyRunning }
        let folder = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: outputURL, create: true)
        self.filter = filter
        self.streamConfig = configuration
        self.workDir = dir
        self.segments = []
        do {
            try await startSegment()
        } catch {
            cleanUp()
            throw error
        }
    }

    func pause() async {
        guard isCapturing else { return }
        await stopSegment()
    }

    func resume() async throws {
        guard workDir != nil, !isCapturing else { return }
        try await startSegment()
    }

    /// Stops capture and writes the finished MP4 to `outputURL`.
    func finish(to outputURL: URL) async throws -> URL {
        guard workDir != nil else { throw RecorderError.notStarted }
        await stopSegment()
        await waitForSegmentFile()
        let usable = segments.filter { $0.fileSize > 0 }
        defer { cleanUp() }
        guard !usable.isEmpty else { throw segmentError ?? RecorderError.noFileWritten }
        try await SegmentMerger.merge(usable, to: outputURL)
        return outputURL
    }

    /// Stops and throws away everything recorded in this session.
    func cancel() async {
        await stopSegment()
        await waitForSegmentFile()
        cleanUp()
    }

    // MARK: - Segments

    private func startSegment() async throws {
        guard let filter, let streamConfig, let workDir else { throw RecorderError.notStarted }
        let url = workDir.appendingPathComponent(String(format: "segment-%03d.mp4", segments.count + 1))

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = .mp4
        // HEVC keeps text crisp at a smaller size; fall back to H.264 if unavailable.
        recordingConfig.videoCodecType = recordingConfig.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264

        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        let newStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        // A screen output keeps frames flowing; the samples themselves are not used.
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try newStream.addRecordingOutput(output)

        stream = newStream
        recordingOutput = output
        segmentFinished = false
        segmentError = nil
        stoppingOnPurpose = false
        do {
            try await newStream.startCapture()
        } catch {
            stream = nil
            recordingOutput = nil
            markSegmentFinished()
            throw error
        }
        segments.append(url)
        isCapturing = true
        Log.recorder.info("segment \(self.segments.count) started")
    }

    private func stopSegment() async {
        guard let activeStream = stream else { return }
        stoppingOnPurpose = true
        isCapturing = false
        do {
            try await activeStream.stopCapture()
        } catch {
            Log.recorder.error("stopCapture failed: \(error.localizedDescription)")
        }
        stream = nil
        await waitForSegmentFile()
        recordingOutput = nil
    }

    /// Waits (at most 10 s) until the recording output has closed the current file.
    private func waitForSegmentFile() async {
        guard !segmentFinished else { return }
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            Log.recorder.error("segment did not finish in time; continuing")
            self.markSegmentFinished()
        }
        await withCheckedContinuation { finishWaiters.append($0) }
        timeout.cancel()
    }

    private func markSegmentFinished() {
        segmentFinished = true
        let waiters = finishWaiters
        finishWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func cleanUp() {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        filter = nil
        streamConfig = nil
        segments = []
        stream = nil
        recordingOutput = nil
        isCapturing = false
    }

    // MARK: - Callbacks (hopped to the main actor)

    fileprivate func streamStopped(error: Error) {
        guard stream != nil, !stoppingOnPurpose else { return }
        let userStopped = (error as NSError).domain == SCStreamErrorDomain
            && (error as NSError).code == SCStreamError.Code.userStopped.rawValue
        Log.recorder.error("stream stopped: \(error.localizedDescription) userStopped=\(userStopped)")
        stream = nil
        isCapturing = false
        onUnexpectedStop?(userStopped ? nil : error, userStopped)
    }

    fileprivate func outputFinished(error: Error?) {
        if let error {
            Log.recorder.error("recording output failed: \(error.localizedDescription)")
            segmentError = error
            // If only the file writer failed, the capture may still run: stop it and report.
            if let activeStream = stream, !stoppingOnPurpose {
                stream = nil
                isCapturing = false
                Task { try? await activeStream.stopCapture() }
                markSegmentFinished()
                onUnexpectedStop?(error, false)
                return
            }
        }
        markSegmentFinished()
    }
}

extension ScreenRecorder: SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.streamStopped(error: error) }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {}

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.outputFinished(error: error) }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.outputFinished(error: nil) }
    }
}
