import AppKit
import SwiftUI

enum Theme {
    /// Calm, trustworthy blue for the brand, buttons and the recording indicator (#2E6BD3).
    /// White text on it has a 5:1 contrast ratio (meets WCAG AA).
    static let accent = Color(red: 0.180, green: 0.420, blue: 0.827)
    static let nsAccent = NSColor(srgbRed: 0.180, green: 0.420, blue: 0.827, alpha: 1)
    /// Softer tint for selected backgrounds.
    static let accentSoft = accent.opacity(0.12)
}

/// Applies the font and text size chosen in Settings → General → Appearance to a whole window or panel.
/// Text without its own font uses the chosen size. Text that sets a style (`.app(.caption)`, `.appSize(14)`)
/// is scaled by the same factor. The view is rebuilt when the choice changes, so every screen updates at once.
struct AppAppearance: ViewModifier {
    @ObservedObject private var settings = AppSettings.shared

    func body(content: Content) -> some View {
        content
            .font(.system(size: settings.textSize.bodySize, design: settings.fontStyle.design))
            .fontDesign(settings.fontStyle.design)
            .controlSize(settings.textSize.controlSize)
            .id("\(settings.textSize.rawValue)-\(settings.fontStyle.rawValue)")
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearance()) }
}

extension Font {
    /// macOS point sizes of the text styles at the default setting.
    private static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .subheadline, .callout: return 12
        case .footnote, .caption: return 10
        case .caption2: return 10
        @unknown default: return 13
        }
    }

    /// A text style that follows the Text size chosen in Settings (SwiftUI's own styles don't on macOS).
    @MainActor static func app(_ style: Font.TextStyle) -> Font {
        let settings = AppSettings.shared
        let weight: Font.Weight = style == .headline ? .semibold : .regular
        return .system(size: (baseSize(style) * settings.textSize.scale).rounded(), weight: weight, design: settings.fontStyle.design)
    }

    /// A fixed point size that follows the Text size chosen in Settings.
    @MainActor static func appSize(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design? = nil) -> Font {
        let settings = AppSettings.shared
        return .system(size: (size * settings.textSize.scale).rounded(), weight: weight, design: design ?? settings.fontStyle.design)
    }
}

/// Brand button styles: a filled primary for the main action, a soft secondary for the rest.
/// Both show hover, pressed and disabled states and keep a visible focus ring for keyboard users.
struct BrandButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .primary
    var tint: Color = Theme.accent
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.appSize(14, weight: .semibold))
            .foregroundStyle(kind == .primary ? Color.white : tint)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                shape.fill(kind == .primary
                           ? AnyShapeStyle(LinearGradient(colors: [tint.opacity(hovering ? 1 : 0.94), tint.opacity(hovering ? 0.88 : 0.8)],
                                                          startPoint: .top, endPoint: .bottom))
                           : AnyShapeStyle(tint.opacity(hovering ? 0.18 : 0.10)))
            )
            .overlay(shape.strokeBorder(kind == .primary ? Color.white.opacity(0.18) : tint.opacity(0.35), lineWidth: 1))
            .shadow(color: kind == .primary ? tint.opacity(pressed ? 0.15 : 0.35) : .clear, radius: pressed ? 2 : 6, y: pressed ? 1 : 3)
            .scaleEffect(pressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: pressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static var brand: BrandButtonStyle { BrandButtonStyle() }
    static var brandSecondary: BrandButtonStyle { BrandButtonStyle(kind: .secondary) }
}

/// "Upload again" choices: pick any set-up cloud destination and an upload size.
/// The new upload replaces the saved link; the earlier copy stays where it was uploaded.
/// Menu items for choosing a cloud destination and then an upload size. Used for one recording or a selection.
struct UploadChoiceMenu: View {
    let choose: (UploadDestination, UploadQuality) -> Void
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ForEach(UploadDestination.allCases.filter { $0 != .none }) { destination in
            if settings.missingSetup(for: destination) == nil {
                Menu {
                    ForEach(UploadQuality.allCases) { quality in
                        Button(quality.title) { choose(destination, quality) }
                    }
                } label: {
                    Label(destination.title, systemImage: destination.icon)
                }
            } else {
                Button { WindowRouter.shared.showSettings(tab: .uploads) } label: {
                    Label("\(destination.title) (set up in Settings)", systemImage: destination.icon)
                }
            }
        }
    }
}

