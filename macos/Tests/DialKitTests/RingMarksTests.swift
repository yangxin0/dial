import CoreGraphics
import XCTest
@testable import DialKit

final class RingMarksTests: XCTestCase {
    private let ring = RingGeometry(center: CGPoint(x: 100, y: 100))

    private func angle(_ point: CGPoint) -> CGFloat { atan2(point.y - 100, point.x - 100) }
    private func radius(_ point: CGPoint) -> CGFloat { hypot(point.x - 100, point.y - 100) }

    func testEachTickIsOneScrollLine() {
        let ticks = ring.ticks(turn: 0)
        XCTAssertEqual(ticks.count, RingMarks.tickCount)
        let step = TurnCounter.delta(from: angle(ticks[0].to), to: angle(ticks[1].to))
        XCTAssertEqual(step, TurnCounter.radiansPerLine, accuracy: 0.0001)
    }

    func testMajorTicksStandOutEveryThirtyDegrees() {
        let ticks = ring.ticks(turn: 0)
        XCTAssertEqual(ticks.filter(\.major).count, 12)
        XCTAssertTrue(ticks[0].major)
        XCTAssertFalse(ticks[1].major)
        XCTAssertLessThan(radius(ticks[0].from), radius(ticks[1].from))
    }

    func testMarksStayOnTheRingBesideTheButton() {
        for mark in ring.ticks(turn: 1) + ring.spokes(turn: 1) {
            for end in [mark.from, mark.to] {
                XCTAssertEqual(ring.zone(at: end), .ring)
            }
        }
        let dimple = ring.dimple(turn: 1)
        XCTAssertLessThanOrEqual(radius(dimple) + RingMarks.dimpleRadius, DialMetrics.outerRadius)
        XCTAssertGreaterThanOrEqual(radius(dimple) - RingMarks.dimpleRadius, DialMetrics.buttonRadius)
    }

    func testMarksTurnWithTheDrag() {
        let turn: CGFloat = 0.4
        XCTAssertEqual(TurnCounter.delta(from: angle(ring.ticks(turn: 0)[0].to), to: angle(ring.ticks(turn: turn)[0].to)), turn, accuracy: 0.0001)
        XCTAssertEqual(TurnCounter.delta(from: angle(ring.spokes(turn: 0)[0].to), to: angle(ring.spokes(turn: turn)[0].to)), turn, accuracy: 0.0001)
        XCTAssertEqual(TurnCounter.delta(from: angle(ring.dimple(turn: 0)), to: angle(ring.dimple(turn: turn))), turn, accuracy: 0.0001)
    }

    func testEachStyleShowsSomething() {
        for style in RingStyle.allCases {
            XCTAssertTrue(style.hasTicks || style.hasDimple || style.hasSpokes || style.hasTrail, "\(style)")
        }
    }

    func testTheTrailFadesWithAge() {
        var trail = RingTrail()
        XCTAssertTrue(trail.segments(now: 0).isEmpty)
        trail.add(angle: 0, at: 10)
        XCTAssertTrue(trail.segments(now: 10).isEmpty, "one point is no arc")
        trail.add(angle: 0.1, at: 10)
        trail.add(angle: 0.2, at: 10.25)
        let young = trail.segments(now: 10.25)
        XCTAssertEqual(young.map(\.to), [0.1, 0.2])
        XCTAssertLessThan(young[0].alpha, young[1].alpha)
        XCTAssertEqual(young[1].alpha, 1, accuracy: 0.0001)
        XCTAssertEqual(trail.segments(now: 10.5).map(\.to), [0.2])
        XCTAssertTrue(trail.segments(now: 11).isEmpty)
    }

    func testAFadedTrailIsForgotten() {
        var trail = RingTrail()
        trail.add(angle: 0, at: 10)
        trail.add(angle: 0.1, at: 10.1)
        trail.add(angle: 0.2, at: 10.4)
        trail.prune(now: 10.55)
        XCTAssertEqual(trail.segments(now: 10.55).map(\.to), [0.1, 0.2], "the piece still fading stays")
        trail.prune(now: 10.65)
        XCTAssertEqual(trail.segments(now: 10.65).map(\.to), [0.2])
        trail.prune(now: 20)
        XCTAssertTrue(trail.isEmpty)
    }
}
