import XCTest
@testable import CyclopMeetings

final class MeetingStagesTests: XCTestCase {
    func testStagesSurviveTheRoundTrip() throws {
        var stages = MeetingStages()
        stages.transcribed = true
        stages.framesExtracted = true

        let file = MeetingStateFile(state: .processing, duration: 60, stages: stages)
        let decoded = try MeetingStateFile.decode(try file.encoded())

        XCTAssertEqual(decoded.stages?.transcribed, true)
        XCTAssertEqual(decoded.stages?.framesExtracted, true)
        XCTAssertEqual(decoded.stages?.framesRead, false)
    }

    /// A file written before stages existed still has to decode: losing it
    /// costs the meeting, and the recording cannot be made again.
    func testOlderFileWithoutStagesStillDecodes() throws {
        let json = #"{"state":"ready","duration":60}"#.data(using: .utf8)!

        let decoded = try MeetingStateFile.decode(json)

        XCTAssertEqual(decoded.state, .ready)
        XCTAssertNil(decoded.stages)
    }

    func testFreshStagesAreAllUnfinished() {
        let stages = MeetingStages()

        XCTAssertFalse(stages.transcribed)
        XCTAssertFalse(stages.framesPlanned)
        XCTAssertFalse(stages.framesExtracted)
        XCTAssertFalse(stages.framesRead)
        XCTAssertFalse(stages.participantsResolved)
    }
}
