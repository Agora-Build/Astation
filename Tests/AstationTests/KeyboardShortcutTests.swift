import Cocoa
import Carbon.HIToolbox
import XCTest
@testable import Menubar

private final class FakeHotkeyRegistrar: HotkeyRegistering {
    var onEvent: ((UInt32, Bool) -> Void)?
    var active: [UInt32: KeyboardShortcut] = [:]
    var unavailable: Set<KeyboardShortcut> = []
    var startResult: OSStatus = noErr
    var attempts = 0

    func start() -> OSStatus { startResult }
    func register(_ shortcut: KeyboardShortcut, id: UInt32) -> OSStatus {
        attempts += 1
        if unavailable.contains(shortcut) || active.values.contains(shortcut) { return OSStatus(eventHotKeyExistsErr) }
        active[id] = shortcut
        return noErr
    }
    func unregister(id: UInt32) { active[id] = nil }
    func stop() { active.removeAll() }
    func id(for shortcut: KeyboardShortcut) -> UInt32 { active.first { $0.value == shortcut }!.key }
}

@MainActor
final class KeyboardShortcutTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "keyboard-shortcuts-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func manager(_ registrar: FakeHotkeyRegistrar, defaults: UserDefaults? = nil,
                         conflict: @escaping (KeyboardShortcut) -> String? = { _ in nil }) -> HotkeyManager {
        HotkeyManager(defaults: defaults ?? self.defaults(), registrar: registrar, systemConflict: conflict)
    }

    private let customVoice = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey))
    private let customVideo = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey))

    func testBindingValidationAndModifierNormalization() throws {
        XCTAssertNotNil(KeyboardShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0).validationError)
        XCTAssertNotNil(KeyboardShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)).validationError)
        XCTAssertNotNil(KeyboardShortcut(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey)).validationError)
        XCTAssertNotNil(KeyboardShortcut(keyCode: 999, modifiers: UInt32(cmdKey)).validationError)
        XCTAssertNotNil(KeyboardShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(alphaLock)).validationError)
        XCTAssertNil(KeyboardShortcut(keyCode: UInt32(kVK_F6), modifiers: 0).validationError)
        XCTAssertNil(KeyboardShortcut(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey)).validationError)
        XCTAssertNil(customVoice.validationError)
        let event = try event(.keyDown, key: UInt16(kVK_ANSI_A), flags: [.control, .option, .capsLock, .numericPad])
        XCTAssertEqual(KeyboardShortcut(event: event), customVoice)
        XCTAssertEqual(KeyboardShortcut(keyCode: UInt32(kVK_F6), modifiers: UInt32(controlKey | shiftKey)).displayName, "Ctrl+Shift+F6")
    }

    func testCustomAndClearedBindingsSurviveRelaunch() {
        let storage = defaults()
        let registrar = FakeHotkeyRegistrar()
        let first = manager(registrar, defaults: storage)
        first.registerHotkeys()
        XCTAssertEqual(first.bindings, .defaults)
        XCTAssertNil(first.setShortcut(customVoice, for: .voice))
        XCTAssertNil(first.setShortcut(nil, for: .video))
        first.unregisterAll()

        let second = manager(FakeHotkeyRegistrar(), defaults: storage)
        XCTAssertEqual(second.bindings.voice, customVoice)
        XCTAssertNil(second.bindings.video)
        XCTAssertEqual(second.shortcutLabel(for: .video), "Not Bound")
    }

    func testMalformedAndInvalidSavedBindingsFallBackToDefaults() throws {
        let storage = defaults()
        storage.set(Data("broken".utf8), forKey: HotkeyManager.defaultsKey)
        XCTAssertEqual(manager(FakeHotkeyRegistrar(), defaults: storage).bindings, .defaults)
        let duplicate = ShortcutBindings(voice: customVoice, video: customVoice)
        storage.set(try JSONEncoder().encode(duplicate), forKey: HotkeyManager.defaultsKey)
        XCTAssertEqual(manager(FakeHotkeyRegistrar(), defaults: storage).bindings, .defaults)
        let invalid = ShortcutBindings(voice: KeyboardShortcut(keyCode: 900, modifiers: 0), video: nil)
        storage.set(try JSONEncoder().encode(invalid), forKey: HotkeyManager.defaultsKey)
        XCTAssertEqual(manager(FakeHotkeyRegistrar(), defaults: storage).bindings, .defaults)
    }

    func testDuplicateDoesNotAlterWorkingOrSavedBindings() {
        let storage = defaults()
        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar, defaults: storage)
        manager.registerHotkeys()
        let old = registrar.active
        let error = manager.setShortcut(manager.bindings.video, for: .voice)
        XCTAssertTrue(error?.contains("already assigned") == true)
        XCTAssertEqual(manager.bindings, .defaults)
        XCTAssertEqual(registrar.active, old)
        XCTAssertNil(storage.data(forKey: HotkeyManager.defaultsKey))
    }

    func testExternalRegistrationConflictPreservesOldShortcut() {
        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar)
        manager.registerHotkeys()
        let old = registrar.active
        registrar.unavailable.insert(customVoice)
        XCTAssertNotNil(manager.setShortcut(customVoice, for: .voice))
        XCTAssertEqual(manager.bindings, .defaults)
        XCTAssertEqual(registrar.active, old)
        XCTAssertFalse(manager.voiceHotkeyFailed)
    }

    func testSystemConflictIsRejectedBeforeRegistration() {
        let registrar = FakeHotkeyRegistrar()
        let reserved = customVoice
        let manager = manager(registrar, conflict: { $0 == reserved ? "Reserved by macOS" : nil })
        manager.registerHotkeys()
        let attempts = registrar.attempts
        XCTAssertEqual(manager.setShortcut(customVoice, for: .voice), "Reserved by macOS")
        XCTAssertEqual(registrar.attempts, attempts)
        XCTAssertEqual(manager.bindings, .defaults)
    }

    func testAppMenuConflictsIncludeShiftedAndNestedCommands() {
        let menu = NSMenu()
        let parent = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Redo", action: nil, keyEquivalent: "Z")
        parent.submenu = submenu
        menu.addItem(parent)
        let redo = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | shiftKey))
        XCTAssertTrue(ShortcutConflictChecker.menuConflict(for: redo, in: menu)?.contains("Redo") == true)
        XCTAssertNil(ShortcutConflictChecker.menuConflict(for: customVoice, in: menu))

        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar)
        manager.additionalMenus = { [menu] }
        XCTAssertNotNil(manager.setShortcut(redo, for: .voice))
        XCTAssertEqual(registrar.attempts, 0)
    }

    func testSystemConflictChecksOnlyEnabledMatchingCombinations() {
        var entry: [String: Any] = [
            kHISymbolicHotKeyCode: NSNumber(value: customVoice.keyCode),
            kHISymbolicHotKeyModifiers: NSNumber(value: customVoice.modifiers),
            kHISymbolicHotKeyEnabled: NSNumber(value: true)
        ]
        XCTAssertNotNil(ShortcutConflictChecker.systemConflict(for: customVoice, entries: [entry]))
        XCTAssertNil(ShortcutConflictChecker.systemConflict(for: customVideo, entries: [entry]))
        entry[kHISymbolicHotKeyEnabled] = NSNumber(value: false)
        XCTAssertNil(ShortcutConflictChecker.systemConflict(for: customVoice, entries: [entry]))
        XCTAssertNil(ShortcutConflictChecker.systemConflict(for: customVoice, entries: [[:]]))
    }

    func testReadsMacOSSymbolicShortcuts() throws {
        var unmanaged: Unmanaged<CFArray>?
        XCTAssertEqual(CopySymbolicHotKeys(&unmanaged), noErr)
        let array = try XCTUnwrap(unmanaged?.takeRetainedValue())
        let entries = try XCTUnwrap(array as? [[String: Any]])
        guard let entry = entries.first(where: { ($0[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true }),
              let code = entry[kHISymbolicHotKeyCode] as? NSNumber,
              let flags = entry[kHISymbolicHotKeyModifiers] as? NSNumber else {
            throw XCTSkip("This Mac has no enabled symbolic keyboard shortcuts.")
        }
        let shortcut = KeyboardShortcut(keyCode: code.uint32Value,
                                        modifiers: flags.uint32Value & KeyboardShortcut.supportedModifiers)
        XCTAssertTrue(ShortcutConflictChecker.systemConflict(for: shortcut)?.contains("used by macOS") == true)
    }

    func testRestoreDefaultsRollsBackAllNewRegistrationsOnFailure() {
        let storage = defaults()
        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar, defaults: storage)
        manager.registerHotkeys()
        XCTAssertNil(manager.setShortcut(customVoice, for: .voice))
        XCTAssertNil(manager.setShortcut(customVideo, for: .video))
        let old = registrar.active
        let saved = storage.data(forKey: HotkeyManager.defaultsKey)
        registrar.unavailable.insert(ShortcutBindings.defaults.video!)
        XCTAssertNotNil(manager.restoreDefaults())
        XCTAssertEqual(registrar.active, old)
        XCTAssertEqual(storage.data(forKey: HotkeyManager.defaultsKey), saved)
        registrar.unavailable.removeAll()
        XCTAssertNil(manager.restoreDefaults())
        XCTAssertEqual(manager.bindings, .defaults)
        XCTAssertEqual(Set(registrar.active.values), [ShortcutBindings.defaults.voice!, ShortcutBindings.defaults.video!])
    }

    func testRestoreDefaultsCanSwapOwnedKeysWithoutSelfConflict() throws {
        let storage = defaults()
        let swapped = ShortcutBindings(voice: ShortcutBindings.defaults.video, video: ShortcutBindings.defaults.voice)
        storage.set(try JSONEncoder().encode(swapped), forKey: HotkeyManager.defaultsKey)
        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar, defaults: storage)
        manager.registerHotkeys()
        let attempts = registrar.attempts
        XCTAssertNil(manager.restoreDefaults())
        XCTAssertEqual(manager.bindings, .defaults)
        XCTAssertEqual(registrar.attempts, attempts)
        var voiceDown = 0
        var videoDown = 0
        manager.onVoiceKeyDown = { voiceDown += 1 }
        manager.onVideoToggle = { videoDown += 1 }
        registrar.onEvent?(registrar.id(for: ShortcutBindings.defaults.voice!), true)
        registrar.onEvent?(registrar.id(for: ShortcutBindings.defaults.video!), true)
        XCTAssertEqual(voiceDown, 1)
        XCTAssertEqual(videoDown, 1)
    }

    func testUnavailableShortcutCanBeRetriedAndDoesNotBlockEditingOtherAction() {
        let registrar = FakeHotkeyRegistrar()
        registrar.unavailable.insert(ShortcutBindings.defaults.video!)
        let manager = manager(registrar)
        manager.registerHotkeys()
        XCTAssertTrue(manager.videoHotkeyFailed)
        XCTAssertNil(manager.setShortcut(customVoice, for: .voice))
        XCTAssertTrue(manager.videoHotkeyFailed)
        XCTAssertEqual(registrar.active.count, 1)
        registrar.unavailable.removeAll()
        manager.registerHotkeys()
        XCTAssertFalse(manager.videoHotkeyFailed)
        XCTAssertEqual(registrar.active.count, 2)
        let attempts = registrar.attempts
        manager.registerHotkeys()
        XCTAssertEqual(registrar.attempts, attempts)
    }

    func testClearDoesNotDependOnAnotherActionsSystemConflict() {
        let registrar = FakeHotkeyRegistrar()
        var blockVideo = false
        let manager = manager(registrar, conflict: {
            blockVideo && $0 == ShortcutBindings.defaults.video ? "Reserved by macOS" : nil
        })
        manager.registerHotkeys()
        blockVideo = true
        XCTAssertNil(manager.setShortcut(nil, for: .voice))
        XCTAssertNil(manager.bindings.voice)
        XCTAssertEqual(registrar.active.count, 1)
    }

    func testVoiceReleaseRepeatSuppressionAndStaleEvents() {
        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar)
        manager.registerHotkeys()
        let voiceID = registrar.id(for: manager.bindings.voice!)
        let videoID = registrar.id(for: manager.bindings.video!)
        var down = 0
        var up = 0
        var video = 0
        manager.onVoiceKeyDown = { down += 1 }
        manager.onVoiceKeyUp = { up += 1 }
        manager.onVideoToggle = { video += 1 }
        registrar.onEvent?(voiceID, false)
        registrar.onEvent?(voiceID, true)
        registrar.onEvent?(voiceID, true)
        XCTAssertEqual(down, 1)
        XCTAssertEqual(up, 0)
        XCTAssertNil(manager.setShortcut(customVoice, for: .voice))
        XCTAssertEqual(up, 1)
        registrar.onEvent?(voiceID, true)
        registrar.onEvent?(voiceID, false)
        XCTAssertEqual(down, 1)
        XCTAssertEqual(up, 1)
        registrar.onEvent?(videoID, true)
        registrar.onEvent?(videoID, true)
        registrar.onEvent?(videoID, false)
        registrar.onEvent?(videoID, true)
        XCTAssertEqual(video, 2)
    }

    func testRecordingSuspendsAndReleasesVoiceAndResumesOnlyOnce() {
        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar)
        manager.registerHotkeys()
        let id = registrar.id(for: manager.bindings.voice!)
        var up = 0
        manager.onVoiceKeyUp = { up += 1 }
        registrar.onEvent?(id, true)
        manager.suspendForRecording()
        XCTAssertEqual(up, 1)
        XCTAssertTrue(registrar.active.isEmpty)
        XCTAssertNotNil(manager.setShortcut(customVoice, for: .voice))
        manager.registerHotkeys()
        XCTAssertTrue(registrar.active.isEmpty)
        manager.suspendForRecording()
        manager.resumeAfterRecording()
        manager.resumeAfterRecording()
        XCTAssertEqual(registrar.active.count, 2)
        XCTAssertEqual(up, 1)
    }

    func testRecorderWaitsForReleaseAndPersistsWithoutTriggeringAction() throws {
        _ = NSApplication.shared
        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar)
        manager.registerHotkeys()
        var triggered = 0
        manager.onVoiceKeyDown = { triggered += 1 }
        let controller = KeyboardShortcutsViewController(manager: manager)
        _ = controller.view
        controller.beginRecording(.voice)
        controller.capture(try event(.keyDown, key: UInt16(customVoice.keyCode), flags: [.control, .option]))
        XCTAssertTrue(manager.isSuspended)
        XCTAssertEqual(manager.bindings, .defaults)
        controller.capture(try event(.keyUp, key: UInt16(customVoice.keyCode), flags: []))
        XCTAssertFalse(manager.isSuspended)
        XCTAssertNil(controller.recordingAction)
        XCTAssertEqual(manager.bindings.voice, customVoice)
        XCTAssertEqual(triggered, 0)
    }

    func testRecorderCancelInvalidAndDuplicateKeysKeepOriginalBindings() throws {
        _ = NSApplication.shared
        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar)
        manager.registerHotkeys()
        let controller = KeyboardShortcutsViewController(manager: manager)
        _ = controller.view
        controller.beginRecording(.voice)
        controller.capture(try event(.keyDown, key: UInt16(kVK_ANSI_A), flags: []))
        XCTAssertEqual(controller.recordingAction, .voice)
        controller.capture(try event(.keyDown, key: UInt16(kVK_Escape), flags: []))
        XCTAssertNil(controller.recordingAction)
        XCTAssertFalse(manager.isSuspended)
        XCTAssertEqual(registrar.active.count, 2)
        controller.beginRecording(.voice)
        controller.capture(try event(.keyDown, key: UInt16(kVK_ANSI_V), flags: [.control, .shift]))
        controller.capture(try event(.keyUp, key: UInt16(kVK_ANSI_V), flags: []))
        XCTAssertEqual(manager.bindings, .defaults)
        XCTAssertEqual(registrar.active.count, 2)
        controller.beginRecording(.video)
        controller.viewWillDisappear()
        XCTAssertFalse(manager.isSuspended)
        XCTAssertEqual(manager.bindings, .defaults)
    }

    func testHandlerFailureAndShutdownCleanUpRegistrations() {
        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar)
        registrar.startResult = OSStatus(eventInternalErr)
        manager.registerHotkeys()
        XCTAssertTrue(manager.voiceHotkeyFailed)
        XCTAssertTrue(manager.videoHotkeyFailed)
        XCTAssertNotNil(manager.setShortcut(customVoice, for: .voice))
        XCTAssertEqual(manager.bindings, .defaults)
        registrar.startResult = noErr
        manager.registerHotkeys()
        XCTAssertFalse(manager.voiceHotkeyFailed)
        manager.unregisterAll()
        XCTAssertTrue(registrar.active.isEmpty)
    }

    func testCanClearBindingsWhenKeyboardHandlerFails() {
        let registrar = FakeHotkeyRegistrar()
        registrar.startResult = OSStatus(eventInternalErr)
        let manager = manager(registrar)
        manager.registerHotkeys()
        XCTAssertNil(manager.setShortcut(nil, for: .voice))
        XCTAssertNil(manager.setShortcut(nil, for: .video))
        XCTAssertNil(manager.bindings.voice)
        XCTAssertNil(manager.bindings.video)
        XCTAssertTrue(manager.registrationErrors.isEmpty)
    }

    func testLongConflictMessagesHaveAnUnambiguousScrollableLayout() throws {
        _ = NSApplication.shared
        let registrar = FakeHotkeyRegistrar()
        let manager = manager(registrar, conflict: { _ in
            "This shortcut is used by macOS. Change it in System Settings > Keyboard > Keyboard Shortcuts, or choose another combination."
        })
        manager.registerHotkeys()
        let controller = KeyboardShortcutsViewController(manager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 596, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(controller.view as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertFalse(document.hasAmbiguousLayout)
        XCTAssertEqual(document.frame.width, scroll.contentSize.width, accuracy: 1)
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
        document.scroll(NSPoint(x: 0, y: 100))
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
    }

    private func event(_ type: NSEvent.EventType, key: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
    }
}
