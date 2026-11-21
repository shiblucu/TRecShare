@preconcurrency import AVFoundation
import SwiftUI

/// Live input level of the chosen microphone, for the meter in the menu-bar panel.
/// It runs only while the meter is on screen (panel open, mic on, not recording) and never records anything.
@MainActor
final class MicLevelMonitor: ObservableObject {
    /// 0…1, smoothed.
    @Published private(set) var level: Double = 0

    private var session: AVCaptureSession?
    private var connection: AVCaptureConnection?
    private var timer: Timer?
    private let sessionQueue = DispatchQueue(label: "trecshare.mic-level")

    func start(deviceID: String?) {
        stop()
        guard Permissions.status(for: .audio) == .granted,
              let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        self.session = session
        connection = output.connection(with: .audio)
        sessionQueue.async { session.startRunning() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        connection = nil
        if let s = session { sessionQueue.async { s.stopRunning() } }
        session = nil
        level = 0
    }

    private func sample() {
        guard let channels = connection?.audioChannels, !channels.isEmpty else { return }
        let db = channels.map { Double($0.averagePowerLevel) }.max() ?? -160
        // Map -60…0 dB to 0…1; rise quickly, fall gently.
        let target = min(max((db + 60) / 60, 0), 1)
        level = target > level ? target : level * 0.85 + target * 0.15
    }
}

/// Seven-segment level meter, as in the design.
struct MicLevelMeter: View {
    let deviceID: String?
    @StateObject private var monitor = MicLevelMonitor()
    private let segments = 7

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Double(i) < monitor.level * Double(segments) ? Color.green : Color.primary.opacity(0.12))
                    .frame(width: 10, height: 4)
            }
        }
        .accessibilityHidden(true)
        .task(id: deviceID) { monitor.start(deviceID: deviceID) }
        .onDisappear { monitor.stop() }
    }
}
