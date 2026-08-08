import Foundation

/// One dictation, as it is stored in the history file.
///
/// The file is JSONL — one record per line — so a record must never encode
/// a newline of its own, and a corrupt line must cost only itself.
public struct DictationRecord: Codable, Identifiable, Equatable {
    public let at: Date
    public let text: String
    public let chars: Int
    /// File name inside the recordings folder, when the audio was kept.
    public let audio: String?
    public let took: Double
    public let model: String

    public var id: String { "\(at.timeIntervalSince1970)-\(chars)" }

    public init(text: String, audio: String?, took: Double, model: String, at: Date = Date()) {
        self.at = at
        self.text = text
        // Characters as a person counts them, not UTF-8 bytes: the number is
        // shown in the panel next to Russian text, where the two differ by two.
        self.chars = text.count
        self.audio = audio
        self.took = took
        self.model = model
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    /// Returns nil rather than throwing: one unreadable line is not a reason
    /// to lose the rest of the history.
    public static func decode(line: String) -> DictationRecord? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        return try? decoder.decode(DictationRecord.self, from: data)
    }

    public func encodedLine() throws -> String {
        let data = try Self.encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
