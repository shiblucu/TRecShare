import AVFoundation
import SwiftUI
import UserNotifications

/// First-run guide: explains the app and walks through the permissions it needs.
struct WelcomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var screen = Permissions.hasScreenAccess
    @State private var mic = Permissions.status(for: .audio)
    @State private var camera = Permissions.status(for: .video)
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12).fill(Theme.accent).frame(width: 52, height: 52)
                    .overlay(Image(systemName: "video.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to TRecShare").font(.app(.title).weight(.bold))
                    Text("Record your screen, camera and voice. Share a link in seconds.").foregroundStyle(.secondary)
                }
            }

            Text("TRecShare needs a few permissions. Nothing leaves your Mac unless you set up uploads.")
                .font(.app(.callout))

            VStack(spacing: 10) {
                row("Screen Recording", "Required to record your screen.", "rectangle.dashed.badge.record",
                    granted: screen, denied: false) {
                    Permissions.requestScreenAccess()
                    Permissions.openScreenRecordingSettings()
                }
                row("Microphone", "To record your voice.", "mic.fill",
                    granted: mic == .granted, denied: mic == .denied) {
                    if mic == .notAsked { Task { _ = await Permissions.request(.audio); refresh() } } else { Permissions.openMicrophoneSettings() }
                }
                row("Camera", "Optional, to show yourself on screen.", "video.fill",
                    granted: camera == .granted, denied: camera == .denied) {
                    if camera == .notAsked { Task { _ = await Permissions.request(.video); refresh() } } else { Permissions.openCameraSettings() }
                }
                row("Notifications", "To tell you when a recording is saved or a link is ready.", "bell.badge.fill",
                    granted: notifications == .authorized || notifications == .provisional, denied: notifications == .denied) {
                    if notifications == .notDetermined {
                        Notifier.shared.requestPermissionIfNeeded { Task { @MainActor in refresh() } }
                    } else {
                        Permissions.openNotificationSettings()
                    }
                }
            }

            if !screen {
                Text("After allowing Screen Recording, macOS may ask you to quit and reopen TRecShare.")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Click the \(Image(systemName: "video.circle")) icon in the menu bar, or press \(HotKeys.toggleRecording.display), to record.", systemImage: "1.circle")
                    Label("Use the floating bar to pause, restart or finish.", systemImage: "2.circle")
                    Label("Set up Google Drive, Spaces or your server in Settings → Uploads to get a share link automatically.", systemImage: "3.circle")
                }
                .font(.app(.callout))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
            HStack {
                Button("Set Up Uploads…") { WindowRouter.shared.showSettings(tab: .uploads) }
                Spacer()
                Button("Get Started") {
                    settings.hasCompletedOnboarding = true
                    WindowRouter.shared.close("welcome")
                }
                .buttonStyle(.brand)
                .frame(width: 160)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: (560 * settings.textSize.scale).rounded())
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        screen = Permissions.hasScreenAccess
        mic = Permissions.status(for: .audio)
        camera = Permissions.status(for: .video)
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let status = s.authorizationStatus
            Task { @MainActor in notifications = status }
        }
    }

    private func row(_ title: String, _ detail: String, _ icon: String, granted: Bool, denied: Bool,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).frame(width: 28).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.app(.headline))
                Text(detail).font(.app(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button(denied ? "Open Settings" : "Allow", action: action)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}
