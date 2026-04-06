import Carbon.HIToolbox
import AppKit

/// Registers a global hotkey using the Carbon EventHotKey API.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    /// Register Ctrl+Shift+Space (default) or custom combo.
    func register(keyCode: UInt32 = UInt32(kVK_Space),
                  modifiers: UInt32 = UInt32(controlKey | shiftKey),
                  action: @escaping () -> Void) {
        self.handler = action

        // Install a Carbon event handler on the application event target
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              UInt32(kEventParamDirectObject),
                              UInt32(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if hkID.id == 1 {
                HotkeyManager.shared.handler?()
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)

        let hkID = EventHotKeyID(signature: OSType(0x4C454946), id: 1)  // 'LEIF'
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        handler = nil
    }
}
