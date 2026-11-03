import AppKit
import ApplicationServices
import DialKit

enum Outcome: String {
    case pass = "PASS", fail = "FAIL", skip = "SKIP", invalid = "INVALID"
}

/// Thrown when a run can't prove anything, so it must not read as a result.
struct Invalid: Error {
    var reason: String
}

/// So a Ctrl-C never leaves the button held or a fixture running.
private var runningProcesses: [Process] = []
/// What to put back if a run is stopped while it has changed the theme.
private var configToRestore: (path: String, data: Data)?
private func restoreConfig() {
    if let saved = configToRestore { try? saved.data.write(to: URL(fileURLWithPath: saved.path)) }
    configToRestore = nil
}
private func releaseButton() {
    let at = CGEvent(source: nil)?.location ?? .zero
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
}

final class Runner {
    /// How far the pointer may stray from the drag's path, in points.
    static let pathTolerance: CGFloat = 6
    /// A half turn, which scrolls this many lines.
    static let halfTurnLines = Double(CGFloat.pi / TurnCounter.radiansPerLine)

    private let only: Set<String>?
    private let sabotage = ProcessInfo.processInfo.environment["SCROLLTEST_SABOTAGE"]
    private var results: [(target: String, check: String, outcome: Outcome, detail: String)] = []
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dial-scroll-test-\(getpid())")

    init(only: Set<String>?) {
        self.only = only
    }

    private func record(_ target: String, _ check: String, _ outcome: Outcome, _ detail: String) {
        results.append((target, check, outcome, detail))
        print("\(outcome.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(target.padding(toLength: 19, withPad: " ", startingAt: 0)) \(check.padding(toLength: 30, withPad: " ", startingAt: 0)) \(detail)")
    }

