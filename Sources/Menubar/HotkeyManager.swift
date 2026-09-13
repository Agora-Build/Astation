import Cocoa
import Carbon.HIToolbox

protocol HotkeyRegistering: AnyObject {
    var onEvent: ((UInt32, Bool) -> Void)? { get set }
    func start() -> OSStatus
    func register(_ shortcut: KeyboardShortcut, id: UInt32) -> OSStatus
    func unregister(id: UInt32)
    func stop()
}

private final class CarbonHotkeyRegistrar: HotkeyRegistering {
    var onEvent: ((UInt32, Bool) -> Void)?
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private static let signature = OSType(0x4153544E) // "ASTN"

    func start() -> OSStatus {
        guard handler == nil else { return noErr }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        return InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(
                    event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                )
                guard result == noErr else { return result }
                guard identifier.signature == CarbonHotkeyRegistrar.signature else { return OSStatus(eventNotHandledErr) }
                let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(context).takeUnretainedValue()
                guard registrar.references[identifier.id] != nil else { return OSStatus(eventNotHandledErr) }
                let id = identifier.id
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                registrar.onEvent?(id, pressed)
                return noErr
            },
            types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
    }

    func register(_ shortcut: KeyboardShortcut, id: UInt32) -> OSStatus {
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference
        )
        if result == noErr { references[id] = reference }
        return result
    }

    func unregister(id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
    }

    func stop() {
        for id in Array(references.keys) { unregister(id: id) }
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { stop() }
}

/// Owns persisted bindings and active registrations. All access is on the main thread.
final class HotkeyManager {
    static let defaultsKey = "AstationKeyboardShortcuts.v1"

    var onVoiceKeyDown: (() -> Void)?
    var onVoiceKeyUp: (() -> Void)?
    var onVideoToggle: (() -> Void)?
    var additionalMenus: (() -> [NSMenu])?

    private(set) var bindings: ShortcutBindings
    private(set) var registrationErrors: [ShortcutAction: String] = [:]
    private(set) var isSuspended = false
    var voiceHotkeyFailed: Bool { registrationErrors[.voice] != nil }
    var videoHotkeyFailed: Bool { registrationErrors[.video] != nil }

    private struct Registration {
        let id: UInt32
        let shortcut: KeyboardShortcut
    }

    private let defaults: UserDefaults
    private let registrar: HotkeyRegistering
    private let systemConflict: (KeyboardShortcut) -> String?
    private var registrations: [ShortcutAction: Registration] = [:]
    private var nextID: UInt32 = 0
    private var pressedActions: Set<ShortcutAction> = []

    init(defaults: UserDefaults = .standard, registrar: HotkeyRegistering? = nil,
         systemConflict: @escaping (KeyboardShortcut) -> String? = ShortcutConflictChecker.systemConflict) {
        self.defaults = defaults
        self.registrar = registrar ?? CarbonHotkeyRegistrar()
        self.systemConflict = systemConflict
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(ShortcutBindings.self, from: data),
           ShortcutAction.allCases.allSatisfy({ saved[$0]?.validationError == nil }),
           saved.voice == nil || saved.voice != saved.video {
            bindings = saved
        } else {
            bindings = .defaults
        }
        self.registrar.onEvent = { [weak self] id, pressed in self?.handleEvent(id: id, pressed: pressed) }
    }

    deinit { registrar.stop() }

    func shortcutLabel(for action: ShortcutAction) -> String {
        bindings[action]?.displayName ?? "Not Bound"
    }

    /// Retry unavailable keys too, so users can recheck after freeing a shortcut in another app.
    func registerHotkeys() {
        guard !isSuspended else { return }
        let startResult = registrar.start()
        for action in ShortcutAction.allCases {
            guard let shortcut = bindings[action], registrations[action] == nil else { continue }
            if let error = conflict(for: shortcut) {
                registrationErrors[action] = error
                continue
            }
            let id = makeID()
            let result = startResult == noErr ? registrar.register(shortcut, id: id) : startResult
            if result == noErr {
                registrations[action] = Registration(id: id, shortcut: shortcut)
                registrationErrors[action] = nil
            } else {
                registrationErrors[action] = registrationFailure(shortcut, status: result)
                Log.warn("[HotkeyManager] \(action.title): \(registrationErrors[action]!)")
            }
        }
    }

