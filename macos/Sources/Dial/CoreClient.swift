import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.yangxin.dial", category: "core")

/// The connection to dial-core: starts it when nothing answers on the
/// port, reconnects when it goes away, and passes messages both ways on
/// the main queue.
final class CoreClient {
    var onMessage: ((Message) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private(set) var connected = false
    private let port: UInt16
    private var connection: NWConnection?
    private var buffer = Data()
    private var process: Process?
    private var attempts = 0
    private var stopped = false
    private let queue = DispatchQueue(label: "com.yangxin.dial.core")

    init(port: UInt16 = defaultCorePort) {
        self.port = port
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        connection?.cancel()
        connection = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    func send(_ message: Message) {
        guard connected, let connection else { return }
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                log.error("send: \(error.localizedDescription)")
            }
        })
    }

    private func connect() {
        guard !stopped else { return }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.connection = connection
        buffer = Data()
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.stateChanged(state, of: connection) }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func stateChanged(_ state: NWConnection.State, of connection: NWConnection) {
        guard connection === self.connection else { return }
        switch state {
        case .ready:
            attempts = 0
            connected = true
            log.info("connected to dial-core on port \(self.port)")
            onConnected?()
        case .waiting(let error), .failed(let error):
            log.info("core not reachable: \(error.localizedDescription)")
            dropAndRetry()
        case .cancelled:
            dropAndRetry()
        default:
            break
        }
    }

    private func dropAndRetry() {
        let was = connected
        connected = false
        connection?.cancel()
        connection = nil
        if was {
            onDisconnected?()
        }
        guard !stopped else { return }
        attempts += 1
        if attempts == 1 || (attempts % 10 == 0 && !(process?.isRunning ?? false)) {
            launchCore()
        }
        let delay = min(0.3 * Double(attempts), 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                DispatchQueue.main.async { self.consume(data) }
            }
            if isComplete || error != nil {
                DispatchQueue.main.async {
                    if connection === self.connection { self.dropAndRetry() }
                }
                return
            }
            self.receive(on: connection)
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            if let message = try? JSONDecoder().decode(Message.self, from: line) {
                onMessage?(message)
            } else {
                log.error("unreadable line from core")
            }
        }
    }

    /// dial-core sits next to this binary in the app bundle; failing that,
    /// on PATH.
    private func launchCore() {
        if let process, process.isRunning { return }
        let beside = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("dial-core")
        let process = Process()
        // The core exits by itself once this process is gone (-parent), so
        // a dial killed outright leaves no core behind.
        let parent = ["-parent", String(ProcessInfo.processInfo.processIdentifier)]
        if FileManager.default.isExecutableFile(atPath: beside.path) {
            process.executableURL = beside
            process.arguments = parent
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["dial-core"] + parent
        }
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        process.terminationHandler = { p in
            log.info("dial-core exited with \(p.terminationStatus)")
        }
        do {
            try process.run()
            self.process = process
            log.info("started dial-core at \(process.executableURL!.path)")
        } catch {
            log.error("can't start dial-core: \(error.localizedDescription)")
        }
    }
}
