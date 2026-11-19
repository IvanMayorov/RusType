import AppKit

struct Destination {
    let pid: pid_t
    let field: AXUIElement?
    static func focus(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    init?() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        pid = app.processIdentifier
        field = Self.focus(pid)
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
