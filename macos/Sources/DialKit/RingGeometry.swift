import CoreGraphics
import Foundation

/// The dial's measurements, shared by the view and the scroll test.
public enum DialMetrics {
    public static let width: CGFloat = 200
    public static let height: CGFloat = 240
    public static let topMargin: CGFloat = 8
    public static let outerRadius: CGFloat = 86
    public static let innerRadius: CGFloat = 50
    public static let buttonRadius: CGFloat = 40
    public static let maxSlots = 8
    /// Slots sit in the middle of the band the eye sees: between the
    /// button's edge and the rim.
    public static var slotRadius: CGFloat { (outerRadius + buttonRadius) / 2 }
}

/// Which part of the dial a point is on.
public enum DialZone: Equatable {
    case none, ring, button
}

/// The ring's maths, in a coordinate space with y up, as a view's.
public struct RingGeometry {
    /// Right by the centre an angle means nothing.
    public static let deadZoneRadius: CGFloat = 10

    public var center: CGPoint

    public init(center: CGPoint) {
        self.center = center
    }

    private func distance(to point: CGPoint) -> CGFloat {
        hypot(point.x - center.x, point.y - center.y)
    }

    public func zone(at point: CGPoint) -> DialZone {
        let d = distance(to: point)
        if d <= DialMetrics.buttonRadius { return .button }
        if d <= DialMetrics.outerRadius { return .ring }
        return .none
    }

    /// Counterclockwise from the right, in radians.
    public func angle(of point: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }

    public func hasMeaningfulAngle(at point: CGPoint) -> Bool {
        distance(to: point) > Self.deadZoneRadius
    }

    /// Slot 0 sits at the top plus `rotation`; the others follow clockwise.
    public func slotCenter(_ index: Int, of count: Int, rotation: CGFloat) -> CGPoint {
        let angle = CGFloat.pi / 2 - CGFloat(index) * 2 * .pi / CGFloat(count) + rotation
        return CGPoint(x: center.x + DialMetrics.slotRadius * cos(angle),
                       y: center.y + DialMetrics.slotRadius * sin(angle))
    }

    /// The slot a point on the ring belongs to; nil off the ring.
    public func slot(at point: CGPoint, count: Int, rotation: CGFloat) -> Int? {
        guard zone(at: point) == .ring, count > 0 else { return nil }
        var turns = (CGFloat.pi / 2 + rotation - angle(of: point)) / (2 * .pi)  // clockwise from the top
        turns -= turns.rounded(.down)
        return Int((turns * CGFloat(count)).rounded()) % count
    }

    /// The rotation nearest `current` that puts a slot at the top.
    public static func rotation(puttingSlot index: Int, of count: Int, atTopNear current: CGFloat) -> CGFloat {
        var target = CGFloat(index) * 2 * .pi / CGFloat(count)
        while target - current > .pi { target -= 2 * .pi }
        while target - current < -.pi { target += 2 * .pi }
        return target
    }
}

/// Follows a pointer round the ring, and says how far it turned and how
/// many lines that scrolls: positive counterclockwise, which scrolls up.
public struct TurnCounter {
    /// One line per 5 degrees.
    public static let radiansPerLine = CGFloat.pi / 36

    private var lastAngle: CGFloat
    private var accumulated: CGFloat = 0

    public init(startAngle: CGFloat) {
        lastAngle = startAngle
    }

    /// The short way from one angle to another, across the wrap at ±π.
    public static func delta(from: CGFloat, to: CGFloat) -> CGFloat {
        var delta = to - from
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return delta
    }

    public mutating func move(to angle: CGFloat) -> (delta: CGFloat, lines: Int) {
        let delta = Self.delta(from: lastAngle, to: angle)
        lastAngle = angle
        accumulated += delta
        var lines = 0
        while accumulated >= Self.radiansPerLine {
            accumulated -= Self.radiansPerLine
            lines += 1
        }
        while accumulated <= -Self.radiansPerLine {
            accumulated += Self.radiansPerLine
            lines -= 1
        }
        return (delta, lines)
    }
}
