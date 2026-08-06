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
        let response = WorkerResponse.decode(
            line: #"{"text":"Привет","took":1.2,"model":"mlx-community/whisper-large-v3-turbo"}"#
        )
        XCTAssertEqual(response?.text, "Привет")
        XCTAssertEqual(response?.model, "mlx-community/whisper-large-v3-turbo")
        XCTAssertNil(response?.error)
    }

    func testDecodesTranscriptionWithoutModel() {
        // The worker sends `"model": null` when it never went through
        // load_config() — see Engine.transcribe() — so a missing/null model
        // must decode cleanly rather than fail the whole response.
        let response = WorkerResponse.decode(line: #"{"text":"Привет","took":1.2,"model":null}"#)
        XCTAssertEqual(response?.text, "Привет")
        XCTAssertNil(response?.model)
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
