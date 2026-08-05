import XCTest
@testable import CyclopDictation

final class WorkerProtocolTests: XCTestCase {
    func testTranscribeRequestIsOneLine() throws {
        let line = try WorkerRequest.transcribe(path: "/tmp/a b.wav").encodedLine()
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains("\"cmd\":\"transcribe\""))
        XCTAssertTrue(line.contains("/tmp/a b.wav"))
    }

    func testUnloadRequest() throws {
        XCTAssertTrue(try WorkerRequest.unload.encodedLine().contains("\"cmd\":\"unload\""))
    }

    func testDecodesTranscription() {
        let response = WorkerResponse.decode(line: #"{"text":"Привет","took":1.2,"language":"ru"}"#)
        XCTAssertEqual(response?.text, "Привет")
        XCTAssertEqual(response?.language, "ru")
        XCTAssertNil(response?.error)
    }

    func testDecodesError() {
        let response = WorkerResponse.decode(line: #"{"error":"model missing"}"#)
        XCTAssertEqual(response?.error, "model missing")
        XCTAssertNil(response?.text)
    }

    func testDecodesUnloadReport() {
        let response = WorkerResponse.decode(line: #"{"unloaded":true,"freed_mb":3529.5}"#)
        XCTAssertEqual(response?.unloaded, true)
        XCTAssertEqual(response?.freedMB ?? 0, 3529.5, accuracy: 0.01)
    }

    func testGarbageDecodesToNil() {
        XCTAssertNil(WorkerResponse.decode(line: "Traceback (most recent call last):"))
    }
}
