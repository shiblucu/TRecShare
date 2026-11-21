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
    @State private var uploadTo: UploadDestination = .none

    private var fileURL: URL { currentURL ?? url }

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(holder: player)
                .background(Color.black)
                .frame(minHeight: 280)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TextField("Title", text: $title)
                        .accessibilityLabel("Recording title")
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

                uploadCard

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
        // Moved to the Trash from the Library or elsewhere: don't leave a window open on a missing file.
        .onReceive(NotificationCenter.default.publisher(for: .recordingTrashed)) { note in
            if (note.object as? URL) == fileURL { WindowRouter.shared.close("review") }
        }
        .confirmationDialog("Move this recording to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive, action: delete)
        } message: {
            Text("You can restore it from the Trash. Uploaded copies stay online.")
        }
    }

    /// Destination and link options, then the upload button / progress / link (as in the design).
    private var uploadCard: some View {
        let notStarted = uploads.state(for: fileURL) == nil && uploads.record(for: fileURL) == nil
        let uploadsSetUp = settings.uploadDestination != .none
        return VStack(alignment: .leading, spacing: 10) {
            if notStarted && uploadsSetUp {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Upload to")
                        Picker("Upload to", selection: $uploadTo) {
                            ForEach(UploadDestination.allCases.filter { $0 != .none }) {
                                Label($0.shortTitle, systemImage: $0.icon).tag($0)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if uploadTo == .spaces {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel("Share link")
                            Picker("Share link", selection: $settings.spacesLinkAccess) {
                                ForEach(LinkAccess.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .help("Also changes the default in Settings → Uploads.")
                        }
                    } else if uploadTo == .drive {
                        VStack(alignment: .leading, spacing: 4) {
                            SectionLabel("Share link")
                            Picker("Share link", selection: $settings.driveAnyoneWithLink) {
                                Text("Anyone with the link").tag(true)
                                Text("Only people I share it with").tag(false)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .help("Also changes the default in Settings → Uploads.")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                if let missing = settings.missingSetup(for: uploadTo) {
                    Text(missing).font(.caption).foregroundStyle(.secondary)
                }
            }
            UploadStatusView(url: fileURL, destination: uploadsSetUp ? uploadTo : nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accentSoft))
    }

    private func load() {
        if uploadTo == .none { uploadTo = settings.uploadDestination }
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
