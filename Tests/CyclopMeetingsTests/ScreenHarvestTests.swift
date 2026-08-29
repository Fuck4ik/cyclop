import XCTest
@testable import CyclopMeetings

final class ScreenHarvestTests: XCTestCase {
    private func note(_ start: TimeInterval, useful: Bool = true, slug: String = "s") -> ScreenNote {
        ScreenNote(start: start, title: "экран", details: "", presenter: nil,
                   uiNames: [], slug: slug, isUseful: useful)
    }

    func testKeepsNoteWhoseFrameWasCaptured() {
        XCTAssertEqual(
            ScreenHarvest.renderable([note(30)], captured: [30]).map(\.start), [30])
    }

    /// The model shifts a timecode by a second and the document would render a
    /// link to a file nobody wrote.
    func testDropsNoteWithoutItsOwnFrame() {
        XCTAssertTrue(ScreenHarvest.renderable([note(31)], captured: [30]).isEmpty)
    }

    func testDropsUselessNote() {
        XCTAssertTrue(ScreenHarvest.renderable([note(30, useful: false)], captured: [30]).isEmpty)
    }

    /// One frame, one block: a timecode described twice must not produce two.
    func testDropsDuplicateTimecode() {
        let notes = [note(30, slug: "первый"), note(30, slug: "второй")]

        let kept = ScreenHarvest.renderable(notes, captured: [30])

        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.slug, "первый")
    }

    func testEmptyInputGivesNothing() {
        XCTAssertTrue(ScreenHarvest.renderable([], captured: [30]).isEmpty)
    }
}
