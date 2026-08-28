import CyclopDictation
import Foundation

/// Sends a recording to a Gemini-compatible endpoint and brings back the text.
///
/// Deliberately thin: everything worth testing — the URL, the body, the reply —
/// lives in `CloudTranscription` inside the library, because SwiftPM will not
/// let tests import an executable target.
final class CloudTranscriber {
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

    /// Both halves have to be present before the cloud row can be picked:
    /// a host without a token gets a 401, which reads to the user as "broken".
    static var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !CloudCredentials.token.isEmpty
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Only the handshake is bounded. An hour of audio takes minutes to come
        // back, and cutting that off mid-flight would throw away work already
        // paid for; a dictation take is short, so the ceiling is generous
        // rather than tight.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
    }

    func transcribe(wav url: URL) async throws -> String {
        guard let endpoint = CloudTranscription.endpoint(host: Self.host) else {
            throw Failure.notConfigured
        }
        let token = CloudCredentials.token
        guard !token.isEmpty else { throw Failure.notConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try CloudTranscription.requestBody(wav: Data(contentsOf: url))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.upstream(CloudTranscription.failure(from: data, status: status))
        }
        return try CloudTranscription.transcript(from: data)
    }
}

/// The API token, kept in the keychain.
///
/// Stored per-account under one service so that reading it never prompts: the
/// item is created by this app and stays accessible while the Mac is unlocked.
enum CloudCredentials {
    private static let service = "com.cyclop.app.dictation"
    private static let account = "cloud-token"

    static var token: String {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                let data = item as? Data
            else {
                return ""
            }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            // Clearing the field must remove the item, not store an empty
            // string — otherwise `isConfigured` would keep saying yes.
            SecItemDelete(base as CFDictionary)
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            var attributes = base
            attributes[kSecValueData as String] = Data(trimmed.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status != errSecSuccess {
                NSLog("Cyclop: could not store the cloud token (OSStatus \(status))")
            }
        }
    }
}
