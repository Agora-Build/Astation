import Cocoa
import Carbon.HIToolbox
import XCTest
@testable import Menubar

private final class MediaMenuTarget: NSObject {
    @objc func startScreenShare() {}
    @objc func stopScreenShare() {}
}

@MainActor
final class StatusBarMediaMenuTests: XCTestCase {
    private let target = MediaMenuTarget()

    private func screenItem(connected: Bool, sharing: Bool = false, starting: Bool = false,
                            shortcut: String? = "Ctrl+Shift+V") -> NSMenuItem {
        StatusBarMediaMenu.screenShareItem(shortcut: shortcut, isInChannel: connected,
            isSharing: sharing, isStarting: starting, target: target,
            startAction: #selector(MediaMenuTarget.startScreenShare), stopAction: #selector(MediaMenuTarget.stopScreenShare))
    }

    func testScreenSharingIsNamedExplicitlyAndRequiresAChannelToStart() {
        let item = screenItem(connected: false)
        XCTAssertEqual(item.title, "Start Screen Share (Ctrl+Shift+V)...")
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.action, #selector(MediaMenuTarget.startScreenShare))
        XCTAssertTrue(item.target === target)
        XCTAssertTrue(item.toolTip?.contains("Join an RTC channel") == true)
        XCTAssertTrue(item.toolTip?.contains("does not use the camera") == true)
    }

    func testJoinedChannelUsesTheExistingDisplayPickerAction() {
        let item = screenItem(connected: true)
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.action, #selector(MediaMenuTarget.startScreenShare))
        XCTAssertTrue(item.toolTip?.contains("Choose a display or region") == true)
        XCTAssertTrue(item.toolTip?.contains("primary display") == true)
    }

    func testActiveShareUsesOneStopControlEvenIfTheChannelDisconnects() {
        for connected in [false, true] {
            let item = screenItem(connected: connected, sharing: true)
            XCTAssertEqual(item.title, "Stop Screen Share (Ctrl+Shift+V)")
            XCTAssertTrue(item.isEnabled)
            XCTAssertEqual(item.action, #selector(MediaMenuTarget.stopScreenShare))
        }
    }

    func testPendingShareCanBeCancelledRatherThanStartedAgain() {
        for connected in [false, true] {
            let item = screenItem(connected: connected, starting: true)
            XCTAssertEqual(item.title, "Cancel Screen Share (Ctrl+Shift+V): Starting...")
            XCTAssertTrue(item.isEnabled)
            XCTAssertEqual(item.action, #selector(MediaMenuTarget.stopScreenShare))
        }
    }

    func testClearedAndCustomShortcutsKeepTheScreenShareMenuUsable() {
        XCTAssertEqual(screenItem(connected: true, shortcut: nil).title, "Start Screen Share...")
        XCTAssertTrue(screenItem(connected: true, shortcut: nil).isEnabled)
        XCTAssertEqual(screenItem(connected: true, shortcut: "Ctrl+Option+B").title, "Start Screen Share (Ctrl+Option+B)...")
        XCTAssertEqual(ShortcutAction.video.title, "Toggle RTC Screen Sharing")
        XCTAssertTrue(ShortcutAction.video.detail.contains("Does not use the camera"))
        XCTAssertEqual(ShortcutBindings.defaults.video,
                       KeyboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey)))
    }

    func testMenuUpdatePreservesExplicitDisconnectedAvailability() {
        _ = NSApplication.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = screenItem(connected: false)
        menu.addItem(item)
        menu.update()
        XCTAssertFalse(item.isEnabled)
    }

    func testReadyDictationIsAnExplicitHoldAndReleaseHintNotAnOffState() {
        let item = StatusBarMediaMenu.dictationHint(shortcut: "Ctrl+V", unavailableReason: nil)
        XCTAssertEqual(item.title, "Hold Ctrl+V to Dictate")
        XCTAssertFalse(item.isEnabled)
        XCTAssertNil(item.action)
        XCTAssertTrue(item.toolTip?.contains("release it to finish") == true)
        XCTAssertTrue(item.toolTip?.contains("not a button") == true)
    }

    func testMicrophoneTranscriptionKeepsItsActualDictationDisabledReason() {
        let reason = "Mic transcription is active. Stop it or select system/app audio only to use dictation."
        let item = StatusBarMediaMenu.dictationHint(shortcut: "Ctrl+V", unavailableReason: reason)
        XCTAssertEqual(item.title, "Dictation: Disabled during mic transcription")
        XCTAssertEqual(item.toolTip, reason)
    }

    func testUnboundDictationDoesNotTellUsersToHoldANonexistentShortcut() {
        let item = StatusBarMediaMenu.dictationHint(shortcut: nil, unavailableReason: nil)
        XCTAssertEqual(item.title, "Push-to-Talk Dictation: Set a Shortcut")
        XCTAssertTrue(item.toolTip?.contains("Keyboard Shortcuts") == true)
    }
}
