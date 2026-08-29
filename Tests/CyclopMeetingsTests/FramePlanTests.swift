import XCTest
@testable import CyclopMeetings

final class FramePlanTests: XCTestCase {
    func testBudgetIsOneFramePerFourMinutes() {
        XCTAssertEqual(FramePlan.budget(forDuration: 3600), 15)
    }

    /// A five-minute call still deserves a couple of frames, and a four-hour
    /// one must not eat the whole request quota.
    func testBudgetIsClamped() {
        XCTAssertEqual(FramePlan.budget(forDuration: 60), 3)
        XCTAssertEqual(FramePlan.budget(forDuration: 14400), 40)
    }

    func testKeepsChronologicalOrder() {
        let candidates = [
            FrameCandidate(start: 300, expectation: "б", priority: 2),
            FrameCandidate(start: 100, expectation: "а", priority: 1),
        ]

        XCTAssertEqual(FramePlan.selected(from: candidates, budget: 5).map(\.start), [100, 300])
    }

    /// Two candidates a few seconds apart are the same screen twice.
    func testMergesCandidatesCloserThanTheGap() {
        let candidates = [
            FrameCandidate(start: 100, expectation: "схема", priority: 2),
            FrameCandidate(start: 120, expectation: "та же схема", priority: 1),
        ]

        let selected = FramePlan.selected(from: candidates, budget: 5)

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.expectation, "та же схема")
    }

    func testDropsLowestPriorityWhenOverBudget() {
        let candidates = [
            FrameCandidate(start: 100, expectation: "а", priority: 3),
            FrameCandidate(start: 200, expectation: "б", priority: 1),
            FrameCandidate(start: 300, expectation: "в", priority: 2),
        ]

        XCTAssertEqual(
            FramePlan.selected(from: candidates, budget: 2).map(\.expectation), ["б", "в"])
    }

    func testEmptyInputGivesEmptyPlan() {
        XCTAssertTrue(FramePlan.selected(from: [], budget: 10).isEmpty)
    }

    /// A negative budget must not reach `.prefix`, which traps on it.
    func testNegativeBudgetGivesEmptyPlan() {
        let candidates = [FrameCandidate(start: 100, expectation: "а", priority: 1)]

        XCTAssertTrue(FramePlan.selected(from: candidates, budget: -1).isEmpty)
    }

    /// The anchor of the window is where the group started, not whoever
    /// currently represents it. Otherwise 0 / 40 / 80 — each pair inside the
    /// window — collapses into a single frame spanning eighty seconds.
    func testWindowAnchorDoesNotDriftAlongTheChain() {
        let candidates = [
            FrameCandidate(start: 0, expectation: "первый", priority: 3),
            FrameCandidate(start: 40, expectation: "второй", priority: 2),
            FrameCandidate(start: 80, expectation: "третий", priority: 1),
        ]

        let selected = FramePlan.selected(from: candidates, budget: 10)

        XCTAssertEqual(selected.map(\.start), [40, 80])
        XCTAssertEqual(selected.map(\.expectation), ["второй", "третий"])
    }
}
