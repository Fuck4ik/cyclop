import Foundation

/// How far processing got.
///
/// The frame stages are expensive — decoding a frame is cheap, sending it to a
/// vision model is not — so a run interrupted after them must not pay twice.
/// Every field defaults to false so that a file written by an older version
/// decodes into «nothing done yet» rather than failing.
public struct MeetingStages: Codable, Sendable, Equatable {
    public var transcribed: Bool
    public var framesPlanned: Bool
    public var framesExtracted: Bool
    public var framesRead: Bool
    public var participantsResolved: Bool

    public init(
        transcribed: Bool = false,
        framesPlanned: Bool = false,
        framesExtracted: Bool = false,
        framesRead: Bool = false,
        participantsResolved: Bool = false
    ) {
        self.transcribed = transcribed
        self.framesPlanned = framesPlanned
        self.framesExtracted = framesExtracted
        self.framesRead = framesRead
        self.participantsResolved = participantsResolved
    }
}

/// Where a meeting is in its life.
public enum MeetingState: String, Codable, Sendable {
    case recording
    case processing
    case ready
    case failed
}

/// Why a meeting is not finished.
///
/// A code rather than a sentence. The reason is written into `.state.json` by
/// code that has no string table — this library is not the app — and it is
/// read back much later, possibly after the app's language was switched: a
/// stored Russian sentence would stay Russian for good. The pane turns these
/// codes back into words in the language being read.
///
/// Anything this list cannot name — an HTTP message from the proxy, a file
/// system error — travels as `.message` and is shown exactly as it arrived.
/// Such text has no translation to lose, and an unrecognised code from a
/// future version degrades into it rather than into nothing.
public enum MeetingFailure: Equatable, Sendable {
    /// The model answered and nothing in the answer parsed as a reply.
    case nothingRecognised
    /// The app was quit while this meeting was still recording.
    case closedWhileRecording
    /// The folder is claimed as recording or processing by a run of the app
    /// that is no longer alive.
    case interrupted
    /// The folder holds no readable `.state.json` at all.
    case missingStateFile
    /// Something already in words, with no code of its own.
    case message(String)

    /// The dotted prefix keeps these apart from any message text: nothing a
    /// proxy or the file system produces looks like this.
    private static let prefix = "cyclop.meeting.failure."

    public var stored: String {
        switch self {
        case .nothingRecognised: return Self.prefix + "nothingRecognised"
        case .closedWhileRecording: return Self.prefix + "closedWhileRecording"
        case .interrupted: return Self.prefix + "interrupted"
        case .missingStateFile: return Self.prefix + "missingStateFile"
        case .message(let text): return text
        }
    }

    public init(stored: String) {
        switch stored {
        case Self.nothingRecognised.stored: self = .nothingRecognised
        case Self.closedWhileRecording.stored: self = .closedWhileRecording
        case Self.interrupted.stored: self = .interrupted
        case Self.missingStateFile.stored: self = .missingStateFile
        default: self = .message(stored)
        }
    }
}

/// The status file inside a meeting folder.
///
/// Kept on disk rather than in memory so that an app closed mid-processing can
/// pick the meeting back up on the next launch: the recording is already made
/// and losing it to a restart is not acceptable.
public struct MeetingStateFile: Codable, Sendable {
    public let state: MeetingState
    public let duration: TimeInterval
    /// See `MeetingRecording.microphoneOffset`. Optional so that a file
    /// written before this field existed still decodes — losing the offset
    /// costs a shifted owner lane, losing the whole file costs the meeting.
    public let microphoneOffset: TimeInterval?
    /// Optional so that a file written before stages existed still decodes —
    /// losing it costs the meeting, and the recording cannot be made again.
    public let stages: MeetingStages?
    public let failure: String?

    public init(
        state: MeetingState,
        duration: TimeInterval,
        microphoneOffset: TimeInterval? = nil,
        stages: MeetingStages? = nil,
        failure: String? = nil
    ) {
        self.state = state
        self.duration = duration
        self.microphoneOffset = microphoneOffset
        self.stages = stages
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