    func run() -> Int32 {
        signal(SIGINT) { _ in
            releaseButton()
            restoreConfig()
            runningProcesses.forEach { kill($0.processIdentifier, SIGTERM) }
            _exit(130)
        }
        print("ScrollTest: taking over the pointer. Don't touch the mouse until it's done.")
        let pointer = currentPointer()
        let previous = frontPID().flatMap { NSRunningApplication(processIdentifier: $0) }
        defer {
            CGWarpMouseCursorPosition(pointer)
            previous?.activate(options: [])
            try? FileManager.default.removeItem(at: scratch)
        }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try checkPreconditions()
            for target in allTargets where only?.contains(target.name) ?? true {
                if let reason = target.unavailable() {
                    record(target.name, "(whole target)", .skip, reason)
                    continue
                }
                try test(target)
            }
            if only?.contains("clicks") ?? true {
                try testClicks()
            }
            if only?.contains("theme") ?? true {
                try testTheme()
            }
        } catch let invalid as Invalid {
            print("\nINVALID: \(invalid.reason)\nThis run proved nothing, so it doesn't count as a pass or a failure.")
            return 2
        } catch {
            print("\nINVALID: \(error)")
            return 2
        }
        let failed = results.filter { $0.outcome == .fail }
        let passed = results.filter { $0.outcome == .pass }.count
        let skipped = results.filter { $0.outcome == .skip }
        print("\n\(passed) passed, \(failed.count) failed, \(skipped.count) skipped")
        for skip in skipped { print("  skipped \(skip.target): \(skip.detail)") }
        if !failed.isEmpty {
            print("If you moved the mouse during the run, run it again before believing a pointer failure.")
            return 1
        }
        return 0
    }

    // MARK: - Preconditions

    private func checkPreconditions() throws {
        guard AXIsProcessTrusted() else {
            throw Invalid(reason: "this terminal needs Accessibility, to drive the mouse and read Chrome's title")
        }
        guard ScrollEvent.isAvailable else {
            throw Invalid(reason: "this macOS has no CGEventSetWindowLocation: run `make test` for the details")
        }
        // A run against the wrong build once looked like a result.
        let dials = NSRunningApplication.runningApplications(withBundleIdentifier: "com.yangxin.dial")
        guard dials.count == 1, let dial = dials.first?.executableURL else {
            throw Invalid(reason: "expected one running dial, found \(dials.count)")
        }
        let built = (try? FileManager.default.attributesOfItem(atPath: dial.path)[.modificationDate] as? Date) ?? .distantPast
        print("Dial under test: \(dial.path), built \(built)")
        guard waitFor(seconds: 15, { self.dialShape() != nil }) else {
            throw Invalid(reason: "no dial on screen: `make test-scroll` starts one, or run `make run`")
        }
        // A dial just started takes a moment to reach its core.
        var status: [String: Any]?
        let connected = waitFor(seconds: 15) {
            status = self.coreStatus()
            return status?["connected"] as? Bool == true
        }
        guard connected, let status else {
            throw Invalid(reason: status == nil ? "dial-core doesn't answer on its port" : "the dial isn't connected to dial-core")
        }
        guard status["accessibility"] as? Bool == true else {
            // Posting silently does nothing without this grant, which would
            // read as a broken ring.
            throw Invalid(reason: "the running dial hasn't got Accessibility")
        }
    }

    /// The dial on screen, at whatever size: its ring's centre (origin at the top
    /// left), its scale, and how see-through macOS is showing it.
    private struct DialShape {
        var center: CGPoint
        var scale: CGFloat
        var alpha: CGFloat
        var width: CGFloat
    }

    private func dialShape() -> DialShape? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list where window[kCGWindowOwnerName as String] as? String == "Dial" {
            guard let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict), bounds.width > 0,
                  abs(bounds.height / bounds.width - DialMetrics.height / DialMetrics.width) < 0.02 else { continue }
            let scale = bounds.width / DialMetrics.width
            return DialShape(center: CGPoint(x: bounds.midX, y: bounds.minY + (DialMetrics.topMargin + DialMetrics.outerRadius) * scale),
                             scale: scale, alpha: window[kCGWindowAlpha as String] as? CGFloat ?? 1, width: bounds.width)
        }
        return nil
    }

    /// What dial-core knows of the dial.
    private func coreStatus() -> [String: Any]? {
        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: "127.0.0.1", port: 47831, inputStream: &input, outputStream: &output)
        guard let input, let output else { return nil }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }
        let hello = Array(#"{"type":"hello","platform":"scrolltest","version":"0"}"#.utf8) + [0x0A]
        guard output.write(hello, maxLength: hello.count) == hello.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = input.read(&buffer, maxLength: buffer.count)
        guard n > 0, let line = String(decoding: buffer[0..<n], as: UTF8.self).split(separator: "\n").first,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return object["dial"] as? [String: Any]
    }

    // MARK: - One target

    private func test(_ target: TestTarget) throws {
        let launched = try target.launch(scratch)
        runningProcesses.append(launched.process)
        defer {
            launched.cleanup()
            launched.process.terminate()
            runningProcesses.removeAll { $0 === launched.process }
            usleep(400_000)
        }
        print("--- \(target.name)")
        // Ready: it has a window, and its position can be read.
        let ready = waitFor(seconds: 25) {
            guard ScrollEvent.frontWindow(of: launched.pid) != nil else { return false }
            if case .screenshots = launched.probe { return true }
            return readProbe(launched.probe) != nil
        }
        guard ready else { throw Invalid(reason: "\(target.name) never became ready to measure") }
        usleep(500_000)
        try bringToFront(launched.pid, target.name)
        if case .screenshots = launched.probe {
            try testByScreenshots(target, launched)
        } else {
            try testByPosition(target, launched)
        }
    }

    private func bringToFront(_ pid: pid_t, _ name: String) throws {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        guard waitFor(seconds: 5, { self.frontPID() == pid }) else {
            throw Invalid(reason: "\(name) didn't come to the front: \(frontName()) is, so nothing would be measured")
        }
    }

    private func lsappinfo(_ arguments: [String]) -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The process in front, asked of the system each time. NSWorkspace's
    /// answer on this thread goes stale: it once said an app stayed in front
    /// for six seconds after another had come up, which read as macOS refusing
    /// the switch.
    private func frontPID() -> pid_t? {
        let info = lsappinfo(["info", "-only", "pid", lsappinfo(["front"])])
        guard let label = info.range(of: "pid = ") else { return nil }
        return pid_t(info[label.upperBound...].prefix { $0.isNumber })
    }
    private func frontName() -> String { frontPID().flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "nothing" }

    /// A test is only valid with the target really in front: an earlier test
    /// wasn't, and nothing noticed.
    private func requireFront(_ pid: pid_t, _ name: String) throws {
        if sabotage == "front" {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [.activateIgnoringOtherApps])
            usleep(500_000)
        }
        guard frontPID() == pid else {
            throw Invalid(reason: "\(name) isn't in front: \(frontName()) is, so this would measure the wrong app")
        }
    }

    // MARK: - Clicks on the ring

    private func frontID() -> String? {
        frontPID().flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }

    /// The ring once it has come to rest with the app in front on it, and so
    /// at the top: a pick reorders the ring and turns it.
    private func settledRing() throws -> (ids: [String], front: String) {
        var last: [String] = []
        var stable = 0
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            usleep(300_000)
            guard let ring = coreStatus()?["ring"] as? [String], let front = frontID(), ring.contains(front) else {
                stable = 0
                continue
            }
            stable = ring == last ? stable + 1 : 0
            last = ring
            if stable >= 3 { return (Array(ring.prefix(DialMetrics.maxSlots)), front) }
        }
        throw Invalid(reason: "the ring didn't settle with the app in front on it (\(frontID() ?? "nothing") is in front)")
    }

    /// Where an icon is on screen, or `offset` degrees clockwise from it.
    private func iconPoint(_ id: String, in ring: (ids: [String], front: String), _ shape: DialShape, offset: Double = 0) -> CGPoint {
        let index = ring.ids.firstIndex(of: id) ?? 0, top = ring.ids.firstIndex(of: ring.front) ?? 0
        let degrees = (90 - (Double(index - top) * 360 / Double(ring.ids.count) + offset)) * .pi / 180
        let radius = DialMetrics.slotRadius * shape.scale
        return CGPoint(x: shape.center.x + radius * cos(degrees), y: shape.center.y - radius * sin(degrees))
    }

    /// Windows of the app a person can see on this desktop.
    private func visibleWindows(_ pid: pid_t) -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid, window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return bounds.width >= 100 && bounds.height >= 100
        }.count
    }

    private let dialLog = NSHomeDirectory() + "/Library/Logs/Dial/dial.log"
    private func logSize() -> Int { FileManager.default.contents(atPath: dialLog)?.count ?? 0 }
    /// What the dial says it picked since the log was this long.
    private func picks(since mark: Int) -> [String] {
        usleep(150_000)
        guard let data = FileManager.default.contents(atPath: dialLog), data.count >= mark else { return [] }
        return String(decoding: data[mark...], as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let range = line.range(of: " pick ") else { return nil }
            return String(line[range.upperBound...])
        }
    }

    /// A press and a release, the pointer moving `drift` points between them
    /// as a hand's does.
    private func click(at point: CGPoint, drift: Int = 0) throws {
        post(.mouseMoved, at: point)
        usleep(150_000)
        let here = currentPointer()
        guard hypot(here.x - point.x, here.y - point.y) < 1 else {
            throw Invalid(reason: "the pointer is at \(Int(here.x)),\(Int(here.y)), not the \(Int(point.x)),\(Int(point.y)) this test put it at: the mouse moved during a click. Run it again without touching the mouse")
        }
        post(.leftMouseDown, at: point)
        usleep(60_000)
        var at = point
        for _ in 0..<drift {
            at.x += 1
            post(.leftMouseDragged, at: at)
            usleep(10_000)
        }
        usleep(40_000)
        post(.leftMouseUp, at: at)
    }

    /// Clicks every icon on the real ring: its app must come to the front and
    /// show a window, as a click on its Dock icon does. An app with its windows
    /// closed once came "to the front" with nothing on screen, which reads as
    /// the click doing nothing. Then the other half of a press: only a release
    /// on an icon switches, and moving turns the ring instead.
    private func testClicks() throws {
        print("--- clicks")
        let name = "clicks"
        guard let shape = dialShape() else { throw Invalid(reason: "the dial's window went away") }
        var ring = try settledRing()
        guard ring.ids.count >= 3 else {
            record(name, "(whole target)", .skip, "fewer than three apps on the ring")
            return
        }
        func label(_ id: String) -> String {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? id
        }

        var visited = Set<String>()
        while let id = ring.ids.first(where: { $0 != ring.front && !visited.contains($0) }) {
            visited.insert(id)
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier else { continue }
            let before = visibleWindows(pid), mark = logSize()
            try click(at: iconPoint(id, in: ring, shape))
            let shown = waitFor(seconds: 6) { self.frontID() == id && self.visibleWindows(pid) > 0 }
            let picked = picks(since: mark)
            let start = before > 0 ? "had \(before) window(s)" : "had no window"
            if picked != [id] {
                record(name, "click \(label(id))", .fail, "\(start), and the dial picked \(picked)")
            } else if !shown {
                record(name, "click \(label(id))", .fail, "\(start); \(frontName()) is in front, and \(label(id)) shows \(visibleWindows(pid)) window(s)")
            } else {
                usleep(800_000)
                let after = visibleWindows(pid)
                if before > 0, after > before {
                    record(name, "click \(label(id))", .fail, "\(start), and the click opened another")
                } else {
                    record(name, "click \(label(id))", .pass, "\(start), in front showing \(after)")
                }
            }
            ring = try settledRing()
        }

        // Hidden and minimized windows are the same trap as closed ones.
        for way in ["hidden", "minimized"] {
            guard let id = ring.ids.first(where: { id in
                guard id != ring.front, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return false }
                return visibleWindows(app.processIdentifier) > 0
            }), let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else {
                record(name, "click a \(way) app", .skip, "no other app on the ring shows a window")
                continue
            }
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
            let windows = value as? [AXUIElement] ?? []
            if way == "hidden" {
                app.hide()
            } else {
                for window in windows { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
            }
            defer {
                app.unhide()
                for window in windows { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            }
            guard waitFor(seconds: 4, { self.visibleWindows(pid) == 0 }) else {
                record(name, "click a \(way) app", .skip, "\(label(id)) wouldn't get out of sight")
                continue
            }
            ring = try settledRing()
            guard ring.ids.contains(id) else { continue }
            try click(at: iconPoint(id, in: ring, shape))
            let shown = waitFor(seconds: 6) { self.frontID() == id && self.visibleWindows(pid) > 0 }
            record(name, "click a \(way) app", shown ? .pass : .fail, "\(label(id)): \(frontName()) in front, showing \(visibleWindows(pid)) window(s)")
            app.unhide()
            for window in windows { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            ring = try settledRing()
        }

        // A hand's click isn't still.
        if let id = ring.ids.first(where: { $0 != ring.front }) {
            let mark = logSize()
            try click(at: iconPoint(id, in: ring, shape), drift: 5)
            let up = waitFor(seconds: 4) { self.frontID() == id }
            let picked = picks(since: mark)
            record(name, "click that wobbles 5 points", up && picked == [id] ? .pass : .fail, "picked \(picked), \(frontName()) in front")
            ring = try settledRing()
        }

        // Between two icons there is nothing to click.
        do {
            let mark = logSize()
            try click(at: iconPoint(ring.front, in: ring, shape, offset: 180 / Double(ring.ids.count)))
            usleep(900_000)
            let picked = picks(since: mark)
            record(name, "click between two icons", picked.isEmpty && frontID() == ring.front ? .pass : .fail, "picked \(picked), \(frontName()) in front")
            ring = try settledRing()
        }

        // Pressing an icon and moving is a drag, however short.
        if let id = ring.ids.first(where: { $0 != ring.front }) {
            let mark = logSize()
            try click(at: iconPoint(id, in: ring, shape), drift: 12)
            usleep(900_000)
            let picked = picks(since: mark)
            record(name, "press an icon, move 12 points", picked.isEmpty && frontID() == ring.front ? .pass : .fail, "picked \(picked), \(frontName()) in front")
            ring = try settledRing()
        }
    }

    /// Changes the theme in the real config, checks the running dial follows
    /// it, and drags the ring at that size and transparency: a resized or
    /// see-through window could stop taking clicks. The config is put back.
    private func testTheme() throws {
        let name = "theme"
        print("--- \(name)")
        let dir = ProcessInfo.processInfo.environment["DIAL_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.config/dial")
        let path = dir + "/config.json"
        guard let original = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var config = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else {
            throw Invalid(reason: "can't read the config at \(path)")
        }
        configToRestore = (path, original)
        defer { restoreConfig() }
        guard let target = allTargets.first(where: { $0.name == "native" }) else { return }
        let launched = try target.launch(scratch)
        runningProcesses.append(launched.process)
        defer {
            launched.process.terminate()
            runningProcesses.removeAll { $0 === launched.process }
            usleep(400_000)
        }
        guard waitFor(seconds: 25, { ScrollEvent.frontWindow(of: launched.pid) != nil && readProbe(launched.probe) != nil }) else {
            throw Invalid(reason: "the theme test's window never became ready")
        }
        usleep(500_000)
        try bringToFront(launched.pid, name)
        // The ends of the range: the smallest, and the biggest that fits, most see-through.
        for (size, transparency) in [(CGFloat(0.5), CGFloat(0)), (CGFloat(2.5), DialTheme.maxTransparency)] {
            let label = "size \(Int(size * 100))%, transparent \(Int(transparency * 100))%"
            config["theme"] = ["size": size, "transparency": transparency]
            try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted).write(to: URL(fileURLWithPath: path))
            let want = DialMetrics.width * size
            let applied = waitFor(seconds: 5) {
                guard let shape = self.dialShape() else { return false }
                return abs(shape.width - want) < 1 && abs(shape.alpha - (1 - transparency)) < 0.02
            }
            let now = dialShape()
            record(name, label + ": applied", applied ? .pass : .fail,
                   applied ? "the running dial is \(Int(want)) wide" : "the dial is \(Int(now?.width ?? 0)) wide with alpha \(now?.alpha ?? 0), wanted \(Int(want)) and \(1 - transparency)")
            guard applied else { continue }
            usleep(300_000)
            try checkDrag(target, launched, label: label, from: 90, to: -90) { moved in
                moved > 0 ? self.size(moved, Self.halfTurnLines * target.perLine) : "moved \(moved), expected down"
            }
        }
        // And back: the dial follows the original config again.
        restoreConfig()
        guard let original = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] else { return }
        let theme = original["theme"] as? [String: Any]
        let size = theme?["size"] as? CGFloat ?? 1
        let back = waitFor(seconds: 5) { abs((self.dialShape()?.width ?? 0) - DialMetrics.width * size) < 1 }
        record(name, "put back", back ? .pass : .fail, back ? "the dial returned to \(Int(size * 100))%" : "the dial didn't return to \(Int(size * 100))%")
    }

    private func position(_ probe: Probe, _ name: String) throws -> Int {
        guard let value = readProbe(probe) else { throw Invalid(reason: "can't read \(name)'s position") }
        return value
    }

    private func testByPosition(_ target: TestTarget, _ launched: Launched) throws {
        let pid = launched.pid, probe = launched.probe, name = target.name
        try requireFront(pid, name)
        guard let window = ScrollEvent.frontWindow(of: pid) else { throw Invalid(reason: "\(name) has no window") }

        // The old method must do nothing. If it starts scrolling, this test
        // no longer tells the methods apart, and its results can't be trusted.
        let beforeOld = try position(probe, name)
        postOldMethod(window)
        usleep(700_000)
        let oldMoved = try position(probe, name) - beforeOld
        if oldMoved != 0 {
            record(name, "old method does nothing", .fail, "it moved \(oldMoved): this test no longer tells the methods apart")
        } else {
            record(name, "old method does nothing", .pass, "moved 0")
        }

        // The recipe, posted directly, without the dial: so a ring failure
        // below can be told from the target itself not scrolling.
        let beforeDirect = try position(probe, name)
        for _ in 0..<5 {
            ScrollEvent.post(lines: -3, to: window)
            usleep(30_000)
        }
        usleep(700_000)
        let direct = try position(probe, name) - beforeDirect
        record(name, "recipe scrolls it directly", direct > 0 ? .pass : .fail, "moved \(direct), expected down")

        let expected = Self.halfTurnLines * target.perLine
        try checkDrag(target, launched, label: "ring clockwise", from: 90, to: -90) { moved in
            moved > 0 ? self.size(moved, expected) : "moved \(moved), expected down"
        }
        try checkDrag(target, launched, label: "ring counterclockwise", from: -90, to: 90) { moved in
            moved < 0 ? self.size(-moved, expected) : "moved \(moved), expected up"
        }
    }

    /// Nil when a scroll is about the right size. Too small is how a ring that
    /// barely scrolled showed up.
    private func size(_ moved: Int, _ expected: Double) -> String? {
        Double(moved) >= expected / 2 && Double(moved) <= expected * 2 ? nil : "moved \(moved), expected about \(Int(expected))"
    }

    private func checkDrag(_ target: TestTarget, _ launched: Launched, label: String, from: Double, to: Double,
                           judge: (Int) -> String?) throws {
        let before = try position(launched.probe, target.name)
        let offPath = try drag(launched.pid, target.name, from: from, to: to)
        let moved = try position(launched.probe, target.name) - before
        let problem = judge(moved)
        record(target.name, label + ": scroll", problem == nil ? .pass : .fail, problem ?? "moved \(moved)")
        recordPointer(target.name, label, offPath)
    }

    private func recordPointer(_ name: String, _ label: String, _ offPath: CGFloat) {
        let ok = offPath <= Self.pathTolerance
        record(name, label + ": pointer", ok ? .pass : .fail,
               "strayed \(Int(offPath.rounded())) pt from the drag's path" + (ok ? "" : ": the pointer was pulled away"))
    }

    private func testByScreenshots(_ target: TestTarget, _ launched: Launched) throws {
        let pid = launched.pid, name = target.name
        try requireFront(pid, name)
        guard let window = ScrollEvent.frontWindow(of: pid) else { throw Invalid(reason: "\(name) has no window") }
        // A window just brought forward is still redrawing: wait until it's still.
        var base = try screenshot(window.windowID, "base")
        var settled = false
        for _ in 0..<20 where !settled {
            usleep(500_000)
            let next = try screenshot(window.windowID, "control")
            settled = next == base
            base = next
        }
        guard settled else {
            throw Invalid(reason: "\(name)'s window keeps changing by itself, so screenshots can't show a scroll")
        }
        var offPath = try drag(pid, name, from: -90, to: 90)
        record(name, "ring counterclockwise", try screenshot(window.windowID, "up") != base ? .pass : .fail, "the view moved up from the bottom")
        // Twice, so it's back at the bottom however far the first turn went.
        offPath = max(offPath, try drag(pid, name, from: 90, to: -90))
        offPath = max(offPath, try drag(pid, name, from: 90, to: -90))
        record(name, "ring clockwise", try screenshot(window.windowID, "down") == base ? .pass : .fail, "the view came back to the bottom")
        recordPointer(name, "ring", offPath)
    }

    private func screenshot(_ window: CGWindowID, _ label: String) throws -> Data {
        let path = scratch.appendingPathComponent("\(label).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window)", path.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: path), !data.isEmpty else {
            throw Invalid(reason: "couldn't take a screenshot of the test window")
        }
        return data
    }

    // MARK: - Input

    private func currentPointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// What the dial did before: the fields that do nothing.
    private func postOldMethod(_ window: ScrollEvent.Target) {
        for _ in 0..<5 {
            if sabotage == "old" {
                // Posts what works instead, so the comparison has to fire.
                ScrollEvent.post(lines: -3, to: window)
                usleep(30_000)
                continue
            }
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0) else { continue }
            event.location = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowID))
            event.postToPid(window.pid)
            usleep(30_000)
        }
    }

    /// Drags round the ring with the button held, as a hand does, and returns
    /// how far the pointer ever was from the ring's path. Angles are in
    /// degrees, counterclockwise from the right.
    ///
    /// The motion is relative to wherever the pointer is, with pauses, because
    /// a hand's is. An earlier version sent absolute positions, each of which
    /// put the pointer back on the path, and passed the build that was pulling
    /// the pointer to the middle of the screen.
    private func drag(_ pid: pid_t, _ name: String, from: Double, to: Double) throws -> CGFloat {
        try requireFront(pid, name)
        guard let shape = dialShape() else { throw Invalid(reason: "the dial's window went away") }
        let center = shape.center, radius = DialMetrics.slotRadius * shape.scale
        func point(_ degrees: Double) -> CGPoint {
            let r = degrees * .pi / 180
            return CGPoint(x: center.x + radius * cos(r), y: center.y - radius * sin(r))
        }
        post(.mouseMoved, at: point(from))
        usleep(120_000)
        if sabotage != "button" { post(.leftMouseDown, at: point(from)) }
        usleep(80_000)
        // The pointer bug only showed with the button down.
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            throw Invalid(reason: "the button isn't held, so this isn't a ring drag")
        }
        defer {
            post(.leftMouseUp, at: currentPointer())
            usleep(700_000)
        }
        let watch = PointerWatch(center: center, radius: radius)
        watch.start()
        defer { watch.stop() }
        let steps = 90
        for i in 1...steps {
            let last = point(from + (to - from) * Double(i - 1) / Double(steps))
            let next = point(from + (to - from) * Double(i) / Double(steps))
            let dx = next.x - last.x, dy = next.y - last.y
            let here = currentPointer()
            let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                mouseCursorPosition: CGPoint(x: here.x + dx, y: here.y + dy), mouseButton: .left)
            event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
            event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
            event?.setIntegerValueField(.eventSourceUserData, value: PointerWatch.ourTag)
            event?.post(tap: .cghidEventTap)
            // A hand stops now and then. Nothing puts the pointer back during this.
            usleep(i % 15 == 0 ? 90_000 : 12_000)
        }
        usleep(150_000)
        let (worst, wheels, others) = watch.stop()
        if wheels > 0 {
            record(name, "no wheel through the system", .fail, "\(wheels) passed through it during the drag, and those move the pointer")
        } else if others > 0 {
            // With no wheel to blame, this motion came from outside the dial.
            throw Invalid(reason: "the mouse moved during a drag (\(others) events that aren't this test's). Run it again without touching the mouse")
        }
        if frontPID() != pid {
            record(name, "app stays in front", .fail, "\(frontName()) took the front during the drag")
        }
        return worst
    }

    private func waitFor(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }
}

