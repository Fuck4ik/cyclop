import Foundation

/// What processing is busy with right now.
///
/// A value rather than a finished line, for the same reason `MeetingFailure`
/// is a code: the processor lives outside the app's string table, while the
/// step is shown to someone who may be reading either language. The pane puts
/// it into words.
public enum MeetingProgress: Equatable, Sendable {
    /// Which of the two recordings is being sent.
    public enum Lane: Equatable, Sendable {
        /// Everyone else: the audio track inside `meeting.mp4`.
        case system
        /// The owner of this Mac: `mic.m4a`.
        case microphone
    }

    /// Between the stop and the first request: folders, scratch space, the
    /// duration of what was recorded.
    case preparing
    /// One chunk of one lane, counted from 1 so it can be shown as is.
    case lane(Lane, index: Int, count: Int)
    /// The last request, the one that writes «Итоги».
    case summary
    /// One batch of frames on its way to the model, counted from 1.
    case frames(index: Int, count: Int)
    /// The request that turns «Участник 2» into a name.
    case participants
}