    @discardableResult
    func setShortcut(_ shortcut: KeyboardShortcut?, for action: ShortcutAction) -> String? {
        var proposed = bindings
        proposed[action] = shortcut
        return apply(proposed, updating: [action])
    }

    @discardableResult
    func restoreDefaults() -> String? { apply(.defaults, updating: Set(ShortcutAction.allCases)) }

    private func apply(_ proposed: ShortcutBindings, updating actions: Set<ShortcutAction>) -> String? {
        guard !isSuspended else { return "Finish recording before changing shortcuts." }
        if let voice = proposed.voice, voice == proposed.video {
            return "\(voice.displayName) is already assigned to another Astation action. Each action needs a different shortcut."
        }
        for action in ShortcutAction.allCases where actions.contains(action) {
            if let shortcut = proposed[action], let error = conflict(for: shortcut) { return error }
        }
        if actions.contains(where: { proposed[$0] != nil }) {
            let startResult = registrar.start()
            guard startResult == noErr else { return "Could not start keyboard shortcuts (error \(startResult)). Try again." }
        }

        // Acquire all new keys before releasing old ones. Reuse registrations when swapping defaults.
        var prepared = registrations.filter { !actions.contains($0.key) }
        var acquired: [UInt32] = []
        for action in ShortcutAction.allCases where actions.contains(action) {
            guard let shortcut = proposed[action] else { continue }
            if let existing = registrations.values.first(where: { $0.shortcut == shortcut }) {
                prepared[action] = existing
                continue
            }
            let id = makeID()
            let result = registrar.register(shortcut, id: id)
            guard result == noErr else {
                for id in acquired { registrar.unregister(id: id) }
                return registrationFailure(shortcut, status: result)
            }
            acquired.append(id)
            prepared[action] = Registration(id: id, shortcut: shortcut)
        }

        for action in ShortcutAction.allCases where proposed[action] != bindings[action] { release(action) }
        let retainedIDs = Set(prepared.values.map(\.id))
        for old in registrations.values where !retainedIDs.contains(old.id) { registrar.unregister(id: old.id) }
        registrations = prepared
        bindings = proposed
        for action in actions { registrationErrors[action] = nil }
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.defaultsKey) }
        return nil
    }

    func suspendForRecording() {
        guard !isSuspended else { return }
        isSuspended = true
        clearRegistrations()
    }

    func resumeAfterRecording() {
        guard isSuspended else { return }
        isSuspended = false
        registerHotkeys()
    }

    func unregisterAll() {
        clearRegistrations()
        registrar.stop()
    }

    private func clearRegistrations() {
        for action in ShortcutAction.allCases { release(action) }
        for registration in registrations.values { registrar.unregister(id: registration.id) }
        registrations.removeAll()
    }

    private func release(_ action: ShortcutAction) {
        if pressedActions.remove(action) != nil, action == .voice { onVoiceKeyUp?() }
    }

    private func handleEvent(id: UInt32, pressed: Bool) {
        guard !isSuspended, let action = registrations.first(where: { $0.value.id == id })?.key else { return }
        if pressed {
            guard pressedActions.insert(action).inserted else { return }
            if action == .voice { onVoiceKeyDown?() } else { onVideoToggle?() }
        } else {
            release(action)
        }
    }

    private func makeID() -> UInt32 {
        nextID += 1
        return nextID
    }

    private func conflict(for shortcut: KeyboardShortcut) -> String? {
        if let error = shortcut.validationError { return error }
        if let error = systemConflict(shortcut) { return error }
        var menus = additionalMenus?() ?? []
        if let mainMenu = NSApp?.mainMenu { menus.append(mainMenu) }
        for menu in menus {
            if let error = ShortcutConflictChecker.menuConflict(for: shortcut, in: menu) { return error }
        }
        return nil
    }

    private func registrationFailure(_ shortcut: KeyboardShortcut, status: OSStatus) -> String {
        "\(shortcut.displayName) is unavailable or registered by another app (error \(status)). Choose another combination."
    }
}
