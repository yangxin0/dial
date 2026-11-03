import CoreGraphics
import Foundation

/// How the dial looks: its size, how see-through it is, and what the ring shows
/// as it turns. The ring's maths
/// don't change with size: the view scales its drawing and its events alike.
public struct DialTheme: Equatable, Codable {
    public static let minSize: CGFloat = 0.5
    public static let maxSize: CGFloat = 3
    public static let maxTransparency: CGFloat = 0.8

    /// 1 is the normal size.
    public var size: CGFloat
    /// 0 is solid. Never fully see-through, so it can't be lost on screen.
    public var transparency: CGFloat
    public var ringStyle: RingStyle

    public init(size: CGFloat = 1, transparency: CGFloat = 0, ringStyle: RingStyle = .ticksAndDimple) {
        self.size = min(max(size, Self.minSize), Self.maxSize)
        self.transparency = min(max(transparency, 0), Self.maxTransparency)
        self.ringStyle = ringStyle
    }

    enum CodingKeys: String, CodingKey {
        case size, transparency, ringStyle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(size: (try? c.decode(CGFloat.self, forKey: .size)) ?? 1,
                  transparency: (try? c.decode(CGFloat.self, forKey: .transparency)) ?? 0,
                  ringStyle: (try? c.decode(RingStyle.self, forKey: .ringStyle)) ?? .ticksAndDimple)
    }

    public var alpha: CGFloat { 1 - transparency }

    /// The size to draw at: the chosen one, unless it wouldn't fit the screen.
    public func fittedSize(in visible: CGRect) -> CGFloat {
        min(size, visible.width / DialMetrics.width, visible.height / DialMetrics.height)
    }

    /// Where the ring's centre is, for a window at this frame. Coordinates have
    /// y up, as a window's frame does.
    public static func ringCenter(ofFrame frame: CGRect) -> CGPoint {
        let scale = frame.width / DialMetrics.width
        return CGPoint(x: frame.midX, y: frame.maxY - (DialMetrics.topMargin + DialMetrics.outerRadius) * scale)
    }

    /// The window that puts the ring's centre where asked, pushed back on
    /// screen if it would run off.
    public func frame(ringCenter center: CGPoint, within visible: CGRect) -> CGRect {
        let scale = fittedSize(in: visible)
        let width = DialMetrics.width * scale, height = DialMetrics.height * scale
        let x = center.x - width / 2
        let y = center.y + (DialMetrics.topMargin + DialMetrics.outerRadius) * scale - height
        return CGRect(x: min(max(x, visible.minX), visible.maxX - width),
                      y: min(max(y, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }
}
