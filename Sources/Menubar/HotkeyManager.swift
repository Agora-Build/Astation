import Cocoa
import Carbon.HIToolbox

/// Manages system-wide global hotkeys using Carbon's RegisterEventHotKey API.
/// Ctrl+V toggles voice (mic mute/unmute), Ctrl+Shift+V toggles video (screen share).
class HotkeyManager {
    private var voiceHotkeyRef: EventHotKeyRef?
    private var videoHotkeyRef: EventHotKeyRef?

    /// Called when Ctrl+V is pressed (voice toggle).
    var onVoiceToggle: (() -> Void)?

    /// Called when Ctrl+Shift+V is pressed (video toggle).
    var onVideoToggle: (() -> Void)?

    private static let voiceHotkeyID = UInt32(1)
    private static let videoHotkeyID = UInt32(2)
    private static let hotkeySignature = OSType(0x4154454D)  // "ATEM" in ASCII

    // Static reference for the C callback to reach this instance.
    private static weak var shared: HotkeyManager?

    init() {
        HotkeyManager.shared = self
    }

    deinit {
        unregisterAll()
    }

    /// Register global hotkeys. Call once after init.
    func registerHotkeys() {
        // Install the Carbon event handler for kEventHotKeyPressed
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                return HotkeyManager.handleHotKeyEvent(event)
            },
            1,
            &eventType,
            nil,
            nil
        )

        // Ctrl+V → voice toggle
        var voiceKeyID = EventHotKeyID(
            signature: HotkeyManager.hotkeySignature,
            id: HotkeyManager.voiceHotkeyID
        )
        let voiceResult = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey),
            voiceKeyID,
            GetApplicationEventTarget(),
            0,
            &voiceHotkeyRef
        )
        if voiceResult != noErr {
            print("[HotkeyManager] Failed to register Ctrl+V: \(voiceResult)")
        }

        // Ctrl+Shift+V → video toggle
        var videoKeyID = EventHotKeyID(
            signature: HotkeyManager.hotkeySignature,
            id: HotkeyManager.videoHotkeyID
        )
        let videoResult = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | shiftKey),
            videoKeyID,
            GetApplicationEventTarget(),
            0,
            &videoHotkeyRef
        )
        if videoResult != noErr {
            print("[HotkeyManager] Failed to register Ctrl+Shift+V: \(videoResult)")
        }

        print("[HotkeyManager] Global hotkeys registered: Ctrl+V (voice), Ctrl+Shift+V (video)")
    }

    /// Unregister all hotkeys.
    func unregisterAll() {
        if let ref = voiceHotkeyRef {
            UnregisterEventHotKey(ref)
            voiceHotkeyRef = nil
        }
        if let ref = videoHotkeyRef {
            UnregisterEventHotKey(ref)
            videoHotkeyRef = nil
        }
        print("[HotkeyManager] Hotkeys unregistered")
    }

    // MARK: - Carbon Event Handler

    private static func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event = event else { return OSStatus(eventNotHandledErr) }

        var hotkeyID = EventHotKeyID()
        let err = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotkeyID
        )

        guard err == noErr else { return err }

        switch hotkeyID.id {
        case voiceHotkeyID:
            DispatchQueue.main.async {
                shared?.onVoiceToggle?()
            }
            return noErr
        case videoHotkeyID:
            DispatchQueue.main.async {
                shared?.onVideoToggle?()
            }
            return noErr
        default:
            return OSStatus(eventNotHandledErr)
        }
    }
}
