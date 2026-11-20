import AVFoundation
import AVKit
import SwiftUI

/// Shown after each recording (and from the Library): watch, trim, rename, upload, share.
struct ReviewView: View {
    let url: URL
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var library: RecordingLibrary
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var player = PlayerHolder()
    @State private var currentURL: URL?
    @State private var title = ""
    @State private var info: MediaInfo?
    @State private var busy: String?
    @State private var message: String?
    @State private var confirmDelete = false

    private var fileURL: URL { currentURL ?? url }

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(holder: player)
                .background(Color.black)
                .frame(minHeight: 280)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TextField("Title", text: $title)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .onSubmit(rename)
                        .help("Rename the recording (press Return)")
                    Spacer()
                    if let info {
                        Text("\(Format.duration(info.duration)) · \(info.resolutionText) · \(Format.bytes(fileURL.fileSize))")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }

                UploadStatusView(url: fileURL)

                HStack(spacing: 8) {
                    Button { player.beginTrim { range in trim(range) } } label: { Label("Trim", systemImage: "timeline.selection") }
                        .help("Cut the start or end. Saves a new trimmed file; the original is kept.")
                    Menu {
                        ForEach(UploadQuality.copyChoices) { q in
                            Button(q.title) { makeCopy(q) }
                        }
                    } label: { Label("Save Smaller Copy", systemImage: "arrow.down.right.and.arrow.up.left") }
                        .fixedSize()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) } label: { Label("Show in Finder", systemImage: "folder") }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Move to Trash", systemImage: "trash") }
                }
                .disabled(busy != nil)

                if let busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout).foregroundStyle(.secondary)
                    }
                } else if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(18)
        }
        .onAppear(perform: load)
        .onDisappear { player.player.pause() }
        .confirmationDialog("Move this recording to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive, action: delete)
        } message: {
            Text("You can restore it from the Trash. Uploaded copies stay online.")
        }
    }

    private func load() {
        if currentURL == nil { currentURL = url }
        title = fileURL.deletingPathExtension().lastPathComponent
        player.load(fileURL)
        Task { info = await MediaInfo.load(fileURL) }
    }

    private func rename() {
        let clean = FileNames.sanitize(title)
        guard clean != fileURL.deletingPathExtension().lastPathComponent else { return }
        do {
            let new = try library.rename(fileURL, to: clean)
            currentURL = new
            title = new.deletingPathExtension().lastPathComponent
            player.load(new)
            WindowRouter.shared.updateTitle("review", title)
            message = "Renamed."
        } catch {
            message = "Couldn't rename: \(error.localizedDescription)"
        }
    }

    private func trim(_ range: CMTimeRange) {
        let source = fileURL
        let dest = FileNames.unique(in: source.deletingLastPathComponent(),
                                    base: "\(source.deletingPathExtension().lastPathComponent) (trimmed)", ext: "mp4")
        busy = "Saving trimmed video…"
        Task {
            do {
                try await MediaTools.trim(source, range: range, to: dest)
                library.refresh()
                currentURL = dest
                load()
                WindowRouter.shared.updateTitle("review", title)
                message = "Saved the trimmed version as \"\(dest.lastPathComponent)\". The original is still in your library."
            } catch {
                try? FileManager.default.removeItem(at: dest)
                message = "Couldn't trim: \(error.localizedDescription)"
            }
            busy = nil
        }
    }

    private func makeCopy(_ quality: UploadQuality) {
        guard let maxHeight = quality.maxHeight else { return }
        let source = fileURL
        let dest = FileNames.unique(in: source.deletingLastPathComponent(),
                                    base: "\(source.deletingPathExtension().lastPathComponent) (\(quality.shortTitle))", ext: "mp4")
        busy = "Making a \(quality.shortTitle) copy…"
        Task {
            do {
                try await Transcoder.transcode(source: source, dest: dest, video: .encode(maxHeight: maxHeight, bitrate: quality.bitrate),
                                               levelAudio: AppSettings.shared.levelVoice)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                library.refresh()
                message = "Saved \(dest.lastPathComponent): \(Format.bytes(dest.fileSize)) (original \(Format.bytes(source.fileSize)))." + (settings.levelVoice ? " Voice volume evened out; the original keeps its own audio." : "")
            } catch {
                message = "Couldn't make the copy: \(error.localizedDescription)"
            }
            busy = nil
        }
    }

    private func delete() {
        player.player.pause()
        do {
            try library.trash(fileURL)
            WindowRouter.shared.close("review")
        } catch {
            message = "Couldn't move to Trash: \(error.localizedDescription)"
        }
    }
}

/// Owns the AVPlayer and the AVPlayerView so trimming can be started from SwiftUI buttons.
@MainActor
final class PlayerHolder: ObservableObject {
    let player = AVPlayer()
    weak var view: AVPlayerView?

    func load(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
    }

    func beginTrim(_ completion: @escaping (CMTimeRange) -> Void) {
        guard let view, view.canBeginTrimming else { return }
        view.beginTrimming { [weak self] result in
            guard result == .okButton, let item = self?.player.currentItem else { return }
            var start = item.reversePlaybackEndTime
            var end = item.forwardPlaybackEndTime
            if !start.isValid { start = .zero }
            if !end.isValid { end = item.duration }
            guard end > start else { return }
            completion(CMTimeRange(start: start, end: end))
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let holder: PlayerHolder

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = holder.player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.showsSharingServiceButton = false
        view.allowsPictureInPicturePlayback = true
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        holder.view = nsView
    }
}
