import CyclopDictation
import Foundation

/// Sends audio to a Gemini-compatible endpoint and brings back text.
///
/// Shared by dictation and by meetings: both do the same thing — audio plus a
/// prompt into one model — and differ only in which prompt they send. Two
/// copies of this would drift apart at the first fix.
final class AudioTranscriptionClient {
    enum Failure: LocalizedError {
        case notConfigured
        case upstream(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "cloud recognition is not configured"
            case .upstream(let message): return message
            }
        }
    }

    /// Where the host lives. The token does not: `UserDefaults` writes a plist
    /// in the clear, and an API key has no business being there.
    static let hostKey = "cyclop.dictation.cloudHost"

    static var host: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }

    static var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !CloudCredentials.token.isEmpty
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Only the handshake is bounded. An hour of audio takes minutes to
        // come back, and cutting that off mid-flight throws away work already
        // paid for.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 1800
        session = URLSession(configuration: configuration)
    }

    /// The MIME type is a parameter and not a default: dictation sends wav and
    /// meetings send AAC in an MP4 container, and a default would quietly
    /// mislabel whichever caller forgot about it.
    func transcribe(
        audio: Data, mimeType: String, prompt: String, model: String
    ) async throws -> String {
        guard let endpoint = CloudTranscription.endpoint(host: Self.host, model: model) else {
            throw Failure.notConfigured
        }
        return try await send(
            CloudTranscription.requestBody(audio: audio, mimeType: mimeType, prompt: prompt),
            to: endpoint
        )
    }

    /// A text-only round trip, used for the summary of an already finished
    /// transcript.
    func complete(prompt: String, model: String) async throws -> String {
        guard let endpoint = CloudTranscription.endpoint(host: Self.host, model: model) else {
            throw Failure.notConfigured
        }
        return try await send(CloudTranscription.requestBody(prompt: prompt), to: endpoint)
    }

    private func send(_ body: Data, to endpoint: URL) async throws -> String {
        let token = CloudCredentials.token
        guard !token.isEmpty else { throw Failure.notConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.upstream(CloudTranscription.failure(from: data, status: status))
        }
        return try CloudTranscription.transcript(from: data)
    }
}
