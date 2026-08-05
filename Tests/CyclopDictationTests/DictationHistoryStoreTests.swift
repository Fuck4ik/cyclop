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
}
