import Foundation

/// A plain log file, ~/Library/Logs/Dial/dial.log, for what the dial did
/// and when: the unified log hides an app's messages from a terminal.
enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Dial/dial.log")
    private static let queue = DispatchQueue(label: "com.yangxin.dial.log")
    private static var handle: FileHandle?
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            if handle == nil {
                let dir = url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1 << 20 {
                    try? FileManager.default.removeItem(at: url)
                }
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                handle?.seekToEndOfFile()
            }
            handle?.write(line.data(using: .utf8)!)
        }
    }
}
