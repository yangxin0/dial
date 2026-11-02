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
            runningProcesses.forEach { kill($0.processIdentifier, SIGTERM) }
            _exit(130)
        }
        print("ScrollTest: taking over the pointer. Don't touch the mouse until it's done.")
        let pointer = currentPointer()
        let previous = NSWorkspace.shared.frontmostApplication
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
        guard waitFor(seconds: 15, { self.dialCenter() != nil }) else {
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

    /// The ring's centre on screen, origin at the top left.
    private func dialCenter() -> CGPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in list where window[kCGWindowOwnerName as String] as? String == "Dial" {
            guard let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width == DialMetrics.width, bounds.height == DialMetrics.height else { continue }
            return CGPoint(x: bounds.minX + DialMetrics.width / 2, y: bounds.minY + DialMetrics.topMargin + DialMetrics.outerRadius)
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

    private func frontPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    private func frontName() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing" }

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
        let base = try screenshot(window.windowID, "base")
        usleep(500_000)
        guard try screenshot(window.windowID, "control") == base else {
            throw Invalid(reason: "\(name)'s window changes by itself, so screenshots can't show a scroll")
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
        guard let center = dialCenter() else { throw Invalid(reason: "the dial's window went away") }
        func point(_ degrees: Double) -> CGPoint {
            let r = degrees * .pi / 180
            return CGPoint(x: center.x + DialMetrics.slotRadius * cos(r), y: center.y - DialMetrics.slotRadius * sin(r))
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
        let watch = PointerWatch(center: center, radius: DialMetrics.slotRadius)
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
            event?.post(tap: .cghidEventTap)
            // A hand stops now and then. Nothing puts the pointer back during this.
            usleep(i % 15 == 0 ? 90_000 : 12_000)
        }
        usleep(150_000)
        let (worst, wheels) = watch.stop()
        if wheels > 0 {
            record(name, "no wheel through the system", .fail, "\(wheels) passed through it during the drag, and those move the pointer")
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
    private var running = false
    private var stopped = false
    private var result: (CGFloat, Int) = (0, 0)
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
                if type == .scrollWheel, let info {
                    let watch = Unmanaged<PointerWatch>.fromOpaque(info).takeUnretainedValue()
                    watch.lock.withLock { watch.wheels += 1 }
                }
                return Unmanaged.passUnretained(event)
            }
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                               eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
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
    func stop() -> (CGFloat, Int) {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return result }
        stopped = true
        running = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapLoop { CFRunLoopStop(tapLoop) }
        result = (worst, wheels)
        return result
    }
}
