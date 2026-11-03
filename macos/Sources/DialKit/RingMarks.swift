import CoreGraphics
import Foundation

/// What the ring shows as a drag turns it, so that it reads as a wheel. The
/// icons hide during a drag, and a bare disc doesn't look like it's moving.
public enum RingStyle: String, Codable, CaseIterable {
    case ticksAndDimple, ticks, dimple, spokes, trail

    public var hasTicks: Bool { self == .ticksAndDimple || self == .ticks }
    public var hasDimple: Bool { self == .ticksAndDimple || self == .dimple }
    public var hasSpokes: Bool { self == .spokes }
    public var hasTrail: Bool { self == .trail }
}

public enum RingMarks {
    /// One tick per scroll line, so each tick that passes is a line scrolled.
    public static let tickCount = 72
    /// Every sixth tick is longer: 30° apart, so a turn is easy to follow.
    public static let majorEvery = 6
    public static let spokeCount = 12
    public static let dimpleRadius: CGFloat = 5.5
    public static let trailWidth: CGFloat = 9
}

/// A short straight mark on the ring.
public struct RingMark: Equatable {
    public var from: CGPoint
    public var to: CGPoint
    public var major: Bool

    public init(from: CGPoint, to: CGPoint, major: Bool) {
        self.from = from
        self.to = to
        self.major = major
    }
}

extension RingGeometry {
    private func point(angle: CGFloat, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    /// `turn` is how far the marks have gone round, counterclockwise.
    public func ticks(turn: CGFloat) -> [RingMark] {
        (0..<RingMarks.tickCount).map { index in
            let angle = turn + CGFloat(index) * 2 * .pi / CGFloat(RingMarks.tickCount)
            let major = index % RingMarks.majorEvery == 0
            return RingMark(from: point(angle: angle, radius: DialMetrics.outerRadius - (major ? 13 : 9)),
                            to: point(angle: angle, radius: DialMetrics.outerRadius - 4), major: major)
        }
    }

    public func spokes(turn: CGFloat) -> [RingMark] {
        (0..<RingMarks.spokeCount).map { index in
            let angle = turn + CGFloat(index) * 2 * .pi / CGFloat(RingMarks.spokeCount)
            return RingMark(from: point(angle: angle, radius: DialMetrics.buttonRadius + 7),
                            to: point(angle: angle, radius: DialMetrics.outerRadius - 7), major: false)
        }
    }

    /// The dimple's centre, on the circle the icons sit on: at the top at no turn.
    public func dimple(turn: CGFloat) -> CGPoint {
        point(angle: .pi / 2 + turn, radius: DialMetrics.slotRadius)
    }

    /// A trail's piece, on the circle the icons sit on.
    public func trailPoint(angle: CGFloat) -> CGPoint {
        point(angle: angle, radius: DialMetrics.slotRadius)
    }
}

/// A fading arc behind the pointer: where it has just been.
public struct RingTrail {
    public static let lifetime: TimeInterval = 0.5

    public struct Segment: Equatable {
        public var from: CGFloat
        public var to: CGFloat
        /// 1 is new; it reaches 0 at the end of the trail's lifetime.
        public var alpha: CGFloat
    }

    private var samples: [(angle: CGFloat, time: TimeInterval)] = []

    public init() {}

    public var isEmpty: Bool { samples.isEmpty }

    public mutating func add(angle: CGFloat, at time: TimeInterval) {
        samples.append((angle, time))
    }

    public mutating func clear() {
        samples.removeAll()
    }

    /// Forgets what has faded out, keeping one sample older so that the piece
    /// joining it to the rest fades out rather than vanishes.
    public mutating func prune(now: TimeInterval) {
        guard let keep = samples.lastIndex(where: { now - $0.time >= Self.lifetime }) else { return }
        samples.removeFirst(keep)
        if samples.count == 1, now - samples[0].time >= Self.lifetime { samples.removeAll() }
    }

    public func segments(now: TimeInterval) -> [Segment] {
        guard samples.count > 1 else { return [] }
        return (1..<samples.count).compactMap { index in
            let alpha = 1 - (now - samples[index].time) / Self.lifetime
            guard alpha > 0 else { return nil }
            return Segment(from: samples[index - 1].angle, to: samples[index].angle, alpha: CGFloat(min(alpha, 1)))
        }
    }
}
