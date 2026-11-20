import Carbon.HIToolbox
import Foundation

/// System-wide keyboard shortcuts (work in any app, no Accessibility permission needed).
@MainActor
final class HotKeys {
    static let shared = HotKeys()

    struct Shortcut {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: UInt32
        let display: String
    }

    static let toggleRecording = Shortcut(id: 1, keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey), display: "⌥⇧R")
    static let togglePause = Shortcut(id: 2, keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | shiftKey), display: "⌥⇧P")
    static let screenshot = Shortcut(id: 4, keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey), display: "⌥⇧S")
    static let cancelRecording = Shortcut(id: 3, keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey | shiftKey), display: "⌥⇧C")

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        unregister(shortcut.id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5343_4B54), id: shortcut.id)   // 'SCKT'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[shortcut.id] = ref
            handlers[shortcut.id] = action
        } else {
            Log.app.error("could not register shortcut \(shortcut.display): \(status)")
        }
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id) }
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
