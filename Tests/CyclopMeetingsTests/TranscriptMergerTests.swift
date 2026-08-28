import XCTest
@testable import CyclopMeetings

final class TranscriptMergerTests: XCTestCase {
    func testOwnerSpeechIsNamed() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 0, speaker: "Участник 1", text: "моя реплика")],
            system: [],
            ownerName: "Роман"
        )
        XCTAssertEqual(merged.map(\.speaker), ["Роман"])
    }

    func testBothLanesAreOrderedByTime() {
        let merged = TranscriptMerger.merge(
            microphone: [
                TranscriptSegment(start: 0, speaker: "Участник 1", text: "начнём"),
                TranscriptSegment(start: 20, speaker: "Участник 1", text: "согласен"),
            ],
            system: [
                TranscriptSegment(start: 10, speaker: "Участник 1", text: "смотрел логи"),
                TranscriptSegment(start: 30, speaker: "Участник 2", text: "я за откат"),
            ],
            ownerName: "Роман"
        )

        XCTAssertEqual(merged.map(\.start), [0, 10, 20, 30])
        XCTAssertEqual(merged.map(\.speaker), ["Роман", "Участник 1", "Роман", "Участник 2"])
    }

    /// Numbering comes from the model and only covers the system lane; the
    /// owner is not one of those numbers and must not shift them.
    func testSystemNumberingIsLeftAlone() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 5, speaker: "Участник 1", text: "моя")],
            system: [TranscriptSegment(start: 0, speaker: "Участник 3", text: "чужая")],
            ownerName: "Роман"
        )
        XCTAssertEqual(merged.map(\.speaker), ["Участник 3", "Роман"])
    }

    /// Two people talking over each other land on the same second. Order then
    /// has to be stable, and the owner goes first — it is his machine.
    func testSimultaneousSpeechPutsTheOwnerFirst() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 7, speaker: "Участник 1", text: "моя")],
            system: [TranscriptSegment(start: 7, speaker: "Участник 2", text: "чужая")],
            ownerName: "Роман"
        )
        XCTAssertEqual(merged.map(\.speaker), ["Роман", "Участник 2"])
    }

    func testMissingMicrophoneLaneStillGivesATranscript() {
        let merged = TranscriptMerger.merge(
            microphone: [],
            system: [TranscriptSegment(start: 0, speaker: "Участник 1", text: "одни они")],
            ownerName: "Роман"
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].speaker, "Участник 1")
    }

    /// An empty owner name in settings must not produce "**[00:00:00] :** …".
    func testEmptyOwnerNameFallsBackToALabel() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 0, speaker: "Участник 1", text: "моя")],
            system: [],
            ownerName: "   "
        )
        XCTAssertEqual(merged[0].speaker, "Я")
    }
}
