import XCTest
@testable import CyclopMeetings

final class TranscriptParserTests: XCTestCase {
    func testParsesTheFormatTheModelIsAskedFor() {
        let answer = """
            **[00:00:00] Участник 1:** Так, коллеги, давайте начнём.
            **[00:00:05] Участник 2:** Я посмотрел логи в Grafana.
            """
        let segments = TranscriptParser.segments(from: answer)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], TranscriptSegment(
            start: 0, speaker: "Участник 1", text: "Так, коллеги, давайте начнём."))
        XCTAssertEqual(segments[1].start, 5)
        XCTAssertEqual(segments[1].speaker, "Участник 2")
    }

    /// Models drift: sometimes the asterisks are gone, sometimes an hour-less
    /// timecode arrives. Both still carry a usable transcript.
    func testAcceptsPlainAndShortTimecodes() {
        let answer = """
            [00:00:07] Участник 1: без звёздочек
            **[01:05] Участник 2:** без часов
            """
        let segments = TranscriptParser.segments(from: answer)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "без звёздочек")
        XCTAssertEqual(segments[1].start, 65)
    }

    /// A preamble like "Вот расшифровка:" must not become a segment, and an
    /// empty answer must not become an empty speaker.
    func testSkipsEverythingWithoutATimecode() {
        XCTAssertTrue(TranscriptParser.segments(from: "Вот расшифровка записи:").isEmpty)
        XCTAssertTrue(TranscriptParser.segments(from: "").isEmpty)
    }

    /// A speech that runs past the line break belongs to the segment above it,
    /// not to nobody.
    func testContinuationLinesJoinThePreviousSegment() {
        let answer = """
            **[00:00:00] Участник 1:** Первая строка
            и её продолжение.
            **[00:00:09] Участник 2:** Вторая.
            """
        let segments = TranscriptParser.segments(from: answer)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Первая строка и её продолжение.")
    }
}
