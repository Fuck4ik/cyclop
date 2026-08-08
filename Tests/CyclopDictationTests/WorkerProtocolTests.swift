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

    func testDownloadRequestCarriesTheModelId() throws {
        let line = try WorkerRequest.download(id: "large-v3-turbo-q4").encodedLine()
        XCTAssertTrue(line.contains("\"cmd\":\"download\""))
        XCTAssertTrue(line.contains("\"id\":\"large-v3-turbo-q4\""))
    }

    func testEnsureModelRequest() throws {
        XCTAssertTrue(try WorkerRequest.ensureModel.encodedLine().contains("\"cmd\":\"ensure\""))
    }

    func testDecodesDownloadProgress() {
        let response = WorkerResponse.decode(
            line: #"{"progress":0.42,"downloaded_mb":630.5,"total_mb":1539.0,"model":"mlx-community/whisper-large-v3-turbo"}"#
        )
        XCTAssertEqual(response?.progress ?? 0, 0.42, accuracy: 0.001)
        XCTAssertEqual(response?.downloadedMB ?? 0, 630.5, accuracy: 0.01)
        XCTAssertEqual(response?.totalMB ?? 0, 1539, accuracy: 0.01)
        XCTAssertNil(response?.text, "прогресс — не расшифровка")
    }

    func testDecodesModelReady() {
        let response = WorkerResponse.decode(line: #"{"ready":true,"model":"mlx-community/whisper-small-mlx"}"#)
        XCTAssertEqual(response?.ready, true)
        XCTAssertNil(response?.progress)
    }

    func testDecodesCatalog() {
        let line = #"""
        {"models":[{"id":"large-v3-turbo","label":"Balanced","repo":"mlx-community/whisper-large-v3-turbo","detail":"best speed/quality default","size_mb":1539,"ready":true,"selected":true}]}
        """#
        let models = WorkerResponse.decode(line: line)?.models
        XCTAssertEqual(models?.count, 1)
        XCTAssertEqual(models?.first?.id, "large-v3-turbo")
        XCTAssertEqual(models?.first?.sizeMB, 1539)
        XCTAssertEqual(models?.first?.ready, true)
        XCTAssertEqual(models?.first?.selected, true)
    }
}

final class DictationModelTests: XCTestCase {
    private func model(sizeMB: Int) -> DictationModel {
        DictationModel(
            id: "x", label: "L", repo: "r", detail: "d",
            sizeMB: sizeMB, ready: false, selected: false
        )
    }

    func testMegabytesStayMegabytes() {
        let size = model(sizeMB: 442).size
        XCTAssertFalse(size.isGigabytes)
        XCTAssertEqual(size.value, 442, accuracy: 0.01)
    }

    func testFourFigureSizesBecomeGigabytes() {
        // 1539 MB is a number nobody reads as a size; 1.5 GB is.
        let size = model(sizeMB: 1539).size
        XCTAssertTrue(size.isGigabytes)
        XCTAssertEqual(size.value, 1.503, accuracy: 0.01)
    }

    func testProgressWithoutATotalIsIndeterminate() {
        // An offline dry run cannot say how big the download is; the bar has
        // to know not to sit at zero pretending to be stuck.
        let progress = DownloadProgress(fraction: 0, downloadedMB: 12, totalMB: 0)
        XCTAssertFalse(progress.isDeterminate)
        XCTAssertTrue(DownloadProgress(fraction: 0.1, downloadedMB: 12, totalMB: 120).isDeterminate)
    }
}
