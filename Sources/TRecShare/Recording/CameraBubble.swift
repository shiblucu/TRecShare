import AppKit
@preconcurrency import AVFoundation

/// The portrait, draggable webcam window with softly rounded corners. It's a normal on-screen window,
/// so it appears in screen and area recordings exactly where you place it.
@MainActor
final class CameraBubble: NSObject {
    static let shared = CameraBubble()

    private var panel: NSPanel?
    private var session: AVCaptureSession?
    private var currentDeviceID: String?
    private let sessionQueue = DispatchQueue(label: "trecshare.camera")
    private var savedOrigin: NSPoint?

    var isVisible: Bool { panel?.isVisible ?? false }
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    func show(deviceID: String?, size: CameraSize, on screen: NSScreen?) {
        guard Permissions.status(for: .video) == .granted else { return }
        let frameSize = NSSize(size.frame(for: AppSettings.shared.cameraShape))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)

        if panel.isVisible {
            // Already on screen: keep the user's position, only follow size/camera changes.
            if panel.frame.size != frameSize { setSize(size) }
            if session == nil || device?.uniqueID != currentDeviceID { startSession(device: device) }
            return
        }

        let origin: NSPoint
        if let saved = savedOrigin, NSScreen.screens.contains(where: { $0.frame.contains(saved) }),
           screen == nil || screen!.frame.contains(saved) {
            origin = saved
        } else {
            let frame = (screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: frame.minX + 32, y: frame.minY + 32)
        }
        panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        (panel.contentView as? BubbleView)?.layoutPreview()
        panel.orderFrontRegardless()

        if session == nil || device?.uniqueID != currentDeviceID { startSession(device: device) }
    }

    func setSize(_ size: CameraSize) {
        guard let panel, panel.isVisible else { return }
        var frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let target = size.frame(for: AppSettings.shared.cameraShape)
        frame.size = NSSize(width: target.width, height: target.height)
        frame.origin = NSPoint(x: center.x - target.width / 2, y: center.y - target.height / 2)
        panel.setFrame(frame, display: true, animate: true)
        (panel.contentView as? BubbleView)?.layoutPreview()
    }

    func hide() {
        if let panel { savedOrigin = panel.frame.origin }
        panel?.orderOut(nil)
        let s = session
        session = nil
        currentDeviceID = nil
        (panel?.contentView as? BubbleView)?.previewLayer.session = nil
        sessionQueue.async { s?.stopRunning() }
    }

    private func startSession(device: AVCaptureDevice?) {
        let old = session
        sessionQueue.async { old?.stopRunning() }
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            Log.recorder.error("camera not available")
            return
        }
        let s = AVCaptureSession()
        s.beginConfiguration()
        s.sessionPreset = .high
        if s.canAddInput(input) { s.addInput(input) }
        s.commitConfiguration()
        session = s
        currentDeviceID = device.uniqueID
        if let view = panel?.contentView as? BubbleView {
            view.previewLayer.session = s
            if let conn = view.previewLayer.connection, conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true
            }
        }
        sessionQueue.async { s.startRunning() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.title = "Camera"
        panel.setAccessibilityLabel("Camera preview. Drag to move. Right-click for shape and size.")
        panel.contentView = BubbleView()
        return panel
    }
}

/// Circular camera preview. Right-click for size options.
private final class BubbleView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderWidth = 3
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layoutPreview()
    }

    func layoutPreview() {
        // Circle: fully round. Portrait: moderate corners (10% of the width).
        layer?.cornerRadius = AppSettings.shared.cameraShape == .circle ? bounds.width / 2 : (bounds.width * 0.1).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for size in CameraSize.allCases {
            let item = NSMenuItem(title: size.title, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.representedObject = size.rawValue
            item.target = self
            item.state = AppSettings.shared.cameraSize == size ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for shape in CameraShape.allCases {
            let item = NSMenuItem(title: shape.title, action: #selector(pickShape(_:)), keyEquivalent: "")
            item.representedObject = shape.rawValue
            item.target = self
            item.state = AppSettings.shared.cameraShape == shape ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // While recording, hiding is temporary and matches the control bar's Hide camera button.
        let recording = RecorderModel.shared.cameraInRecording
        let hide = NSMenuItem(title: recording ? "Hide Camera" : "Turn Camera Off",
                              action: recording ? #selector(hideDuringRecording) : #selector(turnOff), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        return menu
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = CameraSize(rawValue: raw) else { return }
        AppSettings.shared.cameraSize = size
        CameraBubble.shared.setSize(size)
    }

    @objc private func pickShape(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let shape = CameraShape(rawValue: raw) else { return }
        AppSettings.shared.cameraShape = shape
        CameraBubble.shared.setSize(AppSettings.shared.cameraSize)
    }

    @objc private func hideDuringRecording() {
        RecorderModel.shared.toggleCameraHidden()
    }

    @objc private func turnOff() {
        AppSettings.shared.cameraEnabled = false
        CameraBubble.shared.hide()
    }
}

private extension NSSize {
    init(_ size: CGSize) { self.init(width: size.width, height: size.height) }
}
