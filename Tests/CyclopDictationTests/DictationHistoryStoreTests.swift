import XCTest
@testable import CyclopDictation

final class DictationHistoryStoreTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    private func write(_ lines: [String]) {
        try! lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func line(_ text: String, at iso: String) -> String {
        #"{"at":"\#(iso)","text":"\#(text)","chars":\#(text.count),"audio":null,"took":1,"model":"m"}"#
    }

    func testNewestFirst() {
        write([
            line("старое", at: "2026-08-01T10:00:00Z"),
            line("новое", at: "2026-08-05T10:00:00Z"),
        ])
        let store = DictationHistoryStore(file: file)
        store.reload()
        XCTAssertEqual(store.items.map(\.text), ["новое", "старое"])
    }

    func testSkipsCorruptLineAndKeepsRest() {
        write([line("первая", at: "2026-08-01T10:00:00Z"), "{битая", line("вторая", at: "2026-08-02T10:00:00Z")])
        let store = DictationHistoryStore(file: file)
        store.reload()
        XCTAssertEqual(store.items.count, 2)
    }

    func testMissingFileGivesEmptyHistory() {
        let store = DictationHistoryStore(file: file)
        store.reload()
        XCTAssertTrue(store.items.isEmpty)
    }

    func testAppendPersistsAndShowsUpFirst() {
        write([line("старое", at: "2026-08-01T10:00:00Z")])
        let store = DictationHistoryStore(file: file)
        store.reload()
        store.append(DictationRecord(text: "свежее", audio: nil, took: 1, model: "m"))

        let reopened = DictationHistoryStore(file: file)
        reopened.reload()
        XCTAssertEqual(reopened.items.first?.text, "свежее")
        XCTAssertEqual(reopened.items.count, 2)
    }

    func testRetentionDropsOldestBeyondLimit() {
        let store = DictationHistoryStore(file: file, limit: 3)
        for index in 1...5 {
            store.append(DictationRecord(
                text: "запись \(index)", audio: nil, took: 1, model: "m",
                at: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        let reopened = DictationHistoryStore(file: file, limit: 3)
        reopened.reload()
        XCTAssertEqual(reopened.items.map(\.text), ["запись 5", "запись 4", "запись 3"])
    }

    func testSearchIgnoresCaseAndDiacritics() {
        write([
            line("Про GitHub и деплой", at: "2026-08-01T10:00:00Z"),
            line("Про ёжика", at: "2026-08-02T10:00:00Z"),
        ])
        let store = DictationHistoryStore(file: file)
        store.reload()
        XCTAssertEqual(store.filtered("github").count, 1)
        XCTAssertEqual(store.filtered("ежик").count, 1)
        XCTAssertEqual(store.filtered("  ").count, 2, "пустой запрос не фильтрует")
    }

    // MARK: - Critical Fixes

    func testAppendDoesNotModifyExistingLines() {
        let lineWithUnknown = #"{"at":"2026-08-01T10:00:00Z","text":"старое","chars":5,"audio":null,"took":1,"model":"m","source":"archive"}"#
        write([lineWithUnknown])

        // Record original file content
        let beforeContent = try! String(contentsOf: file, encoding: .utf8)

        // Append a new record
        let store = DictationHistoryStore(file: file)
        store.reload()
        store.append(DictationRecord(text: "новое", audio: nil, took: 1, model: "m"))

        // Verify the original line is still there unchanged
        let afterContent = try! String(contentsOf: file, encoding: .utf8)
        let lines = afterContent.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        XCTAssertGreaterThanOrEqual(lines.count, 2)
        XCTAssertEqual(lines[0], lineWithUnknown, "existing line should not change")
    }

    func testUnknownFieldSurvivesRetentionTrim() {
        let lineWithUnknown = #"{"at":"2026-08-05T10:00:00Z","text":"запись 1","chars":7,"audio":null,"took":1,"model":"m","source":"archive"}"#
        write([lineWithUnknown])

        let store = DictationHistoryStore(file: file, limit: 1)
        store.reload()

        // Add an older record to trigger retention (newer record is kept)
        store.append(DictationRecord(
            text: "запись 2", audio: nil, took: 1, model: "m",
            at: Date(timeIntervalSince1970: 100)))

        // Reload and verify "source" field is preserved on the kept record
        let reopened = DictationHistoryStore(file: file, limit: 1)
        reopened.reload()
        XCTAssertEqual(reopened.items.count, 1)
        XCTAssertEqual(reopened.items.first?.text, "запись 1", "newer record should be kept")

        let afterContent = try! String(contentsOf: file, encoding: .utf8)
        XCTAssert(afterContent.contains("\"source\":\"archive\""), "source field should survive retention trim")
    }

    func testAppendOutOfOrderPlacesCorrectlyInMemory() {
        let store = DictationHistoryStore(file: file)

        // Add record with time 1000
        let r1 = DictationRecord(text: "первая", audio: nil, took: 1, model: "m",
                                 at: Date(timeIntervalSince1970: 1000))
        store.append(r1)

        // Add record with earlier time 500
        let r2 = DictationRecord(text: "вторая", audio: nil, took: 1, model: "m",
                                 at: Date(timeIntervalSince1970: 500))
        store.append(r2)

        // In memory: newer first means r1 (1000) should come before r2 (500)
        XCTAssertEqual(store.items[0].text, "первая", "newer time should be first in memory")
        XCTAssertEqual(store.items[1].text, "вторая", "older time should be second in memory")
    }

    func testTwoIndependentInstancesBothPersist() {
        let store1 = DictationHistoryStore(file: file)
        let store2 = DictationHistoryStore(file: file)

        let r1 = DictationRecord(text: "от первого", audio: nil, took: 1, model: "m",
                                at: Date(timeIntervalSince1970: 100))
        let r2 = DictationRecord(text: "от второго", audio: nil, took: 1, model: "m",
                                at: Date(timeIntervalSince1970: 200))

        store1.append(r1)
        store2.append(r2)

        // Reload from disk and verify both are present
        let reopened = DictationHistoryStore(file: file)
        reopened.reload()

        XCTAssertEqual(reopened.items.count, 2, "both appends should be in file")
        let texts = reopened.items.map(\.text)
        XCTAssert(texts.contains("от первого"), "first append should be present")
        XCTAssert(texts.contains("от второго"), "second append should be present")
    }
}
