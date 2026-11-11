import AppKit
import ApplicationServices

struct FocusedWindow: Equatable {
    let title: String
    let frame: CGRect
}

struct FocusSnapshot {
    let window: FocusedWindow?
    let element: AXUIElement?
    let role: String?
    let subrole: String?

    var canReadText: Bool {
        window != nil && role == (kAXTextAreaRole as String) && !protected
    }

    var canCaptureWindow: Bool {
        guard let role, window != nil, !protected else { return false }
        return role != (kAXTextFieldRole as String) && role != (kAXComboBoxRole as String) &&
            role != (kAXUnknownRole as String)
    }

    private var protected: Bool {
        if let window, ContentPolicy.isPrivateTitle(window.title) { return true }
        return subrole == (kAXSecureTextFieldSubrole as String) ||
            role?.localizedCaseInsensitiveContains("secure") == true ||
            subrole?.localizedCaseInsensitiveContains("secure") == true
    }
}

enum AccessibilityReader {
    static var permissionName: String {
        if #available(macOS 27.0, *) { return "Device Control and Data Access" }
        return "Accessibility"
    }

    static func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func focus(pid: pid_t) -> FocusSnapshot? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        let title = value(window, kAXTitleAttribute) as? String ?? ""
        let position = value(window, kAXPositionAttribute)
        let size = value(window, kAXSizeAttribute)
        var origin = CGPoint.zero, bounds = CGSize.zero
        let frame: FocusedWindow?
        if let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
           CFGetTypeID(size) == AXValueGetTypeID(),
           AXValueGetValue(position as! AXValue, .cgPoint, &origin),
           AXValueGetValue(size as! AXValue, .cgSize, &bounds), bounds.width > 0, bounds.height > 0 {
            frame = FocusedWindow(title: title, frame: CGRect(origin: origin, size: bounds))
        } else {
            frame = nil
        }
        let field = element(app, kAXFocusedUIElementAttribute)
        return FocusSnapshot(window: frame, element: field,
                             role: field.flatMap { value($0, kAXRoleAttribute) as? String },
                             subrole: field.flatMap { value($0, kAXSubroleAttribute) as? String })
    }

    static func readText(_ focus: FocusSnapshot) -> String? {
        guard focus.canReadText, let element = focus.element else { return nil }
        let length = value(element, kAXNumberOfCharactersAttribute) as? Int
        if let length, !(0...32_768).contains(length) { return nil }
        if let raw = value(element, kAXValueAttribute),
           let text = (raw as? String) ?? (raw as? NSAttributedString)?.string {
            return text.utf16.count <= 32_768 ? text : nil
        }
        // A valid text area may expose its contents only through a range query.
        guard let length else { return nil }
        if length == 0 { return "" }
        var range = CFRange(location: 0, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result
        ) == .success, let text = result as? String, text.utf16.count <= 32_768 else { return nil }
        return text
    }

    private static func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let item = value(element, key), CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
        return (item as! AXUIElement)
    }

    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
}
