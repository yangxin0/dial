import AppKit
import WebKit

// What the test scrolls. Each reports how far down it is, growing as it
// scrolls down, so every target reads the same way.

private func report(_ value: Int, to path: String) {
    try? "\(value)".write(toFile: path, atomically: true, encoding: .utf8)
}

private func makeWindow(_ title: String, _ content: NSView) -> NSWindow {
    let height = NSScreen.screens[0].frame.height
    let window = NSWindow(contentRect: NSRect(x: 60, y: height - 520, width: 520, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = title
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    return window
}

func runNativeFixture(path: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
    let page = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 40000))
    scroll.documentView = page
    scroll.hasVerticalScroller = true
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 20000))
    let window = makeWindow("Scroll test: native", scroll)
    app.activate(ignoringOtherApps: true)
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        // A view's y grows upward: turned round, it grows as the page goes down.
        report(40000 - Int(scroll.contentView.bounds.origin.y), to: path)
    }
    withExtendedLifetime(window) { app.run() }
    exit(0)
}

func runWebKitFixture(path: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
    web.loadHTMLString("<!doctype html><body style='margin:0;height:40000px'><script>scrollTo(0,20000)</script>", baseURL: nil)
    let window = makeWindow("Scroll test: WebKit", web)
    app.activate(ignoringOtherApps: true)
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        web.evaluateJavaScript("Math.round(scrollY)") { value, _ in
            if let value = value as? Int { report(value, to: path) }
        }
    }
    withExtendedLifetime(window) { app.run() }
    exit(0)
}

/// Runs inside a terminal as a full-screen program does: asks for mouse
/// reports, and counts the wheel notches it gets, down positive.
func runWheelReporter(path: String) -> Never {
    var raw = termios()
    tcgetattr(0, &raw)
    cfmakeraw(&raw)
    tcsetattr(0, TCSANOW, &raw)
    print("\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h", terminator: "")
    fflush(stdout)
    var net = 0
    report(net, to: path)
    var pending = ""
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(0, &buffer, buffer.count)
        if n <= 0 { exit(0) }
        pending += String(decoding: buffer[0..<n], as: UTF8.self)
        while let range = pending.range(of: "\u{1b}[<") {
            guard let end = pending[range.upperBound...].firstIndex(where: { $0 == "M" || $0 == "m" }) else { break }
            let button = pending[range.upperBound..<end].split(separator: ";").first.flatMap { Int($0) }
            if button == 64 { net -= 1 }
            if button == 65 { net += 1 }
            pending = String(pending[pending.index(after: end)...])
        }
        report(net, to: path)
    }
}
