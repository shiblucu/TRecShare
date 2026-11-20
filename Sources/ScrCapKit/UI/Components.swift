import AppKit
import SwiftUI

enum Theme {
    /// Calm, trustworthy blue used for the brand, buttons and the recording indicator (#3D78D9).
    static let accent = Color(red: 0.239, green: 0.471, blue: 0.851)
    static let nsAccent = NSColor(srgbRed: 0.239, green: 0.471, blue: 0.851, alpha: 1)
    /// Softer tint for selected backgrounds.
    static let accentSoft = accent.opacity(0.12)
}

/// Upload state for one recording: Upload button → progress → link (copy/open) or error (retry).
struct UploadStatusView: View {
    let url: URL
    var compact = false
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if let state = uploads.state(for: url) {
                switch state {
                case .preparing(let p):
                    progressRow("Preparing upload…", p)
                case .uploading(let p):
                    progressRow(p < 0 ? "Uploading…" : "Uploading \(Int(p * 100))%", p < 0 ? nil : p)
                case .failed(let message):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(message).font(.caption).lineLimit(compact ? 2 : 4).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if settings.missingSetup(for: settings.uploadDestination) != nil {
                            Button("Settings") { WindowRouter.shared.showSettings(tab: .uploads) }
                        } else {
                            Button("Retry") { uploads.upload(url) }
                        }
                        Button { uploads.dismissError(url) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .help("Dismiss")
                    }
                }
            } else if let record = uploads.record(for: url) {
                linkRow(record)
            } else {
                uploadButton
            }
        }
        .controlSize(.small)
    }

    private func progressRow(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 8) {
            if let value {
                ProgressView(value: value).frame(maxWidth: compact ? 120 : 220)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(label).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 4)
            Button("Cancel") { uploads.cancel(url) }
        }
    }

    private func linkRow(_ record: UploadResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link").foregroundStyle(.green).accessibilityHidden(true)
            Text(record.link.absoluteString)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(record.expiresAt.map { "Link expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? record.link.absoluteString)
            Spacer(minLength: 4)
            Button("Copy Link") { Pasteboard.copy(record.link.absoluteString) }
            Button("Open") { NSWorkspace.shared.open(record.link) }
        }
    }

    @ViewBuilder
    private var uploadButton: some View {
        HStack(spacing: 6) {
            if settings.uploadDestination == .none {
                Button {
                    WindowRouter.shared.showSettings(tab: .uploads)
                } label: {
                    Label("Set up uploads to share a link", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                Menu {
                    Section("Upload size") {
                        ForEach(UploadQuality.allCases) { q in
                            Button(q.title) { uploads.upload(url, quality: q) }
                        }
                    }
                } label: {
                    Label("Upload & copy link", systemImage: "icloud.and.arrow.up")
                } primaryAction: {
                    uploads.upload(url)
                }
                .fixedSize()
                .help("Uploads to \(settings.uploadDestination.shortTitle) at \(settings.uploadQuality.shortTitle). Use the arrow for other sizes.")
                Text("to \(settings.uploadDestination.shortTitle)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Grey section label used across the panel and settings.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }
}

/// Wraps NSVisualEffectView for window backgrounds.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
