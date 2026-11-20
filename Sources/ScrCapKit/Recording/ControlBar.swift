import AppKit
import SwiftUI

/// Floating controls while recording: timer, pause/resume, restart, delete, finish.
/// It belongs to ScrCapKit, so it is never captured in the video.
@MainActor
enum ControlBar {
    private static var panel: NSPanel?

    static func show(model: RecorderModel, on screen: NSScreen) {
        hide()
        let host = NSHostingView(rootView: ControlBarView().environmentObject(model))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.minY + 28, width: size.width, height: size.height)
        let p = DraggablePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = host
        p.setAccessibilityLabel("Recording controls")
        p.orderFrontRegardless()
        panel = p
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Resizes the panel to its content, keeping it centred where it is.
    static func refit() {
        guard let panel, let view = panel.contentView else { return }
        DispatchQueue.main.async {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            var frame = panel.frame
            frame.origin.x += (frame.width - size.width) / 2
            frame.size = size
            panel.setFrame(frame, display: true)
        }
    }

    private final class DraggablePanel: NSPanel {
        override var canBecomeKey: Bool { false }
    }
}

private struct ControlBarView: View {
    @EnvironmentObject private var model: RecorderModel
    private enum Confirm { case delete, restart }
    @State private var confirm: Confirm?
    @State private var blink = false

    var body: some View {
        HStack(spacing: 4) {
            if let confirm {
                Text(confirm == .delete ? "Delete this recording?" : "Delete and start over?")
                    .font(.callout.weight(.medium)).padding(.horizontal, 8)
                pill(confirm == .delete ? "Delete" : "Restart", role: .destructive) {
                    if confirm == .delete { model.discardRecording() } else { model.restartRecording() }
                }
                pill("Cancel") { self.confirm = nil }
            } else {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.state == .paused ? Color.orange : Theme.accent)
                        .frame(width: 9, height: 9)
                        .opacity(model.state == .recording && blink ? 0.35 : 1)
                    Text(model.elapsedText)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(minWidth: 48, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.state == .paused ? "Paused at \(model.elapsedText)" : "Recording, \(model.elapsedText)")

                Divider().frame(height: 22).opacity(0.4)

                iconButton(model.state == .paused ? "play.fill" : "pause.fill",
                           help: model.state == .paused ? "Resume (⌥⇧P)" : "Pause (⌥⇧P)") { model.togglePause() }
                iconButton("arrow.counterclockwise", help: "Restart: delete and record again") { confirm = .restart }
                iconButton("trash", help: "Delete recording") { confirm = .delete }

                Button { model.stopRecording() } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                        Text("Finish").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .help("Finish recording (⌥⇧R)")
                .padding(.leading, 4)
            }
        }
        .padding(6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .fixedSize()
        .disabled(model.state == .finishing)
        .onChange(of: confirm) { _, _ in ControlBar.refit() }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { blink = true }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(HoverCircleStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func pill(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(role == .destructive ? .white : .primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(role == .destructive ? Theme.accent : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

struct HoverCircleStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0)))
            .onHover { hovering = $0 }
    }
}
