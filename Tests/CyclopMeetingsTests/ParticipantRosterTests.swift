import XCTest
@testable import CyclopMeetings

final class ParticipantRosterTests: XCTestCase {
    private let segments = [
        TranscriptSegment(start: 0, speaker: "Участник 1", text: "раз"),
        TranscriptSegment(start: 10, speaker: "Участник 2", text: "два два два"),
        TranscriptSegment(start: 20, speaker: "Участник 1", text: "три"),
    ]

    func testProfileCountsSpeechAndSpan() {
        let profiles = SpeakerProfiler.profiles(of: segments)

        XCTAssertEqual(profiles.count, 2)
        let first = profiles.first { $0.label == "Участник 1" }
        XCTAssertEqual(first?.lines, 2)
        XCTAssertEqual(first?.characters, 6)
        XCTAssertEqual(first?.first, 0)
        XCTAssertEqual(first?.last, 20)
    }

    /// The order is what the model reads first, and the loudest speaker is the
    /// one whose identity matters most.
    func testProfilesAreSortedByVolume() {
        XCTAssertEqual(SpeakerProfiler.profiles(of: segments).first?.label, "Участник 2")
    }

    /// "N реплик" does not agree with every N in Russian — "реплик —" reads
    /// correctly no matter the count.
    func testProfileLineDoesNotForceNumberAgreement() {
        let profile = SpeakerProfile(
            label: "Роман", characters: 6, lines: 2, first: 0, last: 20)

        XCTAssertEqual(profile.line, "Роман: реплик — 2, символов — 6, с 00:00:00 по 00:00:20")
    }

    func testCandidateNamesMergeAllSources() {
        let note = ScreenNote(
            start: 0, title: "т", details: "", presenter: nil,
            uiNames: ["Антон Копытин", "Alexander T."], slug: "", isUseful: true)

        let names = ParticipantRoster.candidateNames(
            owner: "Роман Ястребов", calendar: ["Екатерина Яблокова"], notes: [note])

        XCTAssertEqual(
            names, ["Роман Ястребов", "Екатерина Яблокова", "Alexander T.", "Антон Копытин"])
    }

    /// One person joined from two devices shows up as two identical tiles.
    /// Counting them twice would invent a participant.
    func testCandidateNamesDropDuplicates() {
        let note = ScreenNote(
            start: 0, title: "т", details: "", presenter: nil,
            uiNames: ["Антон Копытин", "Антон Копытин"], slug: "", isUseful: true)

        XCTAssertEqual(ParticipantRoster.candidateNames(owner: nil, calendar: [], notes: [note]),
                       ["Антон Копытин"])
    }

    func testNamesFromUselessFramesStillCount() {
        let note = ScreenNote(
            start: 0, title: "пусто", details: "", presenter: nil,
            uiNames: ["Денис Терещенко"], slug: "", isUseful: false)

        XCTAssertEqual(ParticipantRoster.candidateNames(owner: nil, calendar: [], notes: [note]),
                       ["Денис Терещенко"])
    }
}
