import Foundation

/// What Cyclop asks the Python worker to do. One request per line.
public enum WorkerRequest {
    case transcribe(path: String)
    case unload
    case ping
    /// Fetch the selected model if it is not on disk yet. Sent when recording
    /// starts rather than when it ends, so the weights arrive while someone is
    /// still speaking instead of afterwards.
    case ensureModel
    /// Fetch a model chosen from the catalog and dictate with it from now on.
    case download(id: String)
    /// Throw a model's weights away to get the disk space back.
    case delete(id: String)

    private struct Payload: Encodable {
        let cmd: String
        let path: String?
        let id: String?
    }

    public func encodedLine() throws -> String {
        let payload: Payload
        switch self {
        case .transcribe(let path): payload = Payload(cmd: "transcribe", path: path, id: nil)
        case .unload: payload = Payload(cmd: "unload", path: nil, id: nil)
        case .ping: payload = Payload(cmd: "ping", path: nil, id: nil)
        case .ensureModel: payload = Payload(cmd: "ensure", path: nil, id: nil)
        case .download(let id): payload = Payload(cmd: "download", path: nil, id: id)
        case .delete(let id): payload = Payload(cmd: "delete", path: nil, id: id)
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
    /// The model that produced `text`, straight from the worker's own
    /// `load_config()` rather than a string hard-coded on this side — the
    /// standalone WhisperDictation app can switch models from its own menu,
    /// and a fixed string here would go on claiming the old one afterwards.
    /// Optional because the worker itself only knows a real model once it
    /// has actually loaded config through `Engine._ensure()`.
    public let model: String?
    public let error: String?
    public let unloaded: Bool?
    public let freedMB: Double?
    /// A download in flight: how far along, and how much of it there is.
    public let progress: Double?
    public let downloadedMB: Double?
    public let totalMB: Double?
    /// The weights are on disk — either they already were, or they just
    /// finished arriving.
    public let ready: Bool?
    /// The catalog, answered by a one-shot `--models` run.
    public let models: [DictationModel]?
    /// Which model's weights were just thrown away.
    public let deleted: String?

    private enum CodingKeys: String, CodingKey {
        case text, took, model, error, unloaded, progress, ready, models, deleted
        case freedMB = "freed_mb"
        case downloadedMB = "downloaded_mb"
        case totalMB = "total_mb"
    }

    /// Python may also print warnings; anything unparseable is not a response.
    public static func decode(line: String) -> WorkerResponse? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(WorkerResponse.self, from: data)
    }
}
