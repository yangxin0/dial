import Foundation

/// One message of the dial ↔ core protocol: JSON, one object per line.
/// Which fields are set depends on `type` (core/protocol/protocol.go).
struct Message: Codable {
    var type: String
    var platform: String?
    var version: String?
    var ready: [String: Bool]?
    var apps: [AppRecord]?
    var ring: [String]?
    var pcm: String?
    var text: String?
    var final: Bool?
    var transcript: String?
    var intent: String?
    var action: String?
    var app: String?
    var appName: String?
    var confidence: Double?
    var source: String?
    var phase: String?
    var message: String?

    init(type: String) {
        self.type = type
    }
}

struct AppRecord: Codable {
    var id: String
    var name: String
    var running: Bool
    var active: Bool?
}

enum Phase: String {
    case idle, listening, thinking
}

enum Action: String {
    case none, switchApp = "switch_app", openApp = "open_app"
    case scrollUp = "scroll_up", scrollDown = "scroll_down"
    case pageTop = "page_top", pageBottom = "page_bottom"
    case closeWindow = "close_window"
}

let defaultCorePort: UInt16 = 47831
