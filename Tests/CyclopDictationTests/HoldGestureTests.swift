import XCTest
@testable import CyclopDictation

final class HoldGestureTests: XCTestCase {
    func testShortTapIsIgnored() {
        var gesture = HoldGesture(minimumHold: 0.25)
        XCTAssertTrue(gesture.press(at: 100))
        guard case .ignoredTap = gesture.release(at: 100.1) else {
            return XCTFail("нажатие короче порога должно игнорироваться")
        }
    }

    func testHeldPressIsRecorded() {
        var gesture = HoldGesture(minimumHold: 0.25)
        _ = gesture.press(at: 100)
        guard case .recorded(let held) = gesture.release(at: 103) else {
            return XCTFail("удержание должно давать запись")
        }
        XCTAssertEqual(held, 3, accuracy: 0.001)
    }

    func testSecondPressWhileHeldIsRejected() {
        var gesture = HoldGesture(minimumHold: 0.25)
        XCTAssertTrue(gesture.press(at: 100))
        XCTAssertFalse(gesture.press(at: 100.5), "автоповтор не должен начинать вторую запись")
    }

    func testReleaseWithoutPressIsIgnored() {
        var gesture = HoldGesture(minimumHold: 0.25)
        guard case .ignoredTap = gesture.release(at: 100) else {
            return XCTFail("отпускание без нажатия ничего не значит")
        }
    }

    func testRightOptionDownDetection() {
        let rightOptionMask: UInt64 = 0x40 // NX_DEVICERALTKEYMASK
        let leftOptionMask: UInt64 = 0x20  // NX_DEVICELALTKEYMASK

        // Right Option only
        XCTAssertTrue(HoldGesture.isRightOptionDown(rawFlags: rightOptionMask))

        // Left Option only
        XCTAssertFalse(HoldGesture.isRightOptionDown(rawFlags: leftOptionMask))

        // Both Options (user holding left while pressing right)
        XCTAssertTrue(HoldGesture.isRightOptionDown(rawFlags: rightOptionMask | leftOptionMask))

        // Neither
        XCTAssertFalse(HoldGesture.isRightOptionDown(rawFlags: 0))
    }

    func testBugScenario_LeftOptionHeldWhileRightToggled() {
        // This test catches the original bug: if we used maskAlternate (generic bit),
        // releasing right Option while left is held would incorrectly report it as still down.
        let leftOptionMask: UInt64 = 0x20
        let rightOptionMask: UInt64 = 0x40
        let bothMask = leftOptionMask | rightOptionMask

        // User holds left Option and presses right
        XCTAssertTrue(HoldGesture.isRightOptionDown(rawFlags: bothMask),
                      "Right Option should be detected as down, even with left held")

        // User releases right Option (left still held)
        // With the buggy maskAlternate logic, this would still read as "down"
        // With the correct device-specific mask, it correctly reads as "not down"
        XCTAssertFalse(HoldGesture.isRightOptionDown(rawFlags: leftOptionMask),
                       "Right Option should be detected as up, even with left held")
    }
}
