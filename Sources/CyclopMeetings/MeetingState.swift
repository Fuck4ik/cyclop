import Foundation

/// Where a meeting is in its life.
public enum MeetingState: String, Codable, Sendable {
    case recording
    case processing
    case ready
    case failed
}

/// The status file inside a meeting folder.
///
/// Kept on disk rather than in memory so that an app closed mid-processing can
/// pick the meeting back up on the next launch: the recording is already made
/// and losing it to a restart is not acceptable.
public struct MeetingStateFile: Codable, Sendable {
    public let state: MeetingState
    public let duration: TimeInterval
    public let failure: String?

    public init(state: MeetingState, duration: TimeInterval, failure: String? = nil) {
        self.state = state
        self.duration = duration
        self.failure = failure
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MeetingStateFile {
        try JSONDecoder().decode(MeetingStateFile.self, from: data)
    }
}
