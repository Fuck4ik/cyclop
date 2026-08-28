import Foundation

/// One line of a transcript: who spoke, when, and what was said.
///
/// The timecode is stored as seconds from the start of the recording rather
/// than as text, because chunks of a long meeting are transcribed separately
/// and every one of them counts from its own zero — arithmetic has to work.
public struct TranscriptSegment: Equatable, Sendable {
    public let start: TimeInterval
    public let speaker: String
    public let text: String

    public init(start: TimeInterval, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }

    public var timecode: String {
        let total = Int(start.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// The exact shape the transcript file uses, and the one the model is asked
    /// to produce — parser and writer stay in sync through this one property.
    public var line: String {
        "**[\(timecode)] \(speaker):** \(text)"
    }

    public func shifted(by offset: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(start: start + offset, speaker: speaker, text: text)
    }
}
