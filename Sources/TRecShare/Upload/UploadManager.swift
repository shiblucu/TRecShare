import AppKit
import Foundation

/// Runs uploads, remembers each recording's share link, and reports progress to the UI.
@MainActor
final class UploadManager: ObservableObject {
    static let shared = UploadManager()

    enum JobState: Equatable {
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
        case .preparing, .uploading: return true
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
        let settings = AppSettings.shared
        let dest = destination ?? jobDestinations[key] ?? settings.uploadDestination
        jobDestinations[key] = dest
        let quality = quality ?? settings.uploadQuality

        let uploader: Uploader
        do {
            if let missing = settings.missingSetup(for: dest) { throw UploadError(missing) }
            switch dest {
            case .none: throw UploadError(settings.missingSetup(for: .none)!)
            case .spaces: uploader = try SpacesUploader.fromSettings()
            case .drive: uploader = try DriveUploader.fromSettings()
            case .server: uploader = try ServerUploader.fromSettings()
            }
        } catch {
            jobs[key] = .failed(error.localizedDescription)
            return
        }

        jobs[key] = .preparing(0)
        Log.upload.info("upload started → \(dest.rawValue), quality \(quality.rawValue)")
        tasks[key] = Task { [weak self] in
            await self?.run(url: url, uploader: uploader, destination: dest, quality: quality)
        }
    }

    func cancel(_ url: URL) {
        tasks[url.path]?.cancel()
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
            Pasteboard.copy(result.link.absoluteString)
            Notifier.shared.uploadFinished(link: result.link, title: item.title)
            if AppSettings.shared.openLinkAfterUpload { NSWorkspace.shared.open(result.link) }
            Log.upload.info("upload finished")
        } catch is CancellationError {
            jobs[key] = nil
            jobDestinations[key] = nil
        } catch Transcoder.TranscodeError.cancelled {
            jobs[key] = nil
            jobDestinations[key] = nil
        } catch let error as URLError where error.code == .cancelled {
            jobs[key] = nil
            jobDestinations[key] = nil
        } catch {
            Log.upload.error("upload failed: \(error.localizedDescription)")
            jobs[key] = .failed(error.localizedDescription)
            Notifier.shared.uploadFailed(title: url.deletingPathExtension().lastPathComponent, message: error.localizedDescription)
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
        records = (try? decoder.decode([String: UploadResult].self, from: data)) ?? [:]
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
