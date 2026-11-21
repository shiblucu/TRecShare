import AppKit
import Foundation

/// Runs uploads, remembers each recording's share link, and reports progress to the UI.
@MainActor
final class UploadManager: ObservableObject {
    static let shared = UploadManager()

    enum JobState: Equatable {
        case queued                // waiting for its turn (several recordings were sent at once)
        case preparing(Double)     // making the upload copy
        case uploading(Double)     // < 0 means "progress unknown"
        case failed(String)
    }

    @Published private(set) var jobs: [String: JobState] = [:]      // keyed by file path
    @Published private(set) var records: [String: UploadResult] = [:] // keyed by file path

    private var tasks: [String: Task<Void, Never>] = [:]
    /// Destination of a running or failed upload, so Retry (from the Library, Review or panel) goes to the same place.
    private var jobDestinations: [String: UploadDestination] = [:]
    private let storeURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TRecShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("uploads.json")
        load()
    }

    var hasActiveUploads: Bool { jobs.values.contains { if case .failed = $0 { return false }; return true } }

    /// Overall progress of running uploads (for the menu-bar icon), or nil if none.
    var activeProgress: Double? {
        let values = jobs.values.compactMap { state -> Double? in
            switch state {
            case .queued: return 0
            case .preparing(let p): return p * 0.3
            case .uploading(let p): return p < 0 ? 0.5 : 0.3 + p * 0.7
            case .failed: return nil
            }
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    func state(for url: URL) -> JobState? { jobs[url.path] }

    func isUploading(_ url: URL) -> Bool {
        switch jobs[url.path] {
        case .queued, .preparing, .uploading: return true
        default: return false
        }
    }

    func record(for url: URL) -> UploadResult? {
        guard let r = records[url.path] else { return nil }
        if let exp = r.expiresAt, exp < Date() { return nil }
        return r
    }

    // MARK: - Upload

    func upload(_ url: URL, to destination: UploadDestination? = nil, quality: UploadQuality? = nil) {
        let key = url.path
        guard tasks[key] == nil else { return }
        if case .queued = jobs[key] { return }
        let settings = AppSettings.shared
        begin(url, to: destination ?? jobDestinations[key] ?? settings.uploadDestination, quality: quality ?? settings.uploadQuality)
    }

    // MARK: - Several recordings at once

    private struct QueuedUpload {
        let url: URL
        let destination: UploadDestination
        let quality: UploadQuality
    }

    private var queue: [QueuedUpload] = []
    /// Uploads started from a multi-selection: no clipboard / browser / per-file notification, one summary at the end.
    private var batchKeys: Set<String> = []
    private var batchTotal = 0, batchDone = 0, batchFailed = 0
    /// At most this many uploads prepare and send at once (re-encoding is heavy).
    private let maxParallelUploads = 2

    /// Uploads several recordings to one destination at one size, a couple at a time.
    /// Recordings that are already uploading or queued are skipped.
    func uploadMany(_ urls: [URL], to destination: UploadDestination, quality: UploadQuality) {
        if tasks.isEmpty, queue.isEmpty { batchTotal = 0; batchDone = 0; batchFailed = 0 }
        for url in urls {
            let key = url.path
            if tasks[key] != nil { continue }
            if case .queued = jobs[key] { continue }
            jobDestinations[key] = destination
            jobs[key] = .queued
            batchKeys.insert(key)
            batchTotal += 1
            queue.append(QueuedUpload(url: url, destination: destination, quality: quality))
        }
        startQueued()
    }

    private func startQueued() {
        while tasks.count < maxParallelUploads, !queue.isEmpty {
            let next = queue.removeFirst()
            guard case .queued = jobs[next.url.path] else { continue }   // cancelled while waiting
            begin(next.url, to: next.destination, quality: next.quality)
        }
    }

    /// Counts one finished batch upload (`success` nil = cancelled) and sends the summary after the last one.
    private func finishBatchItem(_ key: String, success: Bool?) {
        guard batchKeys.remove(key) != nil else { return }
        switch success {
        case true?: batchDone += 1
        case false?: batchFailed += 1
        case nil: batchTotal -= 1
        }
        if batchKeys.isEmpty, batchDone + batchFailed > 0 {
            Notifier.shared.uploadsFinished(done: batchDone, failed: batchFailed)
            batchTotal = 0; batchDone = 0; batchFailed = 0
        }
    }

    private func begin(_ url: URL, to dest: UploadDestination, quality: UploadQuality) {
        let key = url.path
        jobDestinations[key] = dest

        let uploader: Uploader
        do {
            uploader = try makeUploader(for: dest)
        } catch {
            jobs[key] = .failed(error.localizedDescription)
            finishBatchItem(key, success: false)
            startQueued()
            return
        }

        jobs[key] = .preparing(0)
        Log.upload.info("upload started → \(dest.rawValue), quality \(quality.rawValue)")
        tasks[key] = Task { [weak self] in
            await self?.run(url: url, uploader: uploader, destination: dest, quality: quality)
        }
    }

    private func makeUploader(for destination: UploadDestination) throws -> Uploader {
        let settings = AppSettings.shared
        if let missing = settings.missingSetup(for: destination) { throw UploadError(missing) }
        switch destination {
        case .none: throw UploadError(settings.missingSetup(for: .none)!)
        case .spaces: return try SpacesUploader.fromSettings()
        case .drive: return try DriveUploader.fromSettings()
        case .server: return try ServerUploader.fromSettings()
        }
    }

    // MARK: - Delete the online copy

    /// Recordings whose online copy is being removed right now (keyed by file path).
    @Published private(set) var deleting: Set<String> = []

    func isDeletingOnline(_ url: URL) -> Bool { deleting.contains(url.path) }

    /// True while an uploaded copy exists, even if its private link has expired (the file is still in storage).
    func hasOnlineCopy(_ url: URL) -> Bool { records[url.path] != nil }

    /// Where the saved upload of this recording lives.
    func onlineDestination(for url: URL) -> UploadDestination? {
        records[url.path].flatMap { UploadDestination(rawValue: $0.destination) }
    }

    /// Deletes the uploaded copy (and its share page) from the cloud storage. The recording on this Mac is untouched.
    func deleteOnlineCopy(of url: URL) async throws {
        let key = url.path
        guard let record = records[key] else { return }
        guard !isUploading(url) else { throw UploadError("Wait for the upload to finish first, or cancel it.") }
        guard !deleting.contains(key) else { return }
        guard let destination = UploadDestination(rawValue: record.destination) else {
            throw UploadError("This upload's destination isn't known, so it can't be deleted from here.")
        }
        deleting.insert(key)
        defer { deleting.remove(key) }
        let uploader = try makeUploader(for: destination)
        try await uploader.deleteUpload(record)
        records[key] = nil
        save()
        Log.upload.info("deleted the online copy")
    }

    func cancel(_ url: URL) {
        let key = url.path
        if case .queued = jobs[key] {      // still waiting: just take it out of the line
            queue.removeAll { $0.url.path == key }
            jobs[key] = nil
            jobDestinations[key] = nil
            finishBatchItem(key, success: nil)
            return
        }
        tasks[key]?.cancel()
    }

    func dismissError(_ url: URL) {
        if case .failed = jobs[url.path] {
            jobs[url.path] = nil
            jobDestinations[url.path] = nil
        }
    }

    /// Where a running or failed upload of this file is going.
    func destination(for url: URL) -> UploadDestination? { jobDestinations[url.path] }

    private func run(url: URL, uploader: Uploader, destination: UploadDestination, quality: UploadQuality) async {
        let key = url.path
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("trecshare-\(RandomID.make(length: 8))")
        defer {
            try? FileManager.default.removeItem(at: work)
            tasks[key] = nil
            startQueued()   // the next waiting upload takes this one's place
        }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            guard let info = await MediaInfo.load(url) else { throw UploadError("This file can't be read as a video.") }

            // 1. Upload copy (smaller H.264, or the original with audio tracks mixed).
            var file = url
            let progressSink: @Sendable (Double) -> Void = { p in
                Task { @MainActor [weak self] in
                    if case .preparing = self?.jobs[key] { self?.jobs[key] = .preparing(p) }
                }
            }
            if let maxHeight = quality.maxHeight {
                file = work.appendingPathComponent("upload.mp4")
                try await Transcoder.transcode(source: url, dest: file, video: .encode(maxHeight: maxHeight, bitrate: quality.bitrate),
                                               levelAudio: AppSettings.shared.levelVoice, progress: progressSink)
            } else {
                // Original size: copy the video untouched, but move the index to the front ("fast start")
                // so browsers can begin playing at once, and mix audio tracks into one.
                file = work.appendingPathComponent("upload.mp4")
                try await Transcoder.transcode(source: url, dest: file, video: .passthrough,
                                               levelAudio: AppSettings.shared.levelVoice, progress: progressSink)
            }
            try Task.checkCancellation()

            // 2. Poster frame for the share page.
            var poster: URL?
            if let image = await MediaTools.thumbnail(for: url, maxSize: CGSize(width: 1280, height: 1280)) {
                let p = work.appendingPathComponent("poster.jpg")
                if (try? MediaTools.writeJPEG(image, to: p)) != nil { poster = p }
            }
            let uploadInfo = await MediaInfo.load(file) ?? info

            // 3. Upload.
            jobs[key] = .uploading(0)
            let item = UploadItem(file: file, title: url.deletingPathExtension().lastPathComponent, poster: poster,
                                  duration: uploadInfo.duration, width: uploadInfo.width, height: uploadInfo.height,
                                  recordedAt: url.creationDate == .distantPast ? Date() : url.creationDate)
            let result = try await uploader.upload(item) { p in
                Task { @MainActor [weak self] in
                    if case .uploading = self?.jobs[key] { self?.jobs[key] = .uploading(p) }
                }
            }

            // 4. Remember and share.
            records[key] = result
            save()
            jobs[key] = nil
            jobDestinations[key] = nil
            if batchKeys.contains(key) {
                finishBatchItem(key, success: true)
            } else {
                Pasteboard.copy(result.link.absoluteString)
                Notifier.shared.uploadFinished(link: result.link, title: item.title)
                if AppSettings.shared.openLinkAfterUpload { NSWorkspace.shared.open(result.link) }
            }
            Log.upload.info("upload finished")
        } catch is CancellationError {
            jobs[key] = nil
            jobDestinations[key] = nil
            finishBatchItem(key, success: nil)
        } catch Transcoder.TranscodeError.cancelled {
            jobs[key] = nil
            jobDestinations[key] = nil
            finishBatchItem(key, success: nil)
        } catch let error as URLError where error.code == .cancelled {
            jobs[key] = nil
            jobDestinations[key] = nil
            finishBatchItem(key, success: nil)
        } catch {
            Log.upload.error("upload failed: \(error.localizedDescription)")
            jobs[key] = .failed(error.localizedDescription)
            if batchKeys.contains(key) {
                finishBatchItem(key, success: false)
            } else {
                Notifier.shared.uploadFailed(title: url.deletingPathExtension().lastPathComponent, message: error.localizedDescription)
            }
        }
    }

    // MARK: - Bookkeeping

    func fileRenamed(from old: URL, to new: URL) {
        if let r = records.removeValue(forKey: old.path) { records[new.path] = r; save() }
        if let j = jobs.removeValue(forKey: old.path) { jobs[new.path] = j }
        if let d = jobDestinations.removeValue(forKey: old.path) { jobDestinations[new.path] = d }
    }

    func fileDeleted(_ url: URL) {
        cancel(url)
        if records.removeValue(forKey: url.path) != nil { save() }
        jobs[url.path] = nil
        jobDestinations[url.path] = nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let all = (try? decoder.decode([String: UploadResult].self, from: data)) ?? [:]
        // Forget links for recordings that were deleted outside the app. Files on a disconnected drive
        // (their folder is missing too) are kept, so their links come back when the drive does.
        let fm = FileManager.default
        records = all.filter { path, _ in
            fm.fileExists(atPath: path) || !fm.fileExists(atPath: (path as NSString).deletingLastPathComponent)
        }
        if records.count != all.count { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: storeURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }
}
