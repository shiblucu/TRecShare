import AppKit
import SwiftUI

/// All recordings in the recordings folder, newest first, with upload status and quick actions.
struct LibraryView: View {
    @EnvironmentObject private var library: RecordingLibrary
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var model: RecorderModel
    @State private var search = ""
    @State private var pendingDelete: RecordingItem?

    private var filtered: [RecordingItem] {
        let q = search.trimmed
        return q.isEmpty ? library.items : library.items.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if library.items.isEmpty {
                empty
            } else if filtered.isEmpty {
                Spacer()
                Text("No recordings match “\(search)”.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 18)], spacing: 18) {
                        ForEach(filtered) { item in
                            RecordingCard(item: item, onDelete: { pendingDelete = item })
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 380)
        .onAppear { library.refresh() }
        .confirmationDialog("Move “\(pendingDelete?.title ?? "")” to the Trash?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let item = pendingDelete { try? library.trash(item.url) }
                pendingDelete = nil
            }
        } message: {
            Text("You can restore it from the Trash. Uploaded copies stay online.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Library").font(.title2.weight(.semibold))
            Text("\(library.items.count) recording\(library.items.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            Spacer()
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Button { NSWorkspace.shared.open(library.folder) } label: { Image(systemName: "folder") }
                .help("Open the recordings folder in Finder")
            Button {
                model.startRecording()
            } label: {
                Label("New Recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "video.badge.plus").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No recordings yet").font(.title3.weight(.semibold))
            Text("Press \(HotKeys.toggleRecording.display) or click the menu-bar icon to record your screen.")
                .foregroundStyle(.secondary)
            Button("Start Recording") { model.startRecording() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RecordingCard: View {
    let item: RecordingItem
    let onDelete: () -> Void
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var settings: AppSettings
    @State private var thumbnail: NSImage?
    @State private var duration: TimeInterval?
    @State private var hovering = false

    var body: some View {
        Button { WindowRouter.shared.showReview(item.url) } label: { card }
            .buttonStyle(.plain)
            .contextMenu { menu }
            .help("Open \(item.title)")
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Opens the recording. More actions in the context menu.")
    }

    private var accessibilityText: String {
        var parts = [item.title, item.date.formatted(date: .abbreviated, time: .shortened), Format.bytes(item.size)]
        if let duration { parts.insert("\(Format.duration(duration)) long", at: 1) }
        if uploads.record(for: item.url) != nil { parts.append("shared") }
        return parts.joined(separator: ", ")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Rectangle().fill(Color.black.opacity(0.85))
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if let duration {
                    Text(Format.duration(duration))
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.7)))
                        .foregroundStyle(.white)
                        .padding(8)
                }
                if hovering {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Text(item.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(Format.bytes(item.size))
                Spacer()
                statusBadge
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(hovering ? 0.07 : 0.035)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering = $0 }
        .task(id: item.url) {
            thumbnail = await ThumbnailCache.shared.image(for: item.url)
            duration = await MediaInfo.load(item.url)?.duration
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let state = uploads.state(for: item.url) {
            switch state {
            case .preparing, .uploading:
                Label("Uploading", systemImage: "arrow.up.circle").foregroundStyle(.blue)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        } else if uploads.record(for: item.url) != nil {
            Label("Shared", systemImage: "link").foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open") { WindowRouter.shared.showReview(item.url) }
        Button("Play in QuickTime") { NSWorkspace.shared.open(item.url) }
        if let record = uploads.record(for: item.url) {
            Button("Copy Link") { Pasteboard.copy(record.link.absoluteString) }
            Button("Open Link") { NSWorkspace.shared.open(record.link) }
        }
        if settings.uploadDestination != .none {
            Button(uploads.record(for: item.url) == nil ? "Upload & Copy Link" : "Upload Again") { uploads.upload(item.url) }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Move to Trash", role: .destructive, action: onDelete)
    }
}
