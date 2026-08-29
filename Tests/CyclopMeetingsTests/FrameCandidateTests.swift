import XCTest
@testable import CyclopMeetings

final class FrameCandidateTests: XCTestCase {
    func testParsesTimecodePriorityAndExpectation() {
        let text = "[00:30:00] 1 | консоль Yandex Cloud, список подов кластера"

        XCTAssertEqual(
            FrameCandidateParser.candidates(from: text),
            [FrameCandidate(start: 1800, expectation: "консоль Yandex Cloud, список подов кластера", priority: 1)]
        )
    }

    /// The model adds an introductory sentence about as often as it does not.
    func testSkipsLinesWithoutTimecode() {
        let text = """
            Вот моменты, где нужен кадр:
            [00:07:55] 2 | схема C4 в PlantUML
            """

        XCTAssertEqual(FrameCandidateParser.candidates(from: text).count, 1)
    }

    /// A missing priority is not worth losing the candidate over.
    func testDefaultsPriorityToLowestWhenAbsent() {
        let candidates = FrameCandidateParser.candidates(from: "[00:01:00] | что-то на экране")

        XCTAssertEqual(candidates.first?.priority, 3)
    }

    func testSkipsCandidateWithEmptyExpectation() {
        XCTAssertTrue(FrameCandidateParser.candidates(from: "[00:01:00] 1 | ").isEmpty)
    }

    /// The model writes timecodes in bold about as often as it does not, and
    /// the sibling parsers in this module already allow it.
    func testAcceptsBoldTimecode() {
        let candidates = FrameCandidateParser.candidates(from: "**[00:07:55]** 2 | схема C4")

        XCTAssertEqual(candidates.first?.start, 475)
        XCTAssertEqual(candidates.first?.expectation, "схема C4")
    }

    func testPromptAsksForTwiceTheBudget() {
        let prompt = MeetingPrompts.frameCandidates(for: "лента", budget: 15)

        XCTAssertTrue(prompt.contains("30"))
        XCTAssertTrue(prompt.contains("лента"))
    }
}
