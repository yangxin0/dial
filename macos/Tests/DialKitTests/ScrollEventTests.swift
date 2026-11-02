import CoreGraphics
import XCTest
@testable import DialKit

/// The wheel depends on undocumented macOS details. These run in CI, so a
/// new macOS that drops or changes them fails here first. Delivery itself
/// needs a screen and permissions: that is `make test-scroll`.
final class ScrollEventTests: XCTestCase {
    private let target = ScrollEvent.Target(pid: 4242, windowID: 777,
                                            bounds: CGRect(x: 300, y: 80, width: 900, height: 600))

    func testThisMacOSStillHasThePrivateCall() {
        XCTAssertTrue(ScrollEvent.isAvailable, "CGEventSetWindowLocation is gone: the ring can't scroll anything")
    }

    func testTheEventIsAWheelOfTheRightSize() throws {
        let event = try XCTUnwrap(ScrollEvent.make(lines: 3, for: target))
        XCTAssertEqual(event.type, .scrollWheel)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 0)
        let down = try XCTUnwrap(ScrollEvent.make(lines: -2, for: target))
        XCTAssertEqual(down.getIntegerValueField(.scrollWheelEventDeltaAxis1), -2)
    }

    func testTheEventCarriesTheWindowNumberInField51() throws {
        let event = try XCTUnwrap(ScrollEvent.make(lines: 1, for: target))
        XCTAssertEqual(event.getIntegerValueField(ScrollEvent.windowNumberField), 777)
    }

    func testFields91And92AreNotWhatDeliversIt() throws {
        // The wrong fields cost hours once: they do nothing. Keep them unset,
        // so nobody mistakes them for part of the recipe.
        let event = try XCTUnwrap(ScrollEvent.make(lines: 1, for: target))
        XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointer), 0)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent), 0)
    }

    func testTheEventIsAimedAtTheWindowsMiddleOnScreen() throws {
        let event = try XCTUnwrap(ScrollEvent.make(lines: 1, for: target))
        XCTAssertEqual(event.location.x, 750, accuracy: 0.5)
        XCTAssertEqual(event.location.y, 380, accuracy: 0.5)
    }

    func testThePositionIsWindowLocalNotScreen() throws {
        let event = try XCTUnwrap(ScrollEvent.make(lines: 1, for: target))
        let local = try XCTUnwrap(ScrollEvent.windowLocation(of: event), "can't read the window location on this macOS")
        XCTAssertEqual(local.x, 450, accuracy: 0.5, "must be the window's middle, not its place on screen")
        XCTAssertEqual(local.y, 300, accuracy: 0.5)
    }
}
