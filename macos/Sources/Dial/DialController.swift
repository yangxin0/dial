import AppKit
import AVFoundation
import os.log

private let log = Logger(subsystem: "com.yangxin.dial", category: "dial")

let dialVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

/// Ties the pieces together: the panel on screen, the microphone, the
/// apps, the keys, and the core that decides.
final class DialController {
    let core = CoreClient()
    let apps = AppWatcher()
    let mic = MicrophoneCapture()
    let keys = KeyTap()
    let panel = DialPanel()

    private(set) var phase: Phase = .idle
    private var ring: [String] = []
    private var pendingAudio: [Data] = []
    private var coreListening = false
    private var ready: [String: Bool] = [:]
    private var hintTimer: Timer?
    private var trustTimer: Timer?
    private var statusItem: NSStatusItem?

    func start() {
        Log.write("dial \(dialVersion) starting")
        panel.view.controller = self
        core.onMessage = { [weak self] message in self?.handle(message) }
        core.onConnected = { [weak self] in
            guard let self else { return }
            var hello = Message(type: "hello")
            hello.platform = "macos"
            hello.version = dialVersion
            hello.ready = self.grants
            self.core.send(hello)
            self.sendApps()
        }
        core.onDisconnected = { [weak self] in
            guard let self else { return }
            self.mic.stop()
            self.setPhase(.idle)
            self.show(hint: "dial-core went away, reconnecting…", error: true)
        }
        apps.onChange = { [weak self] in
            self?.sendApps()
            self?.refreshRing()
        }
        apps.start()
        core.start()
        keys.handler = { [weak self] code, flags in self?.handleKey(code, flags) ?? false }
        armKeys(prompt: true)
        // Ask for the microphone now rather than at the first click, so
        // both grants are settled together at launch.
        MicrophoneCapture.requestAccess { [weak self] granted in
            self?.sendGrants()
            if !granted {
                self?.show(hint: "Allow the microphone under Privacy & Security ▸ Microphone ▸ Dial.", error: true)
            }
        }
        makeStatusItem()
        panel.show()
    }

    func stop() {
        mic.stop()
        keys.stop()
        apps.stop()
        core.stop()
    }

    // MARK: - Grants

    /// What macOS has allowed, for Settings' checklist.
    private var grants: [String: Bool] {
        ["accessibility": Input.trusted(prompt: false),
         "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized]
    }

    private func sendGrants() {
        var status = Message(type: "status")
        status.ready = grants
        core.send(status)
    }

    // MARK: - Keys

    /// The key tap needs the Accessibility grant; until it is given, ask
    /// again every few seconds.
    private func armKeys(prompt: Bool) {
        if Input.trusted(prompt: prompt), keys.start() {
            trustTimer?.invalidate()
            trustTimer = nil
            if panel.view.hintIsError { panel.view.hint = nil }
            sendGrants()
            return
        }
        show(hint: "Allow Dial under Privacy & Security ▸ Accessibility. Already on there? Remove it and add it again.", error: true)
        if trustTimer == nil {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.armKeys(prompt: false)
            }
        }
    }

    /// The arrows turn the ring and scroll, space listens, escape cancels:
    /// only while the pointer is over the dial, so the keys stay the
    /// app's otherwise.
    private func handleKey(_ code: Int, _ flags: CGEventFlags) -> Bool {
        guard panel.view.armed else { return false }
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        guard modifiers.isEmpty else { return false }
        switch code {
        case KeyTap.left: turnRing(by: -1)
        case KeyTap.right: turnRing(by: 1)
        case KeyTap.up: Input.scroll(lines: 3)
        case KeyTap.down: Input.scroll(lines: -3)
        case KeyTap.space, KeyTap.returnKey: toggleListening()
        case KeyTap.escape: cancelListening()
        default: return false
        }
        return true
    }

    // MARK: - Ring

    private func sendApps() {
        var message = Message(type: "apps")
        message.apps = apps.records
        core.send(message)
    }

    private func refreshRing() {
        let infos = ring.compactMap { apps.app(id: $0) }
        panel.view.ring = infos
        panel.view.activeID = apps.running.first { $0.active }?.id
    }

