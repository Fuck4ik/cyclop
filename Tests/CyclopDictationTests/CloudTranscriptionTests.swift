import XCTest
@testable import CyclopDictation

final class CloudTranscriptionTests: XCTestCase {
    // MARK: - Endpoint

    func testBareHostGetsSchemeAndPath() {
        let url = CloudTranscription.endpoint(host: "127.0.0.1:8317")
        XCTAssertEqual(
            url?.absoluteString,
            "http://127.0.0.1:8317/v1beta/models/gemini-3.7-flash-high:generateContent"
        )
    }

    func testHttpsIsKept() {
        let url = CloudTranscription.endpoint(host: "https://proxy.example.com")
        XCTAssertEqual(
            url?.absoluteString,
            "https://proxy.example.com/v1beta/models/gemini-3.7-flash-high:generateContent"
        )
    }

    func testTrailingSlashesDoNotDoubleUp() {
        let url = CloudTranscription.endpoint(host: "http://localhost:8317///")
        XCTAssertEqual(
            url?.absoluteString,
            "http://localhost:8317/v1beta/models/gemini-3.7-flash-high:generateContent"
        )
    }

    /// Pasting the URL out of a curl command is the likeliest way to fill this
    /// field, and it must not produce the API path twice.
    func testPastedApiPathIsNotRepeated() {
        let url = CloudTranscription.endpoint(
            host: "http://localhost:8317/v1beta/models/gemini-3-flash:generateContent"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "http://localhost:8317/v1beta/models/gemini-3.7-flash-high:generateContent"
        )
    }

    func testModelIsSubstituted() {
        let url = CloudTranscription.endpoint(host: "localhost:8317", model: "gemini-3-flash")
        XCTAssertEqual(
            url?.absoluteString,
            "http://localhost:8317/v1beta/models/gemini-3-flash:generateContent"
        )
    }

    func testEmptyHostGivesNoEndpoint() {
        XCTAssertNil(CloudTranscription.endpoint(host: ""))
        XCTAssertNil(CloudTranscription.endpoint(host: "   "))
        XCTAssertNil(CloudTranscription.endpoint(host: "http://"))
    }

    // MARK: - Request

    private func inlineData(mimeType: String) throws -> [String: Any] {
        let body = try CloudTranscription.requestBody(
            audio: Data([1, 2, 3]), mimeType: mimeType, prompt: "расшифруй")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["text"] as? String, "расшифруй")
        return try XCTUnwrap(parts[1]["inline_data"] as? [String: Any])
    }

    func testRequestCarriesPromptThenAudio() throws {
        let inline = try inlineData(mimeType: CloudTranscription.wavMimeType)
        XCTAssertEqual(inline["mime_type"] as? String, "audio/wav")
        XCTAssertEqual(inline["data"] as? String, Data([1, 2, 3]).base64EncodedString())
    }

    /// Meetings send AAC inside an MP4 container, not wav. Labelling those
    /// bytes "audio/wav" is what the endpoint decodes by, and it rejects or
    /// misreads them — no meeting can finish while the label is wrong.
    func testMeetingAudioIsLabelledAsMp4() throws {
        let inline = try inlineData(mimeType: CloudTranscription.mp4AudioMimeType)
        XCTAssertEqual(inline["mime_type"] as? String, "audio/mp4")
        XCTAssertEqual(inline["data"] as? String, Data([1, 2, 3]).base64EncodedString())
    }

    func testTextOnlyRequestCarriesNoAudioPart() throws {
        let body = try CloudTranscription.requestBody(prompt: "составь итоги")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["text"] as? String, "составь итоги")
        XCTAssertNil(parts[0]["inline_data"])
    }

    /// The vocabulary is the reason the cloud mode is usable at all: without it
    /// the model transliterates every technical term into Cyrillic.
    func testDefaultPromptCarriesVocabularyAndFillerRule() {
        XCTAssertTrue(CloudTranscription.prompt.contains("pull request"))
        XCTAssertTrue(CloudTranscription.prompt.contains("Kubernetes"))
        XCTAssertTrue(CloudTranscription.prompt.contains("заполнители речи"))
        XCTAssertTrue(CloudTranscription.prompt.contains("а не пересказ"))
    }

    // MARK: - Response

    func testTranscriptIsRead() throws {
        let body = Data(
            """
            {"candidates":[{"content":{"parts":[{"text":"  Привет, это проверка.  "}]}}]}
            """.utf8
        )
        XCTAssertEqual(try CloudTranscription.transcript(from: body), "Привет, это проверка.")
    }

    /// A model that reasons out loud splits its answer across parts; keeping
    /// only the first would truncate the dictation without saying so.
    func testEveryTextPartIsKept() throws {
        let body = Data(
            """
            {"candidates":[{"content":{"parts":[{"text":"первая"},{"text":"вторая"}]}}]}
            """.utf8
        )
        XCTAssertEqual(try CloudTranscription.transcript(from: body), "первая\nвторая")
    }

    /// The dedicated speech model answers exactly like this over this endpoint:
    /// 200, a candidate, and no parts at all. It must read as "no speech",
    /// never as a crash.
    func testCandidateWithoutPartsGivesEmptyTranscript() throws {
        let body = Data(#"{"candidates":[{"content":{}}]}"#.utf8)
        XCTAssertEqual(try CloudTranscription.transcript(from: body), "")
    }

    func testEmptyResponseGivesEmptyTranscript() throws {
        XCTAssertEqual(try CloudTranscription.transcript(from: Data("{}".utf8)), "")
    }

    func testBrokenJsonThrows() {
        XCTAssertThrowsError(try CloudTranscription.transcript(from: Data("not json".utf8)))
    }

    // MARK: - Failure

    func testFailureMessageIsReadFromBody() {
        let body = Data(#"{"error":{"message":"unknown provider for model x"}}"#.utf8)
        XCTAssertEqual(
            CloudTranscription.failure(from: body, status: 502),
            "HTTP 502: unknown provider for model x"
        )
    }

    func testFailureFallsBackToStatus() {
        XCTAssertEqual(CloudTranscription.failure(from: Data("<html>".utf8), status: 500), "HTTP 500")
    }

    // MARK: - Images

    func testImageRequestCarriesPromptFirstThenEveryImage() throws {
        let body = try CloudTranscription.requestBody(
            prompt: "что на экране",
            images: [Data([0x01]), Data([0x02])],
            mimeType: CloudTranscription.jpegMimeType
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0]["text"] as? String, "что на экране")
        let first = try XCTUnwrap(parts[1]["inline_data"] as? [String: Any])
        XCTAssertEqual(first["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(first["data"] as? String, Data([0x01]).base64EncodedString())
    }

    func testImageRequestWithoutImagesIsStillValid() throws {
        let body = try CloudTranscription.requestBody(prompt: "текст", images: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 1)
    }
}
