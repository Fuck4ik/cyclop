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

    func testOwnerLabelTrimsTheName() {
        XCTAssertEqual(TranscriptMerger.ownerLabel(for: "  Роман Ястребов  "), "Роман Ястребов")
    }

    /// The default state of the settings field, and the one where the owner's
    /// lane used to be left open to renaming.
    func testOwnerLabelFallsBackWhenNameIsEmpty() {
        XCTAssertEqual(
            TranscriptMerger.ownerLabel(for: "   "), TranscriptMerger.ownerLabel(for: ""))
        XCTAssertFalse(TranscriptMerger.ownerLabel(for: "").isEmpty)
    }

    /// The lane in the feed and the label the processor subtracts have to be
    /// the same string, however the name was typed.
    func testOwnerLabelMatchesTheLabelInTheFeed() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 0, speaker: "", text: "раз")],
            system: [],
            ownerName: "  Роман  "
        )

        XCTAssertEqual(merged.first?.speaker, TranscriptMerger.ownerLabel(for: "  Роман  "))
    }

    /// A name pasted from the clipboard arrives with line breaks and can be
    /// kilobytes long; it becomes the label on the owner's lane.
    func testOwnerLabelCollapsesWhitespaceAndClamps() {
        let pasted = "Роман\nЯстребов\t\tэксперт"

        XCTAssertEqual(TranscriptMerger.ownerLabel(for: pasted), "Роман Ястребов эксперт")
    }

    func testOwnerLabelIsClampedToSixtyFourCharacters() {
        let long = String(repeating: "я", count: 200)

        XCTAssertEqual(TranscriptMerger.ownerLabel(for: long).count, 64)
    }
}

// MARK: - Echo

/// Speakers on a Mac without headphones are recorded twice: once by the
/// system lane and once by the microphone, which hears the room. Measured on
/// an hour-long call — 178 of the owner's 215 lines were other people's words
/// coming back through the speakers.
extension TranscriptMergerTests {
    func testTheRoomComingBackThroughTheSpeakersIsDropped() {
        let merged = TranscriptMerger.merge(
            microphone: [
                TranscriptSegment(start: 69, speaker: "Участник 1", text: "Коллеги, меня слышно? Привет.")
            ],
            system: [
                TranscriptSegment(start: 69, speaker: "Участник 2", text: "Угу. Коллеги, нас слышно? Привет.")
            ],
            ownerName: "Роман"
        )

        XCTAssertEqual(merged.map(\.speaker), ["Участник 2"])
    }

    func testTheOwnersOwnWordsSurviveBesideSomeoneElses() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 59, speaker: "Участник 1", text: "Да. Саш, привет.")],
            system: [
                TranscriptSegment(
                    start: 59, speaker: "Участник 2",
                    text: "Мы сравнили требования, которые озвучивал заказчик, с договором.")
            ],
            ownerName: "Роман"
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.speaker == "Роман" })
    }

    /// The same words half a minute apart are two people saying the same
    /// thing, not one echo — agreement in a meeting sounds exactly like this.
    func testTheSameWordsFarApartAreNotAnEcho() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 100, speaker: "Участник 1", text: "полностью согласен с планом")],
            system: [TranscriptSegment(start: 40, speaker: "Участник 2", text: "полностью согласен с планом")],
            ownerName: "Роман"
        )

        XCTAssertEqual(merged.count, 2)
    }

    /// A meeting taken on headphones has no echo at all, and nothing may be
    /// dropped from it.
    func testAQuietRoomLosesNothing() {
        let microphone = (0..<5).map {
            TranscriptSegment(start: Double($0) * 10, speaker: "Участник 1", text: "реплика номер \($0)")
        }
        let merged = TranscriptMerger.merge(
            microphone: microphone,
            system: [TranscriptSegment(start: 5, speaker: "Участник 2", text: "совершенно другие слова")],
            ownerName: "Роман"
        )

        XCTAssertEqual(merged.filter { $0.speaker == "Роман" }.count, 5)
    }

    func testAnEmptySystemLaneDropsNothing() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 0, speaker: "Участник 1", text: "один в комнате")],
            system: [],
            ownerName: "Роман"
        )

        XCTAssertEqual(merged.count, 1)
    }

    /// Punctuation and case differ between two transcriptions of the same
    /// sound — the comparison has to look past both.
    func testEchoIsFoundAcrossPunctuationAndCase() {
        XCTAssertTrue(TranscriptMerger.isEcho(
            "Сейчас ещё Пётр хочет что-то спросить.",
            of: "сейчас ещё пётр хочет спросить"))
    }

    func testDifferentSentencesAreNotEcho() {
        XCTAssertFalse(TranscriptMerger.isEcho(
            "Смотрите, пункт шесть про информационную безопасность.",
            of: "Да, я не думаю, что это надо."))
    }

    /// An empty line has no words to match, and dividing by that count is how
    /// a "everything matches" answer would be produced out of nothing.
    func testAnEmptyLineIsNotEcho() {
        XCTAssertFalse(TranscriptMerger.isEcho("", of: "какие-то слова"))
        XCTAssertFalse(TranscriptMerger.isEcho("  ...  ", of: "какие-то слова"))
    }
}

extension TranscriptMergerTests {
    /// The line that first showed the threshold was too strict: the
    /// microphone's own interjections pad the echo out until only two thirds
    /// of it matches.
    func testAnEchoPaddedWithInterjectionsIsStillAnEcho() {
        XCTAssertTrue(TranscriptMerger.isEcho(
            "Да-да, давай, Кать. Давай-давай, говори, Катя.",
            of: "Давай, давай, Кать. Давай, давай."))
    }

    /// The other side of the same measurement: the owner answering in his own
    /// words shares a little with what was just said, and must survive it.
    func testAnAnswerThatSharesAFewWordsSurvives() {
        XCTAssertFalse(TranscriptMerger.isEcho(
            "Так, а что ещё раз за тема обсуждения?",
            of: "Тема обсуждения в том, что мы не понимаем, на какие требования ориентироваться"))
    }
}

extension TranscriptMergerTests {
    /// The pair that showed a three-second window was too narrow: identical
    /// words, timecodes printed three apart, and more than three between them
    /// before the timecode was floored.
    func testAnEchoFourSecondsLaterIsStillAnEcho() {
        let merged = TranscriptMerger.merge(
            microphone: [
                TranscriptSegment(start: 79, speaker: "Участник 1", text: "Ещё раз что-нибудь скажите, пожалуйста.")
            ],
            system: [
                TranscriptSegment(
                    start: 75, speaker: "Участник 2",
                    text: "Сейчас, секундочку. Ещё раз что-нибудь скажите, пожалуйста.")
            ],
            ownerName: "Роман"
        )

        XCTAssertEqual(merged.map(\.speaker), ["Участник 2"])
    }
}
