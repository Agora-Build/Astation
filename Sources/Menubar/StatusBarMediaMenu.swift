import Cocoa

enum StatusBarMediaMenu {
    static func screenShareItem(shortcut: String?, isInChannel: Bool, isSharing: Bool, isStarting: Bool,
                                target: AnyObject, startAction: Selector, stopAction: Selector) -> NSMenuItem {
        let canStop = isSharing || isStarting
        let title = isSharing ? "Stop Screen Share" : isStarting ? "Cancel Screen Share" : "Start Screen Share"
        let shortcutSuffix = shortcut.map { " (\($0))" } ?? ""
        let stateSuffix = isSharing ? "" : isStarting ? ": Starting..." : "..."
        let item = NSMenuItem(title: "\(title)\(shortcutSuffix)\(stateSuffix)",
                              action: canStop ? stopAction : startAction, keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: isSharing ? "rectangle.inset.filled.and.person.filled" : "rectangle.on.rectangle",
                             accessibilityDescription: "Screen Share")
        item.isEnabled = isInChannel || canStop
        item.toolTip = canStop ? "Stop RTC screen sharing. Microphone publishing and local audio features are unchanged."
            : isInChannel ? "Choose a display or region to share over RTC. The shortcut toggles the primary display; it does not use the camera."
            : "Join an RTC channel to share your screen. This control does not use the camera."
        return item
    }

    static func dictationHint(shortcut: String?, unavailableReason: String?) -> NSMenuItem {
        let readyTitle = shortcut.map { "Hold \($0) to Dictate" } ?? "Push-to-Talk Dictation: Set a Shortcut"
        let item = NSMenuItem(title: unavailableReason == nil ? readyTitle : "Dictation: Disabled during mic transcription",
                              action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: unavailableReason == nil ? "mic" : "mic.slash",
                             accessibilityDescription: "Push-to-Talk Dictation")
        item.isEnabled = false
        item.toolTip = unavailableReason ?? (shortcut == nil ? "Set a Push-to-Talk Dictation shortcut in Settings > Keyboard Shortcuts."
            : "Hold the shortcut to speak into the local microphone; release it to finish. This row is a shortcut hint, not a button.")
        return item
    }
}
