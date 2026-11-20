import AppKit

struct Destination {
    let pid: pid_t
    let field: AXUIElement?
    static func focus(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        let application = AXUIElementCreateApplication(pid)
        // Electron/Chromium apps expose their text fields only after this flag is set.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    init?() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        pid = app.processIdentifier
        field = Self.focus(pid)
    }
    var acceptsDictation: Bool {
        guard let field, pid != ProcessInfo.processInfo.processIdentifier else { return false }
        func attribute(_ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(field, key as CFString, &value)
            return value
        }
        guard attribute(kAXSubroleAttribute) as? String != "AXSecureTextField",
              (attribute(kAXEnabledAttribute) as? Bool) != false,
              (attribute("AXEditable") as? Bool) != false else { return false }
        let role = attribute(kAXRoleAttribute) as? String ?? ""
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) { return true }
        var writable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &writable)
        return writable.boolValue || attribute("AXEditable") as? Bool == true
    }

    func containsClick(_ point: CGPoint) -> Bool {
        guard let field else { return false }
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(field, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return false }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        return AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            && AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
            && CGRect(origin: origin, size: dimensions).contains(point)
    }

    var current: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        if let field { return Self.focus(pid).map { CFEqual(field, $0) } ?? false }
        return true
    }
    @MainActor func type(_ text: String) async -> Bool {
        guard current, AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .privateState)
        var chunks = [[UInt16]]()
        var units = [UInt16]()
        for scalar in text.unicodeScalars {
            if units.count + scalar.utf16.count > 16 { chunks.append(units); units = [] }
            units.append(contentsOf: scalar.utf16)
        }
        if !units.isEmpty { chunks.append(units) }
        for chunk in chunks {
            guard current, let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.flags = []; up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
            down.postToPid(pid); up.postToPid(pid)
            if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "ru.oneme.desktop" {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        return true
    }
}
