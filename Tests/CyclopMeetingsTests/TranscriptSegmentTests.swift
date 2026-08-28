import XCTest
@testable import CyclopMeetings

final class TranscriptSegmentTests: XCTestCase {
    func testTimecodeIsPaddedToHours() {
        XCTAssertEqual(TranscriptSegment(start: 0, speaker: "Роман", text: "да").timecode, "00:00:00")
        XCTAssertEqual(TranscriptSegment(start: 65, speaker: "Роман", text: "да").timecode, "00:01:05")
        XCTAssertEqual(TranscriptSegment(start: 3725, speaker: "Роман", text: "да").timecode, "01:02:05")
    }

    func testLineMatchesTranscriptFormat() {
        let segment = TranscriptSegment(start: 5, speaker: "Участник 2", text: "Логи в Grafana")
        XCTAssertEqual(segment.line, "**[00:00:05] Участник 2:** Логи в Grafana")
    }

    /// Chunks are transcribed independently, so every segment of the second
    /// chunk arrives with a timecode counted from that chunk's own start.
    func testShiftMovesTheTimecode() {
        let segment = TranscriptSegment(start: 10, speaker: "Роман", text: "да")
        XCTAssertEqual(segment.shifted(by: 3300).start, 3310)
        XCTAssertEqual(segment.shifted(by: 3300).timecode, "00:55:10")
    }
}
