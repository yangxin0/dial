import AppKit
import ApplicationServices

/// What the dial does to the app in front: scroll it, jump to the top or
/// bottom, close its window, type into it. All through CGEvents, which
/// need the Accessibility permission.
enum Input {
    /// Whether this app may post events; with `prompt`, macOS asks.
    static func trusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// The centre of the frontmost app's frontmost window, in screen
    /// coordinates with the origin at the top left, where a scroll is
    /// delivered.
    static func frontmostWindowCenter() -> CGPoint? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for window in list {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.width > 50, bounds.height > 50
            else { continue }
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        return nil
    }

    /// Scrolls the app in front by `lines`: up when positive.
    static func scroll(lines: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                  wheel1: lines, wheel2: 0, wheel3: 0) else { return }
        if let center = frontmostWindowCenter() {
            event.location = center
        }
        event.post(tap: .cghidEventTap)
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static let keyHome: CGKeyCode = 115
    static let keyEnd: CGKeyCode = 119
    static let keyW: CGKeyCode = 13

    static func pageTop() { key(keyHome) }
    static func pageBottom() { key(keyEnd) }
    static func closeWindow() { key(keyW, flags: .maskCommand) }

    /// Types text into the app in front, as Unicode, twenty characters an
    /// event (the most a keyboard event carries).
    static func type(_ text: String) {
        let units = Array(text.utf16)
        var at = 0
        while at < units.count {
            var end = min(at + 20, units.count)
            // Don't split a surrogate pair.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[at..<end])
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            at = end
            usleep(4000)
        }
    }
}
