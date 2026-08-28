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
}
