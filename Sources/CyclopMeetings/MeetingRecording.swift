import Foundation

/// What the recorder measured about a finished recording, and everything
/// processing needs to know about it.
///
/// Kept as one value because all of it also has to survive a relaunch: a
/// meeting retried tomorrow must be processed exactly like one retried a
/// second after it stopped.
public struct MeetingRecording: Equatable, Sendable {
    /// Wall-clock time between the start and the stop.
    public let duration: TimeInterval

    /// Whether `mic.m4a` got any samples at all. False means the transcript
    /// has no owner lane and every name in it is the model's guess.
    public let hasMicrophoneLane: Bool

    /// How far into the capture the microphone track actually begins.
    ///
    /// `mic.m4a` starts its session at the first microphone sample, while
    /// `meeting.mp4` starts at the beginning of the capture. Those two zeros
    /// are not the same instant — the microphone permission prompt lands in
    /// exactly that gap — and the merge weaves the lanes by timecode, so
    /// without this every owner line would sit however many seconds early
    /// for the whole meeting.
    public let microphoneOffset: TimeInterval

    public init(duration: TimeInterval, hasMicrophoneLane: Bool, microphoneOffset: TimeInterval) {
        self.duration = duration
        self.hasMicrophoneLane = hasMicrophoneLane
        self.microphoneOffset = microphoneOffset
    }
}
