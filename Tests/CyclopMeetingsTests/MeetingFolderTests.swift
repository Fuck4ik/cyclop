import XCTest
@testable import CyclopMeetings

final class MeetingFolderTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Users/test/Meetings", isDirectory: true)
    private let startedAt = Date(timeIntervalSince1970: 1_786_999_980)

    func testFolderIsNamedByDateAndTime() {
        let folder = MeetingFolder(root: root, startedAt: startedAt)
        XCTAssertEqual(folder.url.lastPathComponent, "2026-08-17 20-53 Встреча")
    }

    func testFilesSitInsideTheFolder() {
        let folder = MeetingFolder(root: root, startedAt: startedAt)
        XCTAssertEqual(folder.videoURL.lastPathComponent, "meeting.mp4")
        XCTAssertEqual(folder.microphoneURL.lastPathComponent, "mic.m4a")
        XCTAssertEqual(folder.transcriptURL.lastPathComponent, "transcript.md")
        XCTAssertEqual(folder.stateURL.lastPathComponent, ".state.json")
        XCTAssertEqual(folder.videoURL.deletingLastPathComponent(), folder.url)
    }

    /// The list of past meetings is built by reading the folder names back.
    func testExistingFolderIsRecognisedByItsName() {
        let url = root.appendingPathComponent("2026-08-17 20-53 Встреча", isDirectory: true)
        let folder = MeetingFolder(existing: url)

        XCTAssertNotNil(folder)
        XCTAssertEqual(folder?.startedAt, startedAt)
        XCTAssertEqual(folder?.url, url)
    }

    func testUnrelatedFolderIsIgnored() {
        XCTAssertNil(MeetingFolder(existing: root.appendingPathComponent("Документы")))
        XCTAssertNil(MeetingFolder(existing: root.appendingPathComponent("2026-13-45 99-99 Встреча")))
    }

    func testStateSurvivesEncoding() throws {
        let file = MeetingStateFile(state: .processing, duration: 4623, failure: nil)
        let restored = try MeetingStateFile.decode(file.encoded())

        XCTAssertEqual(restored.state, .processing)
        XCTAssertEqual(restored.duration, 4623)
        XCTAssertNil(restored.failure)
    }

    func testFailureReasonSurvivesEncoding() throws {
        let file = MeetingStateFile(state: .failed, duration: 60, failure: "HTTP 502")
        XCTAssertEqual(try MeetingStateFile.decode(file.encoded()).failure, "HTTP 502")
    }
}
