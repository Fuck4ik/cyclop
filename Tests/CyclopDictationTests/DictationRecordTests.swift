import XCTest
@testable import CyclopDictation

final class DictationRecordTests: XCTestCase {
    func testDecodesArchiveLine() {
        let line = #"{"at":"2026-08-05T17:34:04Z","text":"Привет","chars":6,"audio":"dictation-20260805-173404.wav","took":11.05,"model":"mlx-community/whisper-large-v3-turbo"}"#
        let record = DictationRecord.decode(line: line)
        XCTAssertEqual(record?.text, "Привет")
        XCTAssertEqual(record?.chars, 6)
        XCTAssertEqual(record?.audio, "dictation-20260805-173404.wav")
    }

    func testRejectsGarbageLine() {
        XCTAssertNil(DictationRecord.decode(line: "не json"))
        XCTAssertNil(DictationRecord.decode(line: ""))
    }

    func testRoundTripsThroughOneLine() throws {
        let record = DictationRecord(text: "Тест", audio: nil, took: 1.5, model: "m")
        let line = try record.encodedLine()
        XCTAssertFalse(line.contains("\n"), "запись должна занимать ровно одну строку")
        XCTAssertEqual(DictationRecord.decode(line: line)?.text, "Тест")
    }

    func testCharsCountUnicodeNotBytes() {
        let record = DictationRecord(text: "Привет", audio: nil, took: 0, model: "m")
        XCTAssertEqual(record.chars, 6)
    }
}
