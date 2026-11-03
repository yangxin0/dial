import CoreGraphics
import XCTest
@testable import DialKit

final class DialThemeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1050)

    func testValuesAreKeptInRange() {
        XCTAssertEqual(DialTheme(size: 0.1).size, DialTheme.minSize)
        XCTAssertEqual(DialTheme(size: 99).size, DialTheme.maxSize)
        XCTAssertEqual(DialTheme(transparency: -1).transparency, 0)
        XCTAssertEqual(DialTheme(transparency: 1).transparency, DialTheme.maxTransparency)
        XCTAssertEqual(DialTheme(transparency: 1).alpha, 1 - DialTheme.maxTransparency, accuracy: 0.0001)
    }

    func testItDecodesWhatTheCoreSends() throws {
        let theme = try JSONDecoder().decode(DialTheme.self, from: Data(#"{"size":1.5,"transparency":0.25}"#.utf8))
        XCTAssertEqual(theme, DialTheme(size: 1.5, transparency: 0.25))
    }

    func testMissingOrWrongValuesFallBackAndBadOnesAreClamped() throws {
        XCTAssertEqual(try JSONDecoder().decode(DialTheme.self, from: Data("{}".utf8)), DialTheme())
        XCTAssertEqual(try JSONDecoder().decode(DialTheme.self, from: Data(#"{"size":"big"}"#.utf8)), DialTheme())
        XCTAssertEqual(try JSONDecoder().decode(DialTheme.self, from: Data(#"{"size":50,"transparency":5}"#.utf8)),
                       DialTheme(size: DialTheme.maxSize, transparency: DialTheme.maxTransparency))
    }

    func testItDecodesEveryRingStyleTheCoreSends() throws {
        for (name, style) in [("ticksAndDimple", RingStyle.ticksAndDimple), ("ticks", .ticks), ("dimple", .dimple), ("spokes", .spokes), ("trail", .trail)] {
            let theme = try JSONDecoder().decode(DialTheme.self, from: Data(#"{"size":1,"ringStyle":"\#(name)"}"#.utf8))
            XCTAssertEqual(theme.ringStyle, style)
        }
    }

    func testAMissingOrUnknownRingStyleFallsBack() throws {
        XCTAssertEqual(try JSONDecoder().decode(DialTheme.self, from: Data("{}".utf8)).ringStyle, .ticksAndDimple)
        XCTAssertEqual(try JSONDecoder().decode(DialTheme.self, from: Data(#"{"ringStyle":"neon"}"#.utf8)).ringStyle, .ticksAndDimple)
    }

    func testTheRingStaysPutWhenTheSizeChanges() {
        let center = CGPoint(x: 900, y: 500)
        for size in stride(from: DialTheme.minSize, through: DialTheme.maxSize, by: 0.25) {
            let frame = DialTheme(size: size).frame(ringCenter: center, within: screen)
            XCTAssertEqual(frame.width, DialMetrics.width * size, accuracy: 0.001)
            XCTAssertEqual(frame.height, DialMetrics.height * size, accuracy: 0.001)
            let back = DialTheme.ringCenter(ofFrame: frame)
            XCTAssertEqual(back.x, center.x, accuracy: 0.001, "at size \(size)")
            XCTAssertEqual(back.y, center.y, accuracy: 0.001, "at size \(size)")
        }
    }

    func testABigDialIsPushedBackOnScreen() {
        let frame = DialTheme(size: 3).frame(ringCenter: CGPoint(x: 1900, y: 40), within: screen)
        XCTAssertTrue(screen.contains(frame), "\(frame)")
    }

    func testADialTooBigForTheScreenShrinksToFit() {
        let small = CGRect(x: 0, y: 0, width: 400, height: 900)
        let frame = DialTheme(size: 3).frame(ringCenter: CGPoint(x: 200, y: 400), within: small)
        XCTAssertEqual(frame.width, 400, accuracy: 0.001)
        XCTAssertTrue(small.insetBy(dx: -0.001, dy: -0.001).contains(frame), "\(frame)")
    }
}
