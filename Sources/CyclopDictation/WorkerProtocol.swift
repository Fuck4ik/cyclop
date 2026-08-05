import Foundation

/// What Cyclop asks the Python worker to do. One request per line.
public enum WorkerRequest {
    case transcribe(path: String)
    case unload
    case ping

    private struct Payload: Encodable {
        let cmd: String
        let path: String?
    }

    public func encodedLine() throws -> String {
        let payload: Payload
        switch self {
        case .transcribe(let path): payload = Payload(cmd: "transcribe", path: path)
        case .unload: payload = Payload(cmd: "unload", path: nil)
        case .ping: payload = Payload(cmd: "ping", path: nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}

/// One line of the worker's stdout. Every field is optional because the same
/// shape carries a transcription, an unload report and a failure.
public struct WorkerResponse: Decodable {
    public let text: String?
    public let took: Double?
    public let language: String?
    public let error: String?
    public let unloaded: Bool?
    public let freedMB: Double?

    private enum CodingKeys: String, CodingKey {
        case text, took, language, error, unloaded
        case freedMB = "freed_mb"
    }

    /// Python may also print warnings; anything unparseable is not a response.
    public static func decode(line: String) -> WorkerResponse? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(WorkerResponse.self, from: data)
    }
}
