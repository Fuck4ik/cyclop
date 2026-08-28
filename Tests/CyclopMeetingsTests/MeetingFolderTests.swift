import XCTest
@testable import CyclopMeetings

final class MeetingFolderTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Users/test/Meetings", isDirectory: true)

    /// 17 August 2026, 20:53 on the wall clock of whichever Mac runs this.
    /// The folder name is local time — it has to match the transcript header
    /// and the list row, which are local too — so the expected instant is
    /// built in the local zone rather than pinned to a UTC timestamp.
    private let startedAt: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 17
        components.hour = 20
        components.minute = 53
        return calendar.date(from: components)!
    }()

    func testFolderIsNamedByDateAndTime() {
        let folder = MeetingFolder(root: root, startedAt: startedAt)
        XCTAssertEqual(folder.url.lastPathComponent, "2026-08-17 20-53 Встреча")
    }

    /// The name is the only record of when a meeting started, so writing it
    /// and reading it back has to land on the same instant.
    func testNameRoundTripsThroughTheSameInstant() {
        let folder = MeetingFolder(root: root, startedAt: startedAt)
        XCTAssertEqual(MeetingFolder(existing: folder.url)?.startedAt, startedAt)
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

    /// The reason is written by code with no string table and read back by a
    /// pane that has one, possibly after the app's language was switched — so
    /// what goes to disk is a code, and it has to come back as the same case.
    func testEveryFailureCodeSurvivesTheStateFile() {
        let cases: [MeetingFailure] = [
            .nothingRecognised, .closedWhileRecording, .interrupted, .missingStateFile,
        ]
        for failure in cases {
            XCTAssertEqual(MeetingFailure(stored: failure.stored), failure)
        }
    }

    /// Anything the codes cannot name — a proxy message, a file system error —
    /// is already a sentence and must survive as itself rather than be lost.
    func testUnknownReasonStaysItsOwnText() {
        XCTAssertEqual(MeetingFailure(stored: "HTTP 502: no upstream"), .message("HTTP 502: no upstream"))
        XCTAssertEqual(MeetingFailure.message("HTTP 502").stored, "HTTP 502")
    }
}