    /// Turns the ring by `delta` slots from the active app and brings
    /// that app up; the core learns the pick.
    func turnRing(by delta: Int) {
        guard !ring.isEmpty else {
            show(hint: "No apps on the ring yet.")
            return
        }
        let active = apps.running.first { $0.active }?.id
        let current = active.flatMap { ring.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        var next = (current + delta) % ring.count
        if next < 0 { next += ring.count }
        pick(ring[next])
    }

    /// Switches to an app from the ring (a turn, or a click on its slot).
    func pick(_ id: String) {
        apps.activate(id: id)
        panel.view.activeID = id
        learned(id)
    }

    private func learned(_ id: String) {
        var message = Message(type: "switched")
        message.app = id
        core.send(message)
    }

    // MARK: - Listening

    func toggleListening() {
        switch phase {
        case .idle: startListening()
        case .listening: stopListening()
        case .thinking: break
        }
    }

    private func startListening() {
        guard core.connected else {
            show(hint: "dial-core isn't running yet.", error: true)
            return
        }
        guard ready["voice"] ?? false else {
            show(hint: "Set up the speech engine in Dial Settings first.", error: true)
            return
        }
        MicrophoneCapture.requestAccess { [weak self] granted in
            guard let self else { return }
            self.sendGrants()
            guard granted else {
                self.show(hint: "Allow the microphone in System Settings ▸ Privacy & Security ▸ Microphone.", error: true)
                return
            }
            self.mic.onChunk = { [weak self] chunk in self?.sendAudio(chunk) }
            do {
                try self.mic.start()
            } catch {
                self.show(hint: "Can't record: \(error.localizedDescription)", error: true)
                return
            }
            self.pendingAudio = []
            self.coreListening = false
            self.panel.view.transcript = ""
            self.setPhase(.listening)
            self.core.send(Message(type: "start"))
        }
    }

    private func sendAudio(_ chunk: Data) {
        guard coreListening else {
            pendingAudio.append(chunk)
            if pendingAudio.count > 50 { pendingAudio.removeFirst() }
            return
        }
        var message = Message(type: "audio")
        message.pcm = chunk.base64EncodedString()
        core.send(message)
    }

    private func stopListening() {
        let rest = mic.stop()
        if !rest.isEmpty { sendAudio(rest) }
        core.send(Message(type: "stop"))
        setPhase(.thinking)
    }

    func cancelListening() {
        guard phase != .idle else { return }
        mic.stop()
        pendingAudio = []
        core.send(Message(type: "cancel"))
        setPhase(.idle)
        panel.view.transcript = ""
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        panel.view.phase = phase
    }

    // MARK: - Messages from the core

    private func handle(_ message: Message) {
        switch message.type {
        case "hello":
            ready = message.ready ?? [:]
            if !(ready["voice"] ?? false) {
                show(hint: "Open Dial Settings to add your 豆包 key.", error: true)
            } else if !(ready["jev"] ?? false) {
                show(hint: "Ready. Without a Jev key, a few plain rules tell commands from text.")
            } else {
                show(hint: "Ready.")
            }
        case "ring":
            ring = message.ring ?? []
            refreshRing()
        case "state":
            guard let phase = Phase(rawValue: message.phase ?? "") else { return }
            switch phase {
            case .listening:
                coreListening = true
                let pending = pendingAudio
                pendingAudio = []
                for chunk in pending { sendAudio(chunk) }
                // The mic may have been stopped already (a quick click).
                if self.phase == .listening && !mic.running {
                    core.send(Message(type: "stop"))
                    setPhase(.thinking)
                }
            case .idle:
                coreListening = false
                if mic.running { mic.stop() }
                setPhase(.idle)
            case .thinking:
                coreListening = false
                setPhase(.thinking)
            }
        case "heard":
            panel.view.transcript = message.text ?? ""
        case "result":
            act(on: message)
        case "error":
            Log.write("core error: \(message.message ?? "")")
            mic.stop()
            pendingAudio = []
            setPhase(.idle)
            show(hint: message.message ?? "Something went wrong.", error: true)
        default:
            break
        }
    }

    private func act(on result: Message) {
        Log.write("result: \(result.intent ?? "?") \(result.action ?? "") \(result.appName ?? "") «\(result.transcript ?? "")»")
        let transcript = result.transcript ?? ""
        if result.intent != "command" {
            let text = result.text ?? transcript
            if text.isEmpty {
                show(hint: "Didn't hear anything.")
            } else {
                Input.type(text)
                show(hint: text)
            }
            return
        }
        switch Action(rawValue: result.action ?? "none") ?? .none {
        case .switchApp, .openApp:
            guard let id = result.app else {
                show(hint: result.message ?? "Which app?", error: true)
                return
            }
            apps.activate(id: id)
            learned(id)
            show(hint: "→ \(result.appName ?? id)")
        case .scrollUp:
            Input.scroll(lines: 10)
            show(hint: "↑ scroll")
        case .scrollDown:
            Input.scroll(lines: -10)
            show(hint: "↓ scroll")
        case .pageTop:
            Input.pageTop()
            show(hint: "⤒ top")
        case .pageBottom:
            Input.pageBottom()
            show(hint: "⤓ bottom")
        case .closeWindow:
            Input.closeWindow()
            show(hint: "⌘W")
        case .none:
            show(hint: result.message ?? "That sounded like a command the dial doesn't know.", error: true)
        }
    }

    // MARK: - Hints and the menu

    func show(hint: String, error: Bool = false) {
        panel.view.hint = hint
        panel.view.hintIsError = error
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: error ? 8 : 4, repeats: false) { [weak self] _ in
            self?.panel.view.hint = nil
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MenuBarIcon.make()
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Listen", action: #selector(menuListen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Dial", action: #selector(menuShow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Grant Accessibility…", action: #selector(menuAccessibility), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dial", action: #selector(menuQuit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func menuListen() { toggleListening() }

    /// Asks again, and opens the pane: a rebuilt ad-hoc build is a new
    /// app to macOS, and its old entry there no longer counts.
    @objc private func menuAccessibility() {
        if Input.trusted(prompt: true) {
            show(hint: "Accessibility is allowed.")
            armKeys(prompt: false)
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        show(hint: "If Dial is already on the list, remove it with − and add dist/Dial.app again.", error: true)
    }
    @objc private func menuShow() { panel.show() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    /// Dial Settings.app next to this app or in Applications; else the
    /// config file itself.
    @objc private func menuSettings() {
        let beside = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Dial Settings.app")
        for url in [beside, URL(fileURLWithPath: "/Applications/Dial Settings.app")]
        where FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let config = URL(fileURLWithPath: NSHomeDirectory() + "/.config/dial/config.json")
        if FileManager.default.fileExists(atPath: config.path) {
            NSWorkspace.shared.open(config)
        } else {
            show(hint: "Build Dial Settings with make settings, or run dial-core once to create the config.", error: true)
        }
    }
}
