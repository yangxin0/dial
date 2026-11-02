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

    /// The frontmost app's frontmost window: its number, its centre in
    /// screen coordinates with the origin at the top left, and its name.
    struct FrontWindow {
        var id: CGWindowID
        var center: CGPoint
        var bounds: CGRect
        var name: String
    }

    static func frontWindow() -> FrontWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for window in list {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.width > 50, bounds.height > 50
            else { continue }
            let name = window[kCGWindowName as String] as? String ?? ""
            return FrontWindow(id: number, center: CGPoint(x: bounds.midX, y: bounds.midY), bounds: bounds, name: name)
        }
        return nil
    }

    static func frontmostWindowCenter() -> CGPoint? { frontWindow()?.center }

    /// Marks the dial's own events, so one that comes back to the dial is
    /// known and dropped.
    static let scrollTag: Int64 = 0xD1A1

    /// The dial's own frame, in screen coordinates with the origin at the
    /// top left, so a scroll is never aimed at the dial itself.
    static var dialFrame = CGRect.zero

    /// The current cursor position, origin at the top left.
    static var cursor: CGPoint {
        let m = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: m.x, y: height - m.y)
    }

    /// Scrolls the app in front by `lines`: up when positive.
    ///
    /// A wheel event posted to a process is never delivered to a view, and
    /// one posted into the system goes to the window at its location, and
    /// moves the cursor there. So the wheel goes into the system aimed at
    /// the window in front, and a mouse move back to where the cursor was
    /// follows it in the same queue: the window scrolls, the cursor never
    /// visibly leaves the dial. Measured against a test window and Chrome.
    static func scroll(lines: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                  wheel1: lines, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: scrollTag)
        let back = cursor
        guard let window = frontWindow() else {
            event.post(tap: .cghidEventTap)
            Log.write("scroll \(lines) → under the cursor (no window in front)")
            return
        }
        event.location = target(in: window)
        event.post(tap: .cghidEventTap)
        let held = NSEvent.pressedMouseButtons & 1 != 0
        if let move = CGEvent(mouseEventSource: nil, mouseType: held ? .leftMouseDragged : .mouseMoved,
                              mouseCursorPosition: back, mouseButton: .left) {
            move.setIntegerValueField(.eventSourceUserData, value: scrollTag)
            move.post(tap: .cghidEventTap)
        }
        Log.write("scroll \(lines) → «\(window.name)» at \(Int(event.location.x)),\(Int(event.location.y)), cursor back to \(Int(back.x)),\(Int(back.y))")
    }

    /// Where in the window to aim: its centre, unless the dial sits there,
    /// then a point a quarter of the way in from the top left.
    private static func target(in window: FrontWindow) -> CGPoint {
        if !dialFrame.insetBy(dx: -8, dy: -8).contains(window.center) { return window.center }
        let b = window.bounds
        let alternative = CGPoint(x: b.minX + b.width / 4, y: b.minY + b.height / 4)
        return dialFrame.insetBy(dx: -8, dy: -8).contains(alternative)
            ? CGPoint(x: b.maxX - b.width / 4, y: b.maxY - b.height / 4) : alternative
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
