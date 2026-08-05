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
}
