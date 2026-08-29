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

    /// A stray field line between two blocks must not attach to the block that
    /// just ended: the timecode has to be cleared along with the fields, or one
    /// frame gets the other's title and the other disappears.
    func testStrayFieldBetweenBlocksDoesNotStealTheTimecode() {
        let text = """
            [00:05:00]
            useful: yes
            title: A

            title: B
            [00:10:00]
            useful: yes
            title: C
            """

        let notes = ScreenNoteParser.notes(from: text)

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].start, 300)
        XCTAssertEqual(notes[0].title, "A")
        XCTAssertEqual(notes[1].start, 600)
        XCTAssertEqual(notes[1].title, "C")
    }

    /// A blank line inside a block is not a separator: the model breaks its
    /// own format this way, and everything after the gap has to survive.
    func testBlankLineInsideBlockDoesNotEndIt() {
        let text = """
            [00:05:00]
            useful: yes

            title: экран
            details: подробности
            """

        let notes = ScreenNoteParser.notes(from: text)

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].title, "экран")
        XCTAssertEqual(notes[0].details, "подробности")
    }

    /// The model answers `details` in several lines whenever the screen had
    /// several identifiers on it.
    func testMultilineDetailsSurvive() {
        let text = """
            [00:05:00]
            useful: yes
            title: консоль
            details: кластер ycru1-mp2-prod
            поды argocd-application-controller-0
            все в статусе Running
            """

        let note = ScreenNoteParser.notes(from: text).first

        XCTAssertEqual(
            note?.details,
            "кластер ycru1-mp2-prod поды argocd-application-controller-0 все в статусе Running")
    }

    func testSlugKeepsCyrillicAndCollapsesSeparators() {
        let text = "[00:05:00]\nuseful: yes\nslug: Консоль  Yandex // Cloud\ntitle: т"

        XCTAssertEqual(ScreenNoteParser.notes(from: text).first?.slug, "консоль-yandex-cloud")
    }

    /// The slug becomes a file name: a path separator or a parent reference
    /// must not survive it.
    func testSlugCannotEscapeTheFolder() {
        let text = "[00:05:00]\nuseful: yes\nslug: ../../etc/passwd\ntitle: т"

        let slug = ScreenNoteParser.notes(from: text).first?.slug
        XCTAssertFalse(slug?.contains("/") ?? true)
        XCTAssertFalse(slug?.contains("..") ?? true)
    }
}
