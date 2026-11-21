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
    /// Selection mode: click cards to tick them, then act on all ticked recordings at once.
    @State private var selecting = false
    @State private var selection = Set<URL>()
    @State private var working = false

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
        .onChange(of: library.items) { _, items in
            let existing = Set(items.map(\.url))
            selection = selection.intersection(existing)
        }
        .onExitCommand { if selecting { endSelecting() } }
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
                    .font(.app(.callout).weight(selected ? .semibold : .regular))
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
                Text(settings.uploadDestination.shortTitle).font(.app(.callout))
                Spacer()
                Button("Change") { WindowRouter.shared.showSettings(tab: .uploads) }
                    .buttonStyle(.link).font(.app(.caption))
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
                            RecordingCard(item: item,
                                          selecting: selecting,
                                          selected: selection.contains(item.url),
                                          onToggle: { toggle(item.url) },
                                          onDelete: {
                                              Task { if await OnlineCopyPrompts.confirmTrash(item.url) { try? library.trash(item.url) } }
                                          })
                        }
                    }
                    .padding(20)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { selectionBar }
        }
    }

    // MARK: - Selecting several recordings

    private func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    private func endSelecting() {
        selecting = false
        selection = []
    }

    private var selectedItems: [RecordingItem] { library.items.filter { selection.contains($0.url) } }
    private var selectedWithOnlineCopy: Int { selectedItems.filter { uploads.hasOnlineCopy($0.url) }.count }

    private var selectionBar: some View {
        let count = selection.count
        let allSelected = !filtered.isEmpty && filtered.allSatisfy { selection.contains($0.url) }
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(count == 0 ? "Select recordings" : "\(count) selected")
                    .font(.app(.callout).weight(.semibold))
                    .monospacedDigit()
                Button(allSelected ? "Select None" : "Select All") {
                    if allSelected { selection.subtract(filtered.map(\.url)) } else { selection.formUnion(filtered.map(\.url)) }
                }
                .buttonStyle(.link)
                .hoverLabel(allSelected ? "Untick the recordings shown here" : "Tick every recording shown here")
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Menu {
                    UploadChoiceMenu { destination, quality in
                        let urls = OnlineCopyPrompts.confirmUploadMany(selectedItems.map(\.url), to: destination, quality: quality)
                        guard !urls.isEmpty else { return }
                        uploads.uploadMany(urls, to: destination, quality: quality)
                        if urls.count > 1 { endSelecting() }
                    }
                } label: {
                    Label("Upload", systemImage: "icloud.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(count == 0 || working)
                .hoverLabel("Upload the selected recordings: choose the cloud, then the size. Two are sent at a time.")
                Button {
                    working = true
                    Task {
                        await OnlineCopyPrompts.confirmAndDeleteOnlineCopies(of: selectedItems.map(\.url))
                        working = false
                    }
                } label: {
                    Label("Delete Online Copies", systemImage: "trash.slash")
                }
                .disabled(count == 0 || selectedWithOnlineCopy == 0 || working)
                .hoverLabel(selectedWithOnlineCopy == 0
                            ? "None of the selected recordings has an uploaded copy"
                            : "Remove the uploaded copies of \(selectedWithOnlineCopy) selected \(selectedWithOnlineCopy == 1 ? "recording" : "recordings") from the cloud. The recordings stay on this Mac.")
                Button(role: .destructive) {
                    working = true
                    Task {
                        let toTrash = await OnlineCopyPrompts.confirmTrash(selectedItems.map(\.url))
                        for url in toTrash { try? library.trash(url) }
                        working = false
                        if !toTrash.isEmpty { selection.subtract(toTrash) }
                    }
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(count == 0 || working)
                .hoverLabel("Move the selected recordings to the Trash (you can restore them from there)")
                Button("Done") { endSelecting() }
                    .keyboardShortcut(.cancelAction)
                    .hoverLabel("Leave selection mode")
            }
            .controlSize(.regular)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(filter.rawValue).font(.app(.title2).weight(.semibold))
            Text("\(filtered.count)").foregroundStyle(.secondary)
            Spacer()
            TextField("Search recordings", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            Button {
                if selecting { endSelecting() } else { selecting = true }
            } label: {
                Label(selecting ? "Done" : "Select", systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .disabled(library.items.isEmpty)
            .hoverLabel(selecting ? "Leave selection mode" : "Select several recordings to delete them together")
            Button { NSWorkspace.shared.open(library.folder) } label: { Image(systemName: "folder") }
                .hoverLabel("Open the recordings folder in Finder")
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
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 96, height: 96)
                Image(systemName: "video.badge.plus").font(.system(size: 40, weight: .medium)).foregroundStyle(Theme.accent)
            }
            .accessibilityHidden(true)
            Text("No recordings yet").font(.app(.title2).weight(.semibold))
            Text("Record your screen, camera and voice, then share a link.\nPress \(HotKeys.toggleRecording.display) or click the menu-bar icon.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                // Same as the toolbar: choose display, audio and camera first.
                NotificationCenter.default.post(name: .showRecorderPanel, object: nil)
            } label: {
                Label("New Recording", systemImage: "record.circle")
            }
            .buttonStyle(.brand)
            .frame(width: 220)
            .disabled(model.isBusy)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

private struct RecordingCard: View {
    let item: RecordingItem
    var selecting = false
    var selected = false
    var onToggle: () -> Void = {}
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
            Button {
                if selecting { onToggle() } else { WindowRouter.shared.showReview(item.url) }
            } label: { preview }
                .buttonStyle(.plain)
                .hoverLabel(selecting ? (selected ? "Untick \(item.title)" : "Tick \(item.title)") : "Open \(item.title)")
                .accessibilityLabel(accessibilityText)
                .accessibilityHint(selecting ? "Selects or deselects this recording." : "Opens the recording. More actions in the context menu.")
                .accessibilityAddTraits(selecting && selected ? .isSelected : [])
            HStack(spacing: 8) {
                statusPill
                Spacer()
                Group {
                actionButton
                if !uploads.isUploading(item.url) {
                    Menu {
                        ReuploadMenu(url: item.url)
                    } label: {
                        Image(systemName: "icloud.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .hoverLabel(uploads.record(for: item.url) == nil ? "Upload to… (choose cloud and size)" : "Upload again… (choose cloud and size)")
                    .accessibilityLabel(uploads.record(for: item.url) == nil ? "Upload to another cloud or size" : "Upload again with another cloud or size")
                }
                }
                .disabled(selecting)   // while ticking recordings, the card's own buttons stay out of the way
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Theme.accentSoft : Color.primary.opacity(hovering ? 0.07 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
        .overlay(alignment: .topLeading) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Theme.accent : Color.white)
                    .background(Circle().fill(selected ? Color.white : Color.black.opacity(0.35)).padding(2))
                    .padding(16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
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
                        .font(.app(.caption2).weight(.semibold)).monospacedDigit()
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

            Text(item.title).font(.app(.callout).weight(.semibold)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 6) {
                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(Format.bytes(item.size))
                Spacer()
            }
            .font(.app(.caption))
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func pill(_ text: String, _ fg: Color) -> some View {
        Text(text).font(.app(.caption).weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(fg.opacity(0.14)))
            .foregroundStyle(fg)
    }

    @ViewBuilder
    private var statusPill: some View {
        if uploads.isDeletingOnline(item.url) {
            pill("Deleting online copy…", .orange)
        } else if let state = uploads.state(for: item.url) {
            switch state {
            case .queued: pill("Queued", .secondary)
            case .preparing, .uploading: pill("Uploading", Theme.accent)
            case .failed: pill("Upload failed", .orange)
            }
        } else if uploads.record(for: item.url) != nil {
            pill("Shared", .green)
        } else if uploads.hasOnlineCopy(item.url) {
            pill("Link expired", .orange)
        } else {
            pill("On this Mac", .secondary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let state = uploads.state(for: item.url) {
            switch state {
            case .queued, .preparing, .uploading: Button("Cancel") { uploads.cancel(item.url) }
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
        Menu(uploads.record(for: item.url) == nil ? "Upload to…" : "Upload Again to…") {
            ReuploadMenu(url: item.url)
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Move to Trash", role: .destructive, action: onDelete)
    }
}
