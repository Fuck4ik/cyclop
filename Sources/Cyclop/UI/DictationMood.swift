import Foundation

/// What the notch is doing, as far as the animation is concerned.
///
/// Kept apart from any one animation because every style needs it and none of
/// them owns it: the difference between hearing a voice and waiting on a
/// transcription is a fact about the app, not about how it is drawn.
enum DictationMood {
    /// Recording. There is a microphone to answer, and the animation follows it.
    case listening
    /// Transcribing. Nothing left to answer, so the animation is on its own —
    /// and says less, because at this point there is less to say.
    case thinking

    /// Listening is brisk, thinking is a slower swell — legible without reading
    /// a word of text.
    var speed: Double {
        switch self {
        case .listening: return 1.0
        case .thinking: return 0.5
        }
    }
}
