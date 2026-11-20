import AppKit
import SwiftUI

/// The panel that drops down from the menu-bar icon.
struct RecorderPanel: View {
    @EnvironmentObject private var model: RecorderModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var uploads: UploadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.state.isCapturing || model.state == .finishing {
                recordingControls.padding(16)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    modePicker
                    sourceSection
                    Divider()
                    devicesSection
                    Divider()
                    optionsRow
                }
                .padding(16)
                .disabled(model.isBusy)

                VStack(spacing: 8) {
                    recordButton
                    if model.state == .idle {
                        Button { model.takeScreenshot() } label: {
                            Label(settings.captureMode == .area ? "Select area & take screenshot" : "Take screenshot",
                                  systemImage: "camera.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .help("Saves a PNG and copies it to the clipboard (\(HotKeys.screenshot.display))")
                    }
                    HStack {
                        Toggle("3-second countdown", isOn: $settings.countdownEnabled).toggleStyle(.checkbox)
                        Spacer()
                        if settings.hotkeysEnabled {
                            Text("\(HotKeys.toggleRecording.display) record · \(HotKeys.screenshot.display) screenshot").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .disabled(model.isBusy)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }

            if let message = model.errorMessage { errorBox(message) }
            if let last = model.lastRecording, !model.state.isCapturing { lastRecordingRow(last) }
        }
        .frame(width: 360)
        .task { await model.refreshSources(followCursor: true) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.accent)
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "video.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                .accessibilityHidden(true)
            Text("TRecShare").font(.headline)
            Spacer()
            headerButton("rectangle.stack", "Library") { WindowRouter.shared.showLibrary() }
            headerButton("gearshape", "Settings") { WindowRouter.shared.showSettings() }
            headerButton("power", "Quit TRecShare") { NSApp.terminate(nil) }
                .disabled(model.state.isCapturing || model.state == .finishing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func headerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }

    // MARK: - Source

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(CaptureMode.allCases) { mode in
                let selected = settings.captureMode == mode
                Button { settings.captureMode = mode } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mode.icon).font(.system(size: 15))
                        Text(mode.title).font(.caption.weight(selected ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                        .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record \(mode.title)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private var sourceSection: some View {
        switch settings.captureMode {
        case .screen, .area:
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(settings.captureMode == .area ? "Display (drag to pick the area after you press Record)" :
                                (model.displays.count > 1 ? "Screen to record" : "Display"))
                if model.displays.isEmpty {
                    Text(model.needsScreenPermission ? "Waiting for Screen Recording permission…" : "Looking for displays…")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 5) {
                        ForEach(model.displays) { displayRow($0) }
                    }
                }
            }
        case .window:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionLabel("Window to record")
                    Spacer()
                    Button { Task { await model.refreshSources() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Refresh the window list")
                }
                if model.windows.isEmpty {
                    Text("No windows found. Open the app you want to record, then refresh.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("Window", selection: $model.selectedWindowID) {
                        ForEach(model.windows) { Text($0.label).lineLimit(1).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    Text("The camera isn't included in window recordings.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func displayRow(_ d: DisplayChoice) -> some View {
        let selected = model.selectedDisplayID == d.id
        return Button { model.selectedDisplayID = d.id } label: {
            HStack(spacing: 8) {
                Image(systemName: d.isMain ? "laptopcomputer" : "display")
                Text(d.name).lineLimit(1)
                if d.isMain { Text("Main").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.accentSoft : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Theme.accent : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Devices

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            deviceRow(icon: "video", title: "Camera",
                      isOn: Binding(get: { settings.cameraEnabled }, set: { model.setCameraEnabled($0) }),
                      devices: model.cameras, selection: $settings.cameraID,
                      emptyText: "No camera found")
            deviceRow(icon: "mic", title: "Microphone",
                      isOn: Binding(get: { settings.microphoneEnabled }, set: { model.setMicrophoneEnabled($0) }),
                      devices: model.microphones, selection: $settings.microphoneID,
                      emptyText: "No microphone found", showsLevel: true)
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2").frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("System audio").font(.callout)
                    Text("Sound from apps and the browser").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("System audio", isOn: $settings.systemAudioEnabled).labelsHidden().toggleStyle(.switch)
            }
        }
        .controlSize(.small)
    }

    private func deviceRow(icon: String, title: String, isOn: Binding<Bool>, devices: [DeviceChoice],
                           selection: Binding<String?>, emptyText: String, showsLevel: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary).accessibilityHidden(true)
            if isOn.wrappedValue {
                if devices.isEmpty {
                    Text(emptyText).font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker(title, selection: selection) {
                            ForEach(devices) { Text($0.name).lineLimit(1).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        if showsLevel && model.panelVisible && model.state == .idle {
                            MicLevelMeter(deviceID: selection.wrappedValue)
                        }
                    }
                }
            } else {
                Text("No \(title.lowercased())").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }

    // MARK: - Options

    private var optionsRow: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Quality")
                Picker("Quality", selection: $settings.quality) {
                    ForEach(RecordingQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .help(settings.quality.sizeHint)
            }
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("After recording")
                Picker("Upload to", selection: $settings.uploadDestination) {
                    ForEach(UploadDestination.allCases) { Label($0.shortTitle, systemImage: $0.icon).tag($0) }
                }
                .labelsHidden()
                .help("Where finished recordings are uploaded. Set the details in Settings → Uploads.")
            }
        }
        .controlSize(.small)
    }

    // MARK: - Record button

    @ViewBuilder
    private var recordButton: some View {
        switch model.state {
        case .idle:
            bigButton(settings.captureMode == .area ? "Select area & record" : "Start recording", color: Theme.accent, symbol: "circle.fill") {
                model.startRecording()
            }
            .keyboardShortcut(.defaultAction)
        case .preparing:
            bigButton("Getting ready…", color: .gray, symbol: nil) { model.cancelStart() }
        case .selectingArea:
            bigButton("Select an area… (Esc to cancel)", color: .gray, symbol: nil) { model.cancelStart() }
        case .countdown(let n):
            bigButton("Starting in \(n)… (click to cancel)", color: .gray, symbol: nil) { model.cancelStart() }
        default:
            EmptyView()
        }
    }

    private var recordingControls: some View {
        VStack(spacing: 10) {
            HStack {
                Circle().fill(model.state == .paused ? Color.orange : Theme.accent).frame(width: 10, height: 10)
                Text(model.state == .paused ? "Paused" : model.state == .finishing ? "Saving…" : "Recording")
                    .font(.headline)
                Spacer()
                Text(model.elapsedText).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            }
            HStack(spacing: 8) {
                Button { model.togglePause() } label: {
                    Label(model.state == .paused ? "Resume" : "Pause", systemImage: model.state == .paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                Button(role: .destructive) { RecordingPrompts.confirmDiscard(model) } label: {
                    Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
            .disabled(model.state == .finishing)
            if model.micInRecording || model.cameraInRecording {
                HStack(spacing: 8) {
                    if model.micInRecording {
                        Button { model.toggleMicMute() } label: {
                            Label(model.micMuted ? "Unmute mic" : "Mute mic",
                                  systemImage: model.micMuted ? "mic.slash.fill" : "mic.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if model.cameraInRecording {
                        Button { model.toggleCameraHidden() } label: {
                            Label(model.cameraHidden ? "Show camera" : "Hide camera",
                                  systemImage: model.cameraHidden ? "video.slash.fill" : "video.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .disabled(model.state == .finishing)
            }
            bigButton("Finish recording", color: Theme.accent, symbol: "stop.fill") { model.stopRecording() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.state == .finishing)
        }
    }

    private func bigButton(_ title: String, color: Color, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
                Text(title).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Messages

    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.needsScreenPermission {
                    Button("Screen Recording settings") { Permissions.openScreenRecordingSettings() }
                }
                if model.needsMicrophonePermission {
                    Button("Microphone settings") { Permissions.openMicrophoneSettings() }
                }
                if model.needsCameraPermission {
                    Button("Camera settings") { Permissions.openCameraSettings() }
                }
                Spacer()
                Button("Dismiss") { model.errorMessage = nil }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func lastRecordingRow(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Review") { WindowRouter.shared.showReview(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            UploadStatusView(url: url, compact: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }
}
