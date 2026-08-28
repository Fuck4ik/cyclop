import XCTest
@testable import CyclopMeetings

final class TranscriptDocumentTests: XCTestCase {
    private func document(
        summary: String = "Обсудили релиз.",
        segments: [TranscriptSegment] = [
            TranscriptSegment(start: 0, speaker: "Роман", text: "Начнём."),
            TranscriptSegment(start: 5, speaker: "Участник 2", text: "Логи в Grafana."),
        ],
        hasMicrophoneLane: Bool = true
    ) -> TranscriptDocument {
        TranscriptDocument(
            date: Date(timeIntervalSince1970: 1_787_000_000),
            duration: 4623,
            videoFileName: "meeting.mp4",
            summary: summary,
            segments: segments,
            hasMicrophoneLane: hasMicrophoneLane
        )
    }

    func testHeaderCarriesDurationAndVideoName() {
        let text = document().render()
        XCTAssertTrue(text.contains("**Длительность:** 01:17:03"), text)
        XCTAssertTrue(text.contains("`meeting.mp4`"), text)
    }

    /// Two trailing spaces are a Markdown hard break: without them "Длительность"
    /// and "Запись" collapse into one soft-wrapped paragraph.
    func testDurationLineKeepsItsHardBreak() {
        XCTAssertTrue(document().render().contains("01:17:03  \n"), document().render())
    }

    func testSummaryAndTranscriptSectionsArePresent() {
        let text = document().render()
        XCTAssertTrue(text.contains("## Итоги"), text)
        XCTAssertTrue(text.contains("Обсудили релиз."), text)
        XCTAssertTrue(text.contains("## Расшифровка"), text)
    }

    func testEverySegmentIsRenderedAsALine() {
        let text = document().render()
        XCTAssertTrue(text.contains("**[00:00:00] Роман:** Начнём."), text)
        XCTAssertTrue(text.contains("**[00:00:05] Участник 2:** Логи в Grafana."), text)
    }

    /// Without a microphone lane every label is the model's guess, and the
    /// reader has to know that before trusting the names.
    func testMissingMicrophoneLaneIsStated() {
        let text = document(hasMicrophoneLane: false).render()
        XCTAssertTrue(text.contains("своя дорожка не записалась"), text)
    }

    func testWorkingMicrophoneAddsNoWarning() {
        XCTAssertFalse(document().render().contains("своя дорожка не записалась"))
    }

    /// A failed summary request must not cost the transcript itself.
    func testEmptySummaryLeavesTheSectionOut() {
        let text = document(summary: "  ").render()
        XCTAssertFalse(text.contains("## Итоги"), text)
        XCTAssertTrue(text.contains("## Расшифровка"), text)
    }

    func testTranscriptionPromptAsksForTheParsedFormat() {
        XCTAssertTrue(MeetingPrompts.transcription.contains("**[ЧЧ:ММ:СС]"))
        XCTAssertTrue(MeetingPrompts.transcription.contains("Участник"))
    }

    func testSummaryPromptCarriesTheTranscript() {
        XCTAssertTrue(MeetingPrompts.summary(for: "лента встречи").contains("лента встречи"))
    }
}
