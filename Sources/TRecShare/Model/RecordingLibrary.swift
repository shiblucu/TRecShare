import AppKit
import Foundation

extension Notification.Name {
    /// Asks the app to open the menu-bar recorder panel so the user can choose options before recording.
    static let showRecorderPanel = Notification.Name("TRecShare.showRecorderPanel")
    /// Posted with the file URL after a recording is moved to the Trash.
    static let recordingTrashed = Notification.Name("TRecShare.recordingTrashed")
}

struct RecordingItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let date: Date
    let size: Int64
    var title: String { url.deletingPathExtension().lastPathComponent }
}

/// The recordings folder as a list, kept up to date while it changes on disk.
@MainActor
final class RecordingLibrary: ObservableObject {
    static let shared = RecordingLibrary()

    @Published private(set) var items: [RecordingItem] = []
    @Published private(set) var folder: URL

    private var source: DispatchSourceFileSystemObject?
    private var debounce: Task<Void, Never>?

    private init() {
        folder = AppSettings.shared.recordingsFolder
    }

    func refresh() {
        let current = AppSettings.shared.recordingsFolder
        if current != folder || source == nil {
            folder = current
            watch()
        }
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        items = urls
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                guard v?.isRegularFile == true else { return nil }
                return RecordingItem(url: url, date: v?.creationDate ?? .distantPast, size: Int64(v?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
    }

    /// Renames the file to the sanitized title. Returns the new URL.
    func rename(_ url: URL, to title: String) throws -> URL {
        if UploadManager.shared.isUploading(url) {
            throw UploadError("Wait for the upload to finish before renaming.")
        }
        let name = FileNames.sanitize(title)
        guard name != url.deletingPathExtension().lastPathComponent else { return url }
        let dest = FileNames.unique(in: url.deletingLastPathComponent(), base: name, ext: url.pathExtension)
        try FileManager.default.moveItem(at: url, to: dest)
        UploadManager.shared.fileRenamed(from: url, to: dest)
        RecorderModel.shared.fileRenamed(from: url, to: dest)
        refresh()
        return dest
    }

    /// Moves the file to the Trash (recoverable).
    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        UploadManager.shared.fileDeleted(url)
        RecorderModel.shared.fileDeleted(url)
        refresh()
        NotificationCenter.default.post(name: .recordingTrashed, object: url)
    }

    private func watch() {
        source?.cancel()
        source = nil
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            MainActor.assumeIsolated {
                // Folder deleted or renamed: drop this watcher; refresh() attaches a new one.
                if let events = src?.data, !events.intersection([.delete, .rename]).isEmpty {
                    self?.source?.cancel()
                    self?.source = nil
                }
                self?.debounce?.cancel()
                self?.debounce = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
}