/// Watches the pointer through a drag, about every millisecond: how far it
/// strays from the ring's path, and how many wheel events pass through the
/// system, which is the thing that moves it. A wheel posted to a process
/// doesn't pass there.
final class PointerWatch {
    private let center: CGPoint
    private let radius: CGFloat
    private let lock = NSLock()
    private var worst: CGFloat = 0
    private var wheels = 0
    private var others = 0
    private var running = false
    private var stopped = false
    private var result: (CGFloat, Int, Int) = (0, 0, 0)
    /// Marks this test's own drag events.
    static let ourTag: Int64 = 0xD1A2
    private var tap: CFMachPort?
    private var tapLoop: CFRunLoop?

    init(center: CGPoint, radius: CGFloat) {
        self.center = center
        self.radius = radius
    }

    func start() {
        running = true
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                if let at = CGEvent(source: nil)?.location {
                    let off = abs(hypot(at.x - center.x, at.y - center.y) - radius)
                    lock.withLock { worst = max(worst, off) }
                }
                usleep(1_000)
            }
        }
        Thread.detachNewThread { [self] in
            let callback: CGEventTapCallBack = { _, type, event, info in
                if let info {
                    let watch = Unmanaged<PointerWatch>.fromOpaque(info).takeUnretainedValue()
                    if type == .scrollWheel {
                        watch.lock.withLock { watch.wheels += 1 }
                    } else if event.getIntegerValueField(.eventSourceUserData) != PointerWatch.ourTag {
                        watch.lock.withLock { watch.others += 1 }
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                               eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue)
                                                   | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
                                                   | CGEventMask(1 << CGEventType.mouseMoved.rawValue),
                                               callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            lock.withLock {
                tap = port
                tapLoop = CFRunLoopGetCurrent()
            }
            CFRunLoopRun()
        }
        usleep(50_000)  // Let the tap come up before the drag starts.
    }

    /// Safe to call twice: the second call returns the same result.
    @discardableResult
    func stop() -> (CGFloat, Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return result }
        stopped = true
        running = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapLoop { CFRunLoopStop(tapLoop) }
        result = (worst, wheels, others)
        return result
    }
}
