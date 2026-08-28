import XCTest
@testable import CyclopMeetings

final class SpeakerResolutionTests: XCTestCase {
    func testParsesResolution() {
        let answer = "Участник 2 = Александр Трофимов | высокая | 01:40 «Меня зовут Александр»"

        XCTAssertEqual(
            SpeakerResolutionParser.resolutions(from: answer),
            [SpeakerResolution(
                label: "Участник 2", name: "Александр Трофимов", confidence: .high,
                evidence: "01:40 «Меня зовут Александр»", splitAt: nil, splitName: nil)]
        )
    }

    func testParsesSplitInstruction() {
        let answer = "Участник 1 = Роман Ястребов | средняя | организует запись | split 00:55:00 Антон Копытин"

        let resolution = SpeakerResolutionParser.resolutions(from: answer).first

        XCTAssertEqual(resolution?.splitAt, 3300)
        XCTAssertEqual(resolution?.splitName, "Антон Копытин")
    }

    func testRenamesSegments() {
        let segments = [
            TranscriptSegment(start: 0, speaker: "Участник 2", text: "раз"),
            TranscriptSegment(start: 10, speaker: "Участник 3", text: "два"),
        ]
        let resolutions = [SpeakerResolution(
            label: "Участник 2", name: "Александр", confidence: .high,
            evidence: "", splitAt: nil, splitName: nil)]

        let renamed = SpeakerRelabeler.apply(resolutions, to: segments)

        XCTAssertEqual(renamed.map(\.speaker), ["Александр", "Участник 3"])
    }

    /// The whole point of the split: everything before the boundary is one
    /// person, everything after is another.
    func testSplitsGluedLabelAtBoundary() {
        let segments = [
            TranscriptSegment(start: 10, speaker: "Участник 1", text: "раз"),
            TranscriptSegment(start: 3400, speaker: "Участник 1", text: "два"),
        ]
        let resolutions = [SpeakerResolution(
            label: "Участник 1", name: "Роман", confidence: .medium,
            evidence: "", splitAt: 3300, splitName: "Антон")]

        XCTAssertEqual(
            SpeakerRelabeler.apply(resolutions, to: segments).map(\.speaker), ["Роман", "Антон"])
    }

    /// Two labels resolved to one name is how a torn-apart person gets sewn
    /// back together — no special case needed, both simply get the same name.
    func testTwoLabelsCanShareOneName() {
        let segments = [
            TranscriptSegment(start: 0, speaker: "Участник 5", text: "раз"),
            TranscriptSegment(start: 10, speaker: "Участник 1", text: "два"),
        ]
        let resolutions = [
            SpeakerResolution(label: "Участник 5", name: "Антон", confidence: .high,
                              evidence: "", splitAt: nil, splitName: nil),
            SpeakerResolution(label: "Участник 1", name: "Антон", confidence: .high,
                              evidence: "", splitAt: nil, splitName: nil),
        ]

        XCTAssertEqual(SpeakerRelabeler.apply(resolutions, to: segments).map(\.speaker),
                       ["Антон", "Антон"])
    }

    func testUnresolvedLabelSurvivesUntouched() {
        let segments = [TranscriptSegment(start: 0, speaker: "Участник 9", text: "раз")]

        XCTAssertEqual(SpeakerRelabeler.apply([], to: segments), segments)
    }

    /// The reference case from the spec, with its real numbers. On the audit
    /// call of 24.08.2026 the model tore the architect in two — label 5 ended
    /// at 54:59, label 1 picked up at 55:00 — and glued the person who opened
    /// the call into that same label 1. Both fixes have to hold at once:
    /// everything before the boundary is one person, everything after is the
    /// architect, and the other label is the architect too.
    func testReferenceMeetingIsRepaired() {
        let segments = [
            TranscriptSegment(start: 37, speaker: "Участник 1", text: "Саш, транскрибатор включишь?"),
            TranscriptSegment(start: 3299, speaker: "Участник 5", text: "Вот."),
            TranscriptSegment(start: 3300, speaker: "Участник 1", text: "Итог по каждому проекту."),
            TranscriptSegment(start: 4441, speaker: "Участник 1", text: "Я вам всё показал."),
        ]
        let resolutions = [
            SpeakerResolution(label: "Участник 5", name: "Антон Копытин", confidence: .high,
                              evidence: "плитка в кадре 30:00", splitAt: nil, splitName: nil),
            SpeakerResolution(label: "Участник 1", name: "Роман Ястребов", confidence: .medium,
                              evidence: "00:37 организует запись",
                              splitAt: 3300, splitName: "Антон Копытин"),
        ]

        XCTAssertEqual(
            SpeakerRelabeler.apply(resolutions, to: segments).map(\.speaker),
            ["Роман Ястребов", "Антон Копытин", "Антон Копытин", "Антон Копытин"]
        )
    }

    /// The evidence is a quote from the meeting and may contain the separator
    /// itself. Losing the whole resolution over it costs the name too.
    func testEvidenceKeepsItsOwnSeparators() {
        let answer = "Участник 2 = Иван | высокая | сказал «путь A | B» на 05:00"

        let resolution = SpeakerResolutionParser.resolutions(from: answer).first

        XCTAssertEqual(resolution?.name, "Иван")
        XCTAssertEqual(resolution?.evidence, "сказал «путь A | B» на 05:00")
    }

    /// The model writes whole lines in bold. A trailing pair used to end up
    /// inside the split name, and from there in the transcript itself.
    func testBoldMarkersAreStrippedFromBothEnds() {
        let answer = "**Участник 1 = Роман | средняя | ведёт запись | split 00:55:00 Антон Копытин**"

        let resolution = SpeakerResolutionParser.resolutions(from: answer).first

        XCTAssertEqual(resolution?.label, "Участник 1")
        XCTAssertEqual(resolution?.splitName, "Антон Копытин")
    }

    /// A split with no name cannot be acted on, but the name and confidence on
    /// the same line still can.
    func testSplitWithoutNameKeepsTheRestOfTheLine() {
        let answer = "Участник 3 = Пётр | низкая | догадка | split 00:10:00"

        let resolution = SpeakerResolutionParser.resolutions(from: answer).first

        XCTAssertEqual(resolution?.name, "Пётр")
        XCTAssertEqual(resolution?.evidence, "догадка")
        XCTAssertNil(resolution?.splitAt)
        XCTAssertNil(resolution?.splitName)
    }
}
