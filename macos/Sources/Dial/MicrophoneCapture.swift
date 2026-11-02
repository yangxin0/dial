import AVFoundation

/// Records the default microphone as 16 kHz, 16-bit mono PCM and hands it
/// on in 200 ms chunks, the size the speech endpoint works best with, on
/// the main queue.
final class MicrophoneCapture {
    static let chunkBytes = 6400

    enum Failure: Error {
        case noInput
    }

    var onChunk: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1,
                                       interleaved: true)!
    private var pending = Data()
    private(set) var running = false

    /// Asks for the microphone the first time; `done` runs on the main queue.
    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default:
            done(false)
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: target) else { throw Failure.noInput }
        let target = self.target
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / format.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
            let data = Data(bytes: samples[0], count: Int(out.frameLength) * 2)
            DispatchQueue.main.async { self?.append(data) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    private func append(_ data: Data) {
        guard running else { return }
        pending.append(data)
        while pending.count >= Self.chunkBytes {
            onChunk?(Data(pending.prefix(Self.chunkBytes)))
            pending.removeFirst(Self.chunkBytes)
        }
    }

    /// Stops recording; returns what is left short of a chunk.
    @discardableResult
    func stop() -> Data {
        guard running else { return Data() }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        defer { pending = Data() }
        return pending
    }
}
