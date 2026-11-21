import AppKit
import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All recordings", shared = "Shared", local = "On this Mac only", failed = "Upload failed"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all: return "rectangle.stack"
        case .shared: return "link"
        case .local: return "internaldrive"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// All recordings in the recordings folder, newest first, with upload status and quick actions.
struct LibraryView: View {
    @EnvironmentObject private var library: RecordingLibrary
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var settings: AppSettings
    @State private var search = ""
    @State private var filter: LibraryFilter = .all
    @State private var pendingDelete: RecordingItem?

    private func matches(_ item: RecordingItem, _ f: LibraryFilter) -> Bool {
        switch f {
        case .all: return true
        case .shared: return uploads.record(for: item.url) != nil
        case .failed: if case .failed = uploads.state(for: item.url) { return true } else { return false }
        case .local: return uploads.record(for: item.url) == nil && !matches(item, .failed)
        }
    }

    private var filtered: [RecordingItem] {
        let q = search.trimmed
        return library.items.filter { matches($0, filter) && (q.isEmpty || $0.title.localizedCaseInsensitiveContains(q)) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 420)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(LibraryFilter.allCases) { f in
                let count = library.items.filter { matches($0, f) }.count
                let selected = filter == f
                Button { filter = f } label: {
                    HStack {
                        Label(f.rawValue, systemImage: f.icon)
                        Spacer()
                        Text("\(count)")
                            .foregroundStyle(f == .failed && count > 0 ? Color.orange : .secondary)
                            .monospacedDigit()
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 34)
                    .foregroundStyle(selected ? Theme.accent : .primary)
                    .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accentSoft : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
            SectionLabel("Uploads to").padding(.horizontal, 10)
            HStack {
                Image(systemName: settings.uploadDestination.icon).foregroundStyle(.secondary)
                Text(settings.uploadDestination.shortTitle).font(.callout)
                Spacer()
                Button("Change") { WindowRouter.shared.showSettings(tab: .uploads) }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
        }
        .padding(12)
        .frame(width: 210)
        .background(Color.primary.opacity(0.03))
    }

    private var content: some View {
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
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(filter.rawValue).font(.title2.weight(.semibold))
            Text("\(filtered.count)").foregroundStyle(.secondary)
            Spacer()
            TextField("Search recordings", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Button { NSWorkspace.shared.open(library.folder) } label: { Image(systemName: "folder") }
                .help("Open the recordings folder in Finder")
            Button {
                // Open the recorder panel to choose display, audio and camera first; recording starts from there.
                NotificationCenter.default.post(name: .showRecorderPanel, object: nil)
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
        // The preview is a real button (reachable with Tab); the status row sits beside it, not inside it,
        // so its action button is a separate control instead of a button nested in a button.
        VStack(alignment: .leading, spacing: 8) {
            Button { WindowRouter.shared.showReview(item.url) } label: { preview }
                .buttonStyle(.plain)
                .help("Open \(item.title)")
                .accessibilityLabel(accessibilityText)
                .accessibilityHint("Opens the recording. More actions in the context menu.")
            HStack(spacing: 8) {
                statusPill
                Spacer()
                actionButton
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(hovering ? 0.07 : 0.035)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .task(id: item.url) {
            thumbnail = await ThumbnailCache.shared.image(for: item.url)
            duration = await MediaInfo.load(item.url)?.duration
        }
    }

    private var accessibilityText: String {
        var parts = [item.title, item.date.formatted(date: .abbreviated, time: .shortened), Format.bytes(item.size)]
        if let duration { parts.insert("\(Format.duration(duration)) long", at: 1) }
        if case .failed = uploads.state(for: item.url) { parts.append("upload failed") }
        else if uploads.isUploading(item.url) { parts.append("uploading") }
        else if uploads.record(for: item.url) != nil { parts.append("shared") }
        return parts.joined(separator: ", ")
    }

    private var preview: some View {
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
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func pill(_ text: String, _ fg: Color) -> some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(fg.opacity(0.14)))
            .foregroundStyle(fg)
    }

    @ViewBuilder
    private var statusPill: some View {
        if let state = uploads.state(for: item.url) {
            switch state {
            case .preparing, .uploading: pill("Uploading", Theme.accent)
            case .failed: pill("Upload failed", .orange)
            }
        } else if uploads.record(for: item.url) != nil {
            pill("Shared", .green)
        } else {
            pill("On this Mac", .secondary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let state = uploads.state(for: item.url) {
            switch state {
            case .preparing, .uploading: Button("Cancel") { uploads.cancel(item.url) }
            case .failed: Button("Retry") { uploads.upload(item.url) }
            }
        } else if let record = uploads.record(for: item.url) {
            Button("Copy link") { Pasteboard.copy(record.link.absoluteString) }
        } else if settings.uploadDestination != .none {
            Button("Upload") { uploads.upload(item.url) }
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
