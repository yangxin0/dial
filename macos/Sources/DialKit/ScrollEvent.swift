import CoreGraphics
import Foundation

/// A mouse wheel posted straight to an app's process, so the pointer is not
/// involved. AppKit and Chromium only deliver one that carries the window's
/// number in field 51 and a window-local position, set with the private
/// CGEventSetWindowLocation. See CLAUDE.md; `make test-scroll` tries it for real.
public enum ScrollEvent {
    public static let windowNumberField = CGEventField(rawValue: 51)!

    /// An app's window to scroll.
    public struct Target {
        public var pid: pid_t
        public var windowID: CGWindowID
        public var bounds: CGRect

        public init(pid: pid_t, windowID: CGWindowID, bounds: CGRect) {
            self.pid = pid
            self.windowID = windowID
            self.bounds = bounds
        }
    }

    private typealias SetLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias GetLocation = @convention(c) (CGEvent) -> CGPoint

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)  // RTLD_DEFAULT
    }

    private static let setLocation: SetLocation? = symbol("CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: SetLocation.self) }

    /// Whether this macOS still has the private call the wheel depends on.
    public static var isAvailable: Bool { setLocation != nil }

    /// The window-local position stamped on an event, for tests; nil if
    /// this macOS can't read it.
    public static func windowLocation(of event: CGEvent) -> CGPoint? {
        symbol("CGEventGetWindowLocation").map { unsafeBitCast($0, to: GetLocation.self)(event) }
    }

    /// The app's frontmost ordinary window.
    public static func frontWindow(of pid: pid_t) -> Target? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for window in list {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.width > 50, bounds.height > 50
            else { continue }
            return Target(pid: pid, windowID: id, bounds: bounds)
        }
        return nil
    }

    /// A wheel of `lines`, up when positive, for the middle of the window.
    public static func make(lines: Int32, for target: Target) -> CGEvent? {
        guard let setLocation,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                  wheel1: lines, wheel2: 0, wheel3: 0) else { return nil }
        event.location = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
        setLocation(event, CGPoint(x: target.bounds.width / 2, y: target.bounds.height / 2))
        event.setIntegerValueField(windowNumberField, value: Int64(target.windowID))
        return event
    }

    /// Scrolls the window; false if the event can't be built.
    @discardableResult
    public static func post(lines: Int32, to target: Target) -> Bool {
        guard let event = make(lines: lines, for: target) else { return false }
        event.postToPid(target.pid)
        return true
    }
}
