import XCTest
@testable import CyclopMeetings

final class ScreenNoteTests: XCTestCase {
    private let answer = """
        [00:30:00]
        useful: yes
        slug: yandex-cloud-k8s-рабочая-нагрузка
        title: консоль Yandex Cloud, Managed Kubernetes
        details: Кластер ycru1-mp2-prod-k8s-05sd6avu, поды argocd-application-controller-0, все Running
        presenter: Антон Копытин
        names: Alexander T., Антон Копытин, Илья Канюков

        [00:41:40]
        useful: no
        title: пустой рабочий стол
        """

    func testParsesFullBlock() {
        let notes = ScreenNoteParser.notes(from: answer)

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].start, 1800)
        XCTAssertEqual(notes[0].title, "консоль Yandex Cloud, Managed Kubernetes")
        XCTAssertTrue(notes[0].details.contains("ycru1-mp2-prod-k8s-05sd6avu"))
        XCTAssertEqual(notes[0].presenter, "Антон Копытин")
        XCTAssertEqual(notes[0].uiNames, ["Alexander T.", "Антон Копытин", "Илья Канюков"])
        XCTAssertTrue(notes[0].isUseful)
    }

    func testMarksUselessFrame() {
        XCTAssertFalse(ScreenNoteParser.notes(from: answer)[1].isUseful)
    }

    /// A frame the model said nothing about must not become an empty block in
    /// the transcript.
    func testSkipsBlockWithoutTitle() {
        let notes = ScreenNoteParser.notes(from: "[00:10:00]\nuseful: yes")

        XCTAssertTrue(notes.isEmpty)
    }

    func testFileNameCarriesTimecodeAndSlug() {
        let note = ScreenNote(
            start: 1800, title: "т", details: "д", presenter: nil,
            uiNames: [], slug: "yandex-cloud", isUseful: true)

        XCTAssertEqual(note.fileName, "30-00_yandex-cloud.jpg")
    }

    /// Without a slug the file still has to be nameable — the timecode alone
    /// is unique.
    func testFileNameFallsBackToTimecode() {
        let note = ScreenNote(
            start: 61, title: "т", details: "", presenter: nil,
            uiNames: [], slug: "", isUseful: true)

        XCTAssertEqual(note.fileName, "01-01.jpg")
    }
}
