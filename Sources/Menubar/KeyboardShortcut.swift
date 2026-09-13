import Cocoa
import Carbon.HIToolbox

enum ShortcutAction: String, CaseIterable {
    case voice
    case video

    var title: String {
        switch self {
        case .voice: return "Push-to-Talk Voice"
        case .video: return "Toggle Video Sharing"
        }
    }

    var detail: String {
        switch self {
        case .voice: return "Hold to speak. Release to send your voice request."
        case .video: return "Press to start or stop screen sharing."
        }
    }
}

struct KeyboardShortcut: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let supportedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = Self.carbonModifiers(event.modifierFlags)
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    var validationError: String? {
        guard modifiers & ~Self.supportedModifiers == 0, keyName != nil else {
            return "Choose a letter, number, navigation key, or function key."
        }
        guard Self.functionKeys[keyCode] != nil || modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            return "Include Control, Option, or Command, or use an F1-F20 key."
        }
        return nil
    }

    var displayName: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("Ctrl") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Cmd") }
        parts.append(keyName ?? "Unknown Key")
        return parts.joined(separator: "+")
    }

    private static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    private var keyName: String? {
        if let name = Self.functionKeys[keyCode] { return name }
        let specialKeys: [UInt32: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear",
            75: "Keypad /", 76: "Keypad Enter", 78: "Keypad -", 81: "Keypad =",
            82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
            86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
            91: "Keypad 8", 92: "Keypad 9", 95: "Keypad ,", 102: "Eisu", 104: "Kana",
            114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete",
            119: "End", 121: "Page Down", 123: "Left", 124: "Right", 125: "Down", 126: "Up"
        ]
        if let name = specialKeys[keyCode] { return name }
        guard keyCode < 128, ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) else {
            return nil
        }
        return translatedKey()
    }

    // Use the current keyboard layout, including a dead key's printable form.
    func translatedKey(shifted: Bool = false) -> String? {
        guard keyCode < 128,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let result = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay),
            shifted ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
            characters.count, &length, &characters
        )
        guard result == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        guard text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text.uppercased()
    }
}

struct ShortcutBindings: Codable, Equatable {
    var voice: KeyboardShortcut?
    var video: KeyboardShortcut?

    static let defaults = ShortcutBindings(
        voice: KeyboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey)),
        video: KeyboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey))
    )

    subscript(action: ShortcutAction) -> KeyboardShortcut? {
        get { action == .voice ? voice : video }
        set {
            if action == .voice { voice = newValue } else { video = newValue }
        }
    }
}

enum ShortcutConflictChecker {
    static func systemConflict(for shortcut: KeyboardShortcut) -> String? {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() else {
            return "Could not check macOS keyboard shortcuts. Try again."
        }
        guard let entries = array as? [[String: Any]] else {
            return "Could not read macOS keyboard shortcuts. Try again."
        }
        return systemConflict(for: shortcut, entries: entries)
    }

    static func systemConflict(for shortcut: KeyboardShortcut, entries: [[String: Any]]) -> String? {
        for entry in entries {
            guard (entry[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true,
                  let code = entry[kHISymbolicHotKeyCode] as? NSNumber,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? NSNumber else { continue }
            if code.uint32Value == shortcut.keyCode,
               modifiers.uint32Value & KeyboardShortcut.supportedModifiers == shortcut.modifiers {
                return "\(shortcut.displayName) is used by macOS. Change it in System Settings > Keyboard > Keyboard Shortcuts, or choose another combination."
            }
        }
        return nil
    }

    static func menuConflict(for shortcut: KeyboardShortcut, in menu: NSMenu) -> String? {
        for item in menu.items {
            if let submenu = item.submenu, let conflict = menuConflict(for: shortcut, in: submenu) {
                return conflict
            }
            guard !item.keyEquivalent.isEmpty else { continue }
            var modifiers = KeyboardShortcut.carbonModifiers(item.keyEquivalentModifierMask)
            if item.keyEquivalent != item.keyEquivalent.lowercased() { modifiers |= UInt32(shiftKey) }
            let key = shortcut.translatedKey(shifted: shortcut.modifiers & UInt32(shiftKey) != 0)
            if modifiers == shortcut.modifiers, key == item.keyEquivalent.uppercased() {
                return "\(shortcut.displayName) is used by Astation's \(item.title) command. Choose another combination."
            }
        }
        return nil
    }
}
