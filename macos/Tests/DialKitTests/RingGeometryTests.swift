import CoreGraphics
import XCTest
@testable import DialKit

final class RingGeometryTests: XCTestCase {
    private let ring = RingGeometry(center: CGPoint(x: 100, y: 146))
    private let slotRadius = DialMetrics.slotRadius

    private func point(degrees: CGFloat, radius: CGFloat) -> CGPoint {
        let r = degrees * .pi / 180
        return CGPoint(x: ring.center.x + radius * cos(r), y: ring.center.y + radius * sin(r))
    }

    func testZones() {
        let edge: CGFloat = 0.01   // either side of a boundary, clear of rounding
        XCTAssertEqual(ring.zone(at: ring.center), .button)
        XCTAssertEqual(ring.zone(at: point(degrees: 30, radius: DialMetrics.buttonRadius - edge)), .button)
        XCTAssertEqual(ring.zone(at: point(degrees: 30, radius: DialMetrics.buttonRadius + edge)), .ring)
        XCTAssertEqual(ring.zone(at: point(degrees: 30, radius: DialMetrics.outerRadius - edge)), .ring)
        XCTAssertEqual(ring.zone(at: point(degrees: 30, radius: DialMetrics.outerRadius + edge)), .none)
    }

    func testSlotsSitMidBandAndClockwiseFromTheTop() {
        let top = ring.slotCenter(0, of: 4, rotation: 0)
        XCTAssertEqual(top.x, ring.center.x, accuracy: 0.001)
        XCTAssertEqual(top.y, ring.center.y + slotRadius, accuracy: 0.001)
        // The next slot is to the right: clockwise.
        let next = ring.slotCenter(1, of: 4, rotation: 0)
        XCTAssertEqual(next.x, ring.center.x + slotRadius, accuracy: 0.001)
        XCTAssertEqual(next.y, ring.center.y, accuracy: 0.001)
        XCTAssertEqual(slotRadius, (DialMetrics.outerRadius + DialMetrics.buttonRadius) / 2)
    }

    func testAClickOnASlotFindsThatSlotAtAnyRotation() {
        for count in 1...DialMetrics.maxSlots {
            for rotation in stride(from: CGFloat(-7), through: 7, by: 0.37) {
                for index in 0..<count {
                    let at = ring.slotCenter(index, of: count, rotation: rotation)
                    XCTAssertEqual(ring.slot(at: at, count: count, rotation: rotation), index,
                                   "slot \(index) of \(count) at rotation \(rotation)")
                }
            }
        }
    }

    func testAClickOnAnIconFindsItAtAnyRotation() {
        for count in 1...DialMetrics.maxSlots {
            for rotation in stride(from: -7.0, through: 7.0, by: 0.7) {
                for index in 0..<count {
                    let at = ring.slotCenter(index, of: count, rotation: CGFloat(rotation))
                    // Its centre, and just inside its edge on every side.
                    XCTAssertEqual(ring.icon(at: at, count: count, rotation: CGFloat(rotation)), index)
                    for side in stride(from: 0.0, to: 2 * Double.pi, by: .pi / 4) {
                        let near = CGPoint(x: at.x + (DialMetrics.iconHitRadius - 1) * cos(side), y: at.y + (DialMetrics.iconHitRadius - 1) * sin(side))
                        if ring.zone(at: near) == .ring {
                            XCTAssertEqual(ring.icon(at: near, count: count, rotation: CGFloat(rotation)), index,
                                           "slot \(index) of \(count), rotation \(rotation), side \(side)")
                        }
                    }
                }
            }
        }
    }

    func testBetweenIconsIsNoIconEvenOnAFullRing() {
        for count in 2...DialMetrics.maxSlots {
            let gap = 360 / Double(count) / 2
            XCTAssertNil(ring.icon(at: point(degrees: 90 - gap, radius: slotRadius), count: count, rotation: 0), "\(count) icons")
        }
    }

    func testTheRingOutsideAnIconIsNoIcon() {
        // On the ring still, right over the icon's centre line, but past its reach.
        let few = 3
        let at = ring.slotCenter(0, of: few, rotation: 0)
        let rim = CGPoint(x: at.x, y: at.y + DialMetrics.iconHitRadius + 1)
        XCTAssertEqual(ring.zone(at: rim), .ring)
        XCTAssertEqual(ring.slot(at: rim, count: few, rotation: 0), 0)
        XCTAssertNil(ring.icon(at: rim, count: few, rotation: 0))
        XCTAssertNil(ring.icon(at: ring.center, count: few, rotation: 0))
        XCTAssertNil(ring.icon(at: point(degrees: 90, radius: DialMetrics.outerRadius + 5), count: few, rotation: 0))
        XCTAssertNil(ring.icon(at: point(degrees: 0, radius: slotRadius), count: 0, rotation: 0))
    }

