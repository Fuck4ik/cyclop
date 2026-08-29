import Foundation

/// Recognition that happens on someone else's machine.
///
/// The audio goes to a Gemini-compatible endpoint — in practice a CLIProxyAPI
/// instance — and comes back as text. Two things make this worth having next to
/// the local worker: nothing is downloaded, and the Python process stays down,
/// which is where most of dictation's memory goes.
///
/// Only `generateContent` is used. The dedicated speech model answers a
/// different endpoint and ignores the prompt entirely, so it cannot be told to
/// keep English terms in English — the whole point of the prompt below.
public enum CloudTranscription {
    /// The model that reads the audio. A general model rather than a
    /// speech-to-text one, because only a general model follows instructions.
    public static let defaultModel = "gemini-3.7-flash-high"

    /// Carries the same vocabulary as the local worker's `initial_prompt`, for
    /// the same reason: dictation is full of English technical terms, and
    /// without this they come back transliterated into Cyrillic. The trailing
    /// instruction is what removes fillers — a general "remove filler words"
    /// makes the model rewrite whole sentences, while an explicit list does not.
    public static let prompt = """
        Это диктовка на русском языке для разработчика. Английские термины, \
        бренды и названия пиши на английском, без транслита. \
        Vocabulary: API, SDK, CLI, Claude, ChatGPT, Gemini, OpenAI, Anthropic, \
        Google, Telegram, Cyclop, GitHub, GitLab, pull request, merge, commit, \
        branch, rebase, deploy, staging, production, rollback, hotfix, OAuth, \
        JWT, JSON, YAML, REST, gRPC, GraphQL, Kubernetes, Docker, Terraform, \
        Grafana, Sentry, Postgres, Redis, Kafka, frontend, backend, latency, \
        throughput, Python, JavaScript, TypeScript, React, SwiftUI, AppKit, \
        Xcode, Swift, LLM, embedding, RAG, Whisper, MLX. \
        Расшифруй запись. Убирай заполнители речи (э, э-э, м-м, ну, вот, \
        короче, как бы, типа, этот самый) и оборванные самоповторы. Слова \
        говорящего, порядок мыслей и формулировки сохраняй как есть — это \
        расшифровка, а не пересказ. Верни только текст расшифровки.
        """

    /// Where the request goes, given what someone typed into settings.
    ///
    /// The host is typed by hand, so it arrives in every shape: with a scheme
    /// and without, with a trailing slash, with the API path already appended.
    /// Returns nil when nothing usable can be made of it — an empty field is
    /// the normal case, not an error worth reporting.
    public static func endpoint(host: String, model: String = defaultModel) -> URL? {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A bare host means http: this is normally a proxy on the same machine
        // or a private network, where demanding TLS would just be wrong.
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        // Someone who pastes the full URL from a curl command should not end up
        // with the path twice over.
        if let range = trimmed.range(of: "/v1beta") {
            trimmed = String(trimmed[trimmed.startIndex..<range.lowerBound])
        }
        guard !trimmed.isEmpty, let base = URL(string: trimmed), base.host != nil else {
            return nil
        }
        return URL(string: "\(trimmed)/v1beta/models/\(model):generateContent")
    }

    /// Dictation records raw PCM into a wav file.
    public static let wavMimeType = "audio/wav"

    /// Meetings send an AAC track inside an MP4 container — `.m4a` on disk.
    /// The bytes start with `ftyp`, not `RIFF`, and a wav label over them is
    /// not a cosmetic mistake: the endpoint decodes by the declared type and
    /// answers with a rejection or with noise.
    public static let mp4AudioMimeType = "audio/mp4"

    /// Image format for meeting frames.
    public static let jpegMimeType = "image/jpeg"

    /// The request body: the prompt, then the recording inline.
    ///
    /// The type is passed rather than assumed: the two callers send two
    /// different containers, and only the caller knows which.
    public static func requestBody(
        audio: Data,
        mimeType: String,
        prompt: String = prompt
    ) throws -> Data {
        let payload = Request(
            contents: [
                Request.Content(
                    role: "user",
                    parts: [
                        .init(text: prompt, inlineData: nil),
                        .init(
                            text: nil,
                            inlineData: .init(
                                mimeType: mimeType,
                                data: audio.base64EncodedString()
                            )
                        ),
                    ]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    /// The same request without audio: the summary step sends a finished
    /// transcript as text, and an empty `inline_data` would be rejected.
    public static func requestBody(prompt: String) throws -> Data {
        let payload = Request(
            contents: [
                Request.Content(
                    role: "user",
                    parts: [.init(text: prompt, inlineData: nil)]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    /// Several frames in one request: the prompt names each frame by its
    /// timecode, so the order of the images is a convenience and not a
    /// contract. Batching is what keeps a meeting's worth of frames inside the
    /// request quota.
    public static func requestBody(
        prompt: String, images: [Data], mimeType: String = jpegMimeType
    ) throws -> Data {
        let payload = Request(
            contents: [
                Request.Content(
                    role: "user",
                    parts: [.init(text: prompt, inlineData: nil)]
                        + images.map {
                            .init(
                                text: nil,
                                inlineData: .init(
                                    mimeType: mimeType, data: $0.base64EncodedString()))
                        }
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    /// The transcript out of a successful response.
    ///
    /// Every text part is joined: a model that thinks out loud splits its answer
    /// across parts, and dropping all but the first would silently truncate the
    /// dictation. An empty result means no speech was recognised, which the
    /// caller treats as "nothing to insert" rather than as a failure.
    public static func transcript(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let text = response.candidates?
            .compactMap(\.content?.parts)
            .flatMap { $0 }
            .compactMap(\.text)
            .joined(separator: "\n") ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The message inside an error response, for the log and the panel.
    public static func failure(from data: Data, status: Int) -> String {
        if let response = try? JSONDecoder().decode(ErrorResponse.self, from: data),
            let message = response.error?.message, !message.isEmpty
        {
            return "HTTP \(status): \(message)"
        }
        return "HTTP \(status)"
    }

    // MARK: - Wire format

    private struct Request: Encodable {
        struct Content: Encodable {
            struct Part: Encodable {
                let text: String?
                let inlineData: InlineData?

                enum CodingKeys: String, CodingKey {
                    case text
                    case inlineData = "inline_data"
                }
            }

            struct InlineData: Encodable {
                let mimeType: String
                let data: String

                enum CodingKeys: String, CodingKey {
                    case mimeType = "mime_type"
                    case data
                }
            }

            let role: String
            let parts: [Part]
        }

        let contents: [Content]
    }

    private struct Response: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                }

                let parts: [Part]?
            }

            let content: Content?
        }

        let candidates: [Candidate]?
    }

    private struct ErrorResponse: Decodable {
        struct Failure: Decodable {
            let message: String?
        }

        let error: Failure?
    }
}
