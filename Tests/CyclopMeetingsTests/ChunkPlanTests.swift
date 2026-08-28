import XCTest
@testable import CyclopMeetings

final class ChunkPlanTests: XCTestCase {
    /// An hour of audio is 18 MB in base64 against a 20 MB request ceiling,
    /// so the threshold sits at 55 minutes rather than at a round hour.
    func testLimitIs55Minutes() {
        XCTAssertEqual(ChunkPlan.limit, 3300)
    }

    func testShortMeetingStaysWhole() {
        let chunks = ChunkPlan.chunks(forDuration: 1800)
        XCTAssertEqual(chunks, [ChunkPlan.Chunk(start: 0, duration: 1800)])
    }

    func testMeetingExactlyAtTheLimitStaysWhole() {
        XCTAssertEqual(ChunkPlan.chunks(forDuration: 3300).count, 1)
    }

    func testLongMeetingIsCutIntoWholeChunks() {
        let chunks = ChunkPlan.chunks(forDuration: 7200)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], ChunkPlan.Chunk(start: 0, duration: 3300))
        XCTAssertEqual(chunks[1], ChunkPlan.Chunk(start: 3300, duration: 3300))
        XCTAssertEqual(chunks[2], ChunkPlan.Chunk(start: 6600, duration: 600))
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.duration }, 7200)
    }

    /// A recording that stopped a second after the limit would otherwise
    /// produce a one-second chunk, which costs a whole request for nothing.
    func testTinyTailIsFoldedIntoThePreviousChunk() {
        let chunks = ChunkPlan.chunks(forDuration: 3310)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].duration, 3310)
    }

    /// The fold boundary itself, from both sides. It is the only thing
    /// deciding whether a meeting past 55 minutes is cut at all, and one
    /// second either way changes the answer: at 3360 the tail is still folded
    /// into a single request, at 3361 it becomes a second one.
    func testFoldBoundaryIsPinnedFromBothSides() {
        XCTAssertEqual(
            ChunkPlan.chunks(forDuration: 3360),
            [ChunkPlan.Chunk(start: 0, duration: 3360)]
        )
        XCTAssertEqual(
            ChunkPlan.chunks(forDuration: 3361),
            [
                ChunkPlan.Chunk(start: 0, duration: 3300),
                ChunkPlan.Chunk(start: 3300, duration: 61),
            ]
        )
    }

    func testEmptyRecordingGivesNoChunks() {
        XCTAssertTrue(ChunkPlan.chunks(forDuration: 0).isEmpty)
    }
}