    func testOffTheRingIsNoSlot() {
        XCTAssertNil(ring.slot(at: ring.center, count: 8, rotation: 0))
        XCTAssertNil(ring.slot(at: point(degrees: 0, radius: DialMetrics.outerRadius + 5), count: 8, rotation: 0))
        XCTAssertNil(ring.slot(at: point(degrees: 0, radius: slotRadius), count: 0, rotation: 0))
    }

    func testRotationPutsTheSlotAtTheTopTheShortWay() {
        for count in 1...DialMetrics.maxSlots {
            for current in stride(from: CGFloat(-9), through: 9, by: 0.61) {
                for index in 0..<count {
                    let rotation = RingGeometry.rotation(puttingSlot: index, of: count, atTopNear: current)
                    XCTAssertLessThanOrEqual(abs(rotation - current), .pi + 0.0001)
                    let at = ring.slotCenter(index, of: count, rotation: rotation)
                    XCTAssertEqual(at.x, ring.center.x, accuracy: 0.001)
                    XCTAssertEqual(at.y, ring.center.y + slotRadius, accuracy: 0.001)
                }
            }
        }
    }

    func testTheCentreHasNoMeaningfulAngle() {
        XCTAssertFalse(ring.hasMeaningfulAngle(at: ring.center))
        XCTAssertFalse(ring.hasMeaningfulAngle(at: point(degrees: 45, radius: RingGeometry.deadZoneRadius)))
        XCTAssertTrue(ring.hasMeaningfulAngle(at: point(degrees: 45, radius: RingGeometry.deadZoneRadius + 1)))
    }
}

final class TurnCounterTests: XCTestCase {
    /// Turns from one angle to another in small steps, as a drag does.
    private func lines(from: CGFloat, by turn: CGFloat, steps: Int = 180) -> Int {
        var counter = TurnCounter(startAngle: from)
        var total = 0
        for i in 1...steps {
            total += counter.move(to: from + turn * CGFloat(i) / CGFloat(steps)).lines
        }
        return total
    }

    func testAHalfTurnScrollsThirtySixLines() {
        XCTAssertEqual(lines(from: .pi / 2, by: -.pi), -36)   // clockwise
        XCTAssertEqual(lines(from: -.pi / 2, by: .pi), 36)    // counterclockwise
    }

    func testAFullTurnScrollsSeventyTwoLines() {
        XCTAssertEqual(lines(from: 0, by: 2 * .pi), 72)
        XCTAssertEqual(lines(from: 0, by: -2 * .pi), -72)
    }

    func testClockwiseIsNegativeSoItScrollsDown() {
        var counter = TurnCounter(startAngle: 0)
        XCTAssertLessThan(counter.move(to: -.pi / 6).lines, 0)
        counter = TurnCounter(startAngle: 0)
        XCTAssertGreaterThan(counter.move(to: .pi / 6).lines, 0)
    }

    func testCrossingTheWrapIsASmallStepNotABurst() {
        // Just past π to just before -π: a real small turn, in raw atan2 values.
        XCTAssertEqual(TurnCounter.delta(from: 3.1, to: -3.1), 2 * .pi - 6.2, accuracy: 0.0001)
        XCTAssertEqual(TurnCounter.delta(from: -3.1, to: 3.1), 6.2 - 2 * .pi, accuracy: 0.0001)
        var counter = TurnCounter(startAngle: 3.1)
        XCTAssertLessThanOrEqual(abs(counter.move(to: -3.1).lines), 1)
    }

    func testARealDragAcrossTheWrapStaysSteady() {
        // Raw atan2 angles, wrapped as a view reports them, clockwise past the left.
        var counter = TurnCounter(startAngle: 2.5)
        var total = 0
        var worst = 0
        for i in 1...100 {
            let raw = atan2(sin(2.5 + 0.02 * CGFloat(i)), cos(2.5 + 0.02 * CGFloat(i)))
            let lines = counter.move(to: raw).lines
            total += lines
            worst = max(worst, abs(lines))
        }
        XCTAssertLessThanOrEqual(worst, 1, "a step must never burst")
        XCTAssertEqual(total, Int((2.0 / TurnCounter.radiansPerLine).rounded(.down)))
    }

    func testJitterScrollsNothing() {
        var counter = TurnCounter(startAngle: 1)
        for i in 0..<100 {
            XCTAssertEqual(counter.move(to: 1 + (i % 2 == 0 ? 0.01 : -0.01)).lines, 0)
        }
    }

    func testNoLinesAreLostToRounding() {
        var counter = TurnCounter(startAngle: 0)
        var total = 0
        // 1000 tiny steps, each far below one line.
        for i in 1...1000 { total += counter.move(to: CGFloat(i) * 0.002).lines }
        XCTAssertEqual(total, Int((2.0 / TurnCounter.radiansPerLine).rounded(.down)))
    }

    func testTheDeltaFollowsThePointerExactly() {
        var counter = TurnCounter(startAngle: 0)
        XCTAssertEqual(counter.move(to: 0.3).delta, 0.3, accuracy: 0.0001)
        XCTAssertEqual(counter.move(to: 0.1).delta, -0.2, accuracy: 0.0001)
    }
}
