import AppKit
import ApplicationServices

protocol DictationTextTarget: AnyObject {
    func insert(_ text: String) throws
}

/// No clipboard, keystroke, or Return injection: only replace an editable AX selection.
final class AccessibilityDictationTarget: DictationTextTarget {
    private let element: AXUIElement
    private let pid: pid_t
    private var baselineValue: String
    private var baselineSelection: CFTypeRef

    static func requestPermission() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    static func capture() throws -> DictationTextTarget {
        guard AXIsProcessTrusted() else {
            throw DictationError.message("Allow Astation in System Settings > Privacy & Security > Accessibility to type dictation.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let focused = focusedElement(app.processIdentifier),
              [kAXTextFieldRole, kAXTextAreaRole].contains(string(focused, kAXRoleAttribute) ?? ""),
              string(focused, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              !protected(focused), let value = string(focused, kAXValueAttribute),
              let selection = attribute(focused, kAXSelectedTextRangeAttribute) else {
            throw DictationError.message("Focus an editable, non-password text field before starting dictation.")
        }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue else {
            throw DictationError.message("This field does not support safe Accessibility text insertion. Use captions or Atem instead.")
        }
        return AccessibilityDictationTarget(element: focused, pid: app.processIdentifier, value: value, selection: selection)
    }
    private init(element: AXUIElement, pid: pid_t, value: String, selection: CFTypeRef) {
        self.element = element; self.pid = pid; baselineValue = value; baselineSelection = selection
    }
    func insert(_ text: String) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = Self.focusedElement(pid), CFEqual(focused, element),
              !Self.protected(element), Self.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              Self.string(element, kAXValueAttribute) == baselineValue,
              let selection = Self.attribute(element, kAXSelectedTextRangeAttribute), CFEqual(selection, baselineSelection) else {
            throw DictationError.message("The text field, its contents, or cursor changed while dictation was processing. Result is kept in captions; nothing was typed.")
        }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            throw DictationError.message("The active field rejected text insertion. Result is available in captions.")
        }
        baselineValue = Self.string(element, kAXValueAttribute) ?? baselineValue
        baselineSelection = Self.attribute(element, kAXSelectedTextRangeAttribute) ?? baselineSelection
    }
    private static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    private static func protected(_ element: AXUIElement) -> Bool { (attribute(element, "AXProtectedContent") as? Bool) == true }
}
