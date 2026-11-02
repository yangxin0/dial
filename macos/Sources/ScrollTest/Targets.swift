import AppKit
import ApplicationServices

/// How to read a target's position.
enum Probe {
    case file(String)
    /// A number in the window's title: `y=123`. Chrome's page keeps it there.
    case windowTitle(pid_t)
    /// No number to read: compare screenshots of the window.
    case screenshots
}

/// A running app to scroll.
struct Launched {
    var process: Process
    var pid: pid_t
    var probe: Probe
    var cleanup: () -> Void = {}
}

/// An app to test against.
struct TestTarget {
    var name: String
    /// How far its position moves per wheel line, measured on 2026-11-02.
    /// Only checks the order of magnitude, so it catches a ring that barely
    /// scrolls, as an earlier build did.
    var perLine: Double
    /// Why it can't run here, if it can't.
    var unavailable: () -> String?
    var launch: (_ scratch: URL) throws -> Launched
}

private let chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
private let weztermPath = "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui"

private func spawn(_ path: String, _ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func installed(_ path: String, _ name: String) -> () -> String? {
    { FileManager.default.isExecutableFile(atPath: path) ? nil : "\(name) is not installed" }
}

let allTargets: [TestTarget] = {
    let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return [
        TestTarget(name: "native", perLine: 10, unavailable: { nil }) { scratch in
            let path = scratch.appendingPathComponent("native.y").path
            let process = try spawn(me, ["fixture-native", path])
            return Launched(process: process, pid: process.processIdentifier, probe: .file(path))
        },
        TestTarget(name: "webkit", perLine: 40, unavailable: { nil }) { scratch in
            let path = scratch.appendingPathComponent("webkit.y").path
            let process = try spawn(me, ["fixture-webkit", path])
            return Launched(process: process, pid: process.processIdentifier, probe: .file(path))
        },
        // A separate Chrome with a temporary profile: yours is not touched.
        TestTarget(name: "chrome", perLine: 40, unavailable: installed(chromePath, "Chrome")) { scratch in
            let page = scratch.appendingPathComponent("page.html")
            try """
            <!doctype html><title>y=0</title><body style="margin:0;height:40000px"><script>
            scrollTo(0,20000);setInterval(()=>{document.title='y='+Math.round(scrollY)},50)
            </script>
            """.write(to: page, atomically: true, encoding: .utf8)
            let process = try spawn(chromePath, [
                "--user-data-dir=" + scratch.appendingPathComponent("chrome-profile").path,
                "--no-first-run", "--no-default-browser-check", "--disable-sync",
                "--use-mock-keychain", "--password-store=basic", "--new-window", page.absoluteString,
            ])
            return Launched(process: process, pid: process.processIdentifier, probe: .windowTitle(process.processIdentifier))
        },
        // A full-screen terminal program, as an editor or a TUI is.
        TestTarget(name: "wezterm", perLine: 1, unavailable: installed(weztermPath, "WezTerm")) { scratch in
            let path = scratch.appendingPathComponent("wezterm.y").path
            let process = try spawn(weztermPath, ["-n", "start", "--always-new-process", "--", me, "report", path])
            return Launched(process: process, pid: process.processIdentifier, probe: .file(path))
        },
        // The shell's scrollback, which is WezTerm's own scrolling.
        TestTarget(name: "wezterm-scrollback", perLine: 1, unavailable: {
            if let missing = installed(weztermPath, "WezTerm")() { return missing }
            return CGPreflightScreenCaptureAccess() ? nil : "needs Screen Recording for the terminal, to compare screenshots"
        }) { _ in
            let process = try spawn(weztermPath, ["-n", "start", "--always-new-process", "--", "/bin/sh", "-c", "seq 1 6000; sleep 300"])
            return Launched(process: process, pid: process.processIdentifier, probe: .screenshots)
        },
    ]
}()

/// The number in `y=123`.
func readProbe(_ probe: Probe) -> Int? {
    switch probe {
    case .file(let path):
        return (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    case .windowTitle(let pid):
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String, let range = text.range(of: #"y=-?\d+"#, options: .regularExpression)
            else { continue }
            return Int(text[range].dropFirst(2))
        }
        return nil
    case .screenshots:
        return nil
    }
}
