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

    // MARK: - Scrolling
    //
    // A wheel goes straight to the front app's process, so the pointer is
    // not involved at all. AppKit and Chromium only deliver such an event
    // when it carries the window's number in field 51 and a window-local
    // position, set with the private CGEventSetWindowLocation. See CLAUDE.md.

    private struct FrontWindow {
        var pid: pid_t
        var id: CGWindowID
        var bounds: CGRect
    }

    /// The front app's frontmost ordinary window.
    private static func frontWindow() -> FrontWindow? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in list {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.width > 50, bounds.height > 50
            else { continue }
            return FrontWindow(pid: pid, id: id, bounds: bounds)
        }
        return nil
    }

    private static let windowNumberField = CGEventField(rawValue: 51)!

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        let anyImage = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return dlsym(anyImage, "CGEventSetWindowLocation").map { unsafeBitCast($0, to: SetWindowLocation.self) }
    }()

    /// Scrolls the app in front by `lines`, at the middle of its window: up
    /// when positive.
    static func scroll(lines: Int32) {
        guard let setWindowLocation else {
            Log.write("scroll: this macOS has no CGEventSetWindowLocation")
            return
        }
        guard let window = frontWindow(),
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                  wheel1: lines, wheel2: 0, wheel3: 0) else {
            Log.write("scroll: no window in front")
            return
        }
        event.location = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        setWindowLocation(event, CGPoint(x: window.bounds.width / 2, y: window.bounds.height / 2))
        event.setIntegerValueField(windowNumberField, value: Int64(window.id))
        event.postToPid(window.pid)
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