struct ReuploadMenu: View {
    let url: URL
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        UploadChoiceMenu { destination, quality in uploads.upload(url, to: destination, quality: quality) }
        if uploads.hasOnlineCopy(url) {
            Divider()
            Button(role: .destructive) {
                Task { await OnlineCopyPrompts.confirmAndDeleteOnlineCopy(url) }
            } label: {
                Label("Delete Online Copy…", systemImage: "trash.slash")
            }
            .disabled(uploads.isDeletingOnline(url))
        }
    }
}

/// Upload state for one recording: Upload button → progress → link (copy/open) or error (retry).
struct UploadStatusView: View {
    let url: URL
    var compact = false
    /// Where to upload; nil means the default from Settings.
    var destination: UploadDestination? = nil
    @EnvironmentObject private var uploads: UploadManager
    @EnvironmentObject private var settings: AppSettings

    private var target: UploadDestination { destination ?? settings.uploadDestination }

    var body: some View {
        Group {
            if let state = uploads.state(for: url) {
                switch state {
                case .queued:
                    progressRow("Waiting for other uploads…", nil)
                case .preparing(let p):
                    progressRow("Preparing upload…", p)
                case .uploading(let p):
                    progressRow(p < 0 ? "Uploading…" : "Uploading \(Int(p * 100))%", p < 0 ? nil : p)
                case .failed(let message):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(message).font(.app(.caption)).lineLimit(compact ? 2 : 4).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        // Retry goes to the destination that failed, wherever the upload was started.
                        if settings.missingSetup(for: uploads.destination(for: url) ?? target) != nil {
                            Button("Settings") { WindowRouter.shared.showSettings(tab: .uploads) }
                        } else {
                            Button("Retry") { uploads.upload(url) }
                        }
                        Button { uploads.dismissError(url) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .hoverLabel("Dismiss")
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
            Text(label).font(.app(.caption)).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 4)
            Button("Cancel") { uploads.cancel(url) }
        }
    }

    private func linkRow(_ record: UploadResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link").foregroundStyle(.green).accessibilityHidden(true)
            Text(record.link.absoluteString)
                .font(.app(.caption))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .hoverLabel(record.expiresAt.map { "Link expires \($0.formatted(date: .abbreviated, time: .shortened))" } ?? record.link.absoluteString)
            Spacer(minLength: 4)
            Button("Copy Link") { Pasteboard.copy(record.link.absoluteString) }
            Button("Open") { NSWorkspace.shared.open(record.link) }
        }
    }

    @ViewBuilder
    private var uploadButton: some View {
        HStack(spacing: 6) {
            if target == .none {
                Button {
                    WindowRouter.shared.showSettings(tab: .uploads)
                } label: {
                    Label("Set up uploads to share a link", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.link)
                .font(.app(.caption))
            } else {
                Menu {
                    Section("Upload size") {
                        ForEach(UploadQuality.allCases) { q in
                            Button(q.title) { uploads.upload(url, to: target, quality: q) }
                        }
                    }
                } label: {
                    Label("Upload & copy link", systemImage: "icloud.and.arrow.up")
                } primaryAction: {
                    uploads.upload(url, to: target)
                }
                .fixedSize()
                .hoverLabel("Uploads to \(target.shortTitle) at \(settings.uploadQuality.shortTitle). Use the arrow for other sizes.")
                if destination == nil {
                    Text("to \(target.shortTitle)").font(.app(.caption)).foregroundStyle(.secondary)
                }
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
        Text(text).font(.app(.caption).weight(.medium)).foregroundStyle(.secondary)
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
