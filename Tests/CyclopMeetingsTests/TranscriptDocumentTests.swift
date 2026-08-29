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

    /// Same hard break as the header, and for the same reason: without it the
    /// whole feed renders as one soft-wrapped paragraph. The last line carries
    /// none — nothing follows it, and the file would end in whitespace.
    func testTranscriptLinesKeepTheirHardBreaks() {
        let text = document().render()
        XCTAssertTrue(text.contains("Начнём.  \n**[00:00:05]"), text)
        XCTAssertFalse(text.contains("Логи в Grafana.  "), text)
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

    private func frameDocument(
        participants: [Participant] = [],
        notes: [ScreenNote] = [],
        skippedFrames: Int = 0,
        remarks: [String] = []
    ) -> TranscriptDocument {
        TranscriptDocument(
            date: Date(timeIntervalSince1970: 0),
            duration: 60,
            videoFileName: "meeting.mp4",
            summary: "итоги",
            segments: [
                TranscriptSegment(start: 0, speaker: "Антон", text: "вот здесь всё крутится"),
                TranscriptSegment(start: 90, speaker: "Роман", text: "понятно"),
            ],
            hasMicrophoneLane: true,
            participants: participants,
            notes: notes,
            skippedFrames: skippedFrames,
            remarks: remarks
        )
    }

    func testParticipantsTableIsRendered() {
        let rendered = frameDocument(participants: [
            Participant(name: "Антон Копытин", role: "архитектор", confidence: .high,
                        evidence: "1:14:01 «я архитектор»")
        ]).render()

        XCTAssertTrue(rendered.contains("## Участники"))
        XCTAssertTrue(rendered.contains("| Антон Копытин | архитектор | высокая |"))
        XCTAssertTrue(rendered.contains("1:14:01 «я архитектор»"))
    }

    func testNoParticipantsMeansNoSection() {
        XCTAssertFalse(frameDocument().render().contains("## Участники"))
    }

    /// The block goes after the line it belongs to, and its text goes before
    /// the picture: the file is read by models without eyes.
    func testScreenNoteIsPlacedAfterItsSegment() {
        let rendered = frameDocument(notes: [ScreenNote(
            start: 30, title: "консоль Yandex Cloud", details: "кластер ycru1-mp2",
            presenter: "Антон Копытин", uiNames: [], slug: "yc", isUseful: true)
        ]).render()

        let lines = rendered.components(separatedBy: "\n")
        let speech = lines.firstIndex { $0.contains("вот здесь всё крутится") }!
        let block = lines.firstIndex { $0.contains("консоль Yandex Cloud") }!
        let picture = lines.firstIndex { $0.contains("![") }!
        let next = lines.firstIndex { $0.contains("понятно") }!

        XCTAssertTrue(speech < block)
        XCTAssertTrue(block < picture)
        XCTAssertTrue(picture < next)
        XCTAssertTrue(rendered.contains("screens/00-30_yc.jpg"))
    }

    func testUselessNoteIsNotRendered() {
        let rendered = frameDocument(notes: [ScreenNote(
            start: 30, title: "пустой стол", details: "", presenter: nil,
            uiNames: [], slug: "x", isUseful: false)]).render()

        XCTAssertFalse(rendered.contains("пустой стол"))
    }

    /// Losing coverage silently would read as «everything was covered».
    func testSkippedFramesAreReported() {
        let rendered = frameDocument(
            notes: [ScreenNote(start: 30, title: "экран", details: "", presenter: nil,
                               uiNames: [], slug: "s", isUseful: true)],
            skippedFrames: 3
        ).render()

        XCTAssertTrue(rendered.contains("Кадров разобрано:** 1 из 4"))
    }

    /// The evidence is a verbatim quote and the parser upstream keeps any
    /// pipe it contains. Unescaped, it would shift the row's columns.
    func testPipeInEvidenceDoesNotBreakTheTable() {
        let rendered = frameDocument(participants: [
            Participant(name: "Иван", role: nil, confidence: .medium,
                        evidence: "сказал «путь A | B» на 05:00")
        ]).render()

        let row = rendered
            .components(separatedBy: "\n")
            .first { $0.contains("Иван") }

        XCTAssertNotNil(row)
        XCTAssertTrue(row!.contains("«путь A \\| B»"))
        // A raw split on "|" would still count the escaped one — the
        // backslash does not remove the character, it only tells a Markdown
        // renderer to treat it as literal text. Drop the "\|" sequence
        // itself before counting so only the structural delimiters remain.
        let structuralPipes = row!.replacingOccurrences(of: "\\|", with: "")
            .components(separatedBy: "|").count - 1
        XCTAssertEqual(structuralPipes, 5)
    }

    /// A bracket in the title would close the alt text early and take the
    /// image link with it.
    func testBracketInTitleDoesNotBreakTheImageLink() {
        let rendered = frameDocument(notes: [ScreenNote(
            start: 30, title: "консоль [prod]", details: "", presenter: nil,
            uiNames: [], slug: "yc", isUseful: true)]).render()

        XCTAssertTrue(rendered.contains("![консоль \\[prod\\]](screens/00-30_yc.jpg)"))
    }

    func testRemarksAreRenderedAfterParticipants() {
        let rendered = frameDocument(
            participants: [Participant(name: "Антон", role: nil, confidence: .high, evidence: "")],
            remarks: ["Под одним говорящим склеены двое."]
        ).render()

        let lines = rendered.components(separatedBy: "\n")
        let table = lines.firstIndex { $0.contains("| Антон |") }!
        let remark = lines.firstIndex { $0.contains("склеены двое") }!

        XCTAssertTrue(rendered.contains("### Замечания к разметке"))
        XCTAssertTrue(table < remark)
    }
}
