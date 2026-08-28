import CyclopDictation
import Foundation

/// Dictation's use of the shared transcription client: one prompt, one model,
/// a wav file on disk.
final class CloudTranscriber {
    typealias Failure = AudioTranscriptionClient.Failure

    static var host: String {
        get { AudioTranscriptionClient.host }
        set { AudioTranscriptionClient.host = newValue }
    }

    static var isConfigured: Bool { AudioTranscriptionClient.isConfigured }

    private let client = AudioTranscriptionClient()

    func transcribe(wav url: URL) async throws -> String {
        try await client.transcribe(
            audio: Data(contentsOf: url),
            prompt: CloudTranscription.prompt,
            model: CloudTranscription.defaultModel
        )
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
