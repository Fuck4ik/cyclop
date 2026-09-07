import Foundation

/// Whether a recorded lane holds speech at all.
///
/// This exists because of what a transcription model does with silence: it
/// invents. A lane of digital zeroes — not one non-zero sample in it — came
/// back as a fluent 619-character briefing about deployment rules, complete
/// with names, decisions and a deadline, its vocabulary lifted from the
/// prompt's own glossary. Nothing in such an answer marks it as fiction, and
/// it lands in transcript.md looking exactly like a meeting that happened. So
/// a lane is measured before it is sent, and silence is never paid for or
/// believed.
public enum SpeechLevel {
    /// How long a window the level is judged over.
    ///
    /// Short enough that a pause between sentences does not swallow the
    /// speech around it, long enough that one loud sample cannot carry a
    /// window on its own.
    public static let windowDuration: Double = 0.1

    /// A window whose RMS reaches this, in dBFS, counts as sound.
    ///
    /// RMS rather than peak, and this is the whole reason the measurement is
    /// not a one-line maximum: a lane holding nothing but clicks peaked at
    /// -14.6 dBFS, louder than a lane of real but quiet speech at -14.2. A
    /// peak cannot tell those apart. Averaged over a tenth of a second, the
    /// click is 0.5 s of sound and the conversation is 33.5 s.
    public static let windowThreshold: Double = -45

    /// Total seconds of sound below which a lane holds no speech.
    ///
    /// Measured, not chosen. Across the recordings on hand, every lane that
    /// really carried a conversation reached at least 33.5 s of sound, while
    /// every lane that did not stayed at or under 1.7 s — an empty room, a
    /// muted call, a track of zeroes. Five sits between those two populations
    /// with room on both sides, and errs toward sending: the cost of a wrong
    /// "no speech" is a meeting the pane refuses to transcribe until asked
    /// twice, while the cost of a wrong "speech" is only the invented
    /// transcript this type exists to prevent.
    public static let minimumVoicedSeconds: Double = 5

    /// Window RMS as dBFS. A silent window is -infinity rather than a
    /// division that traps: a lane of zeroes is the normal case here.
    public static func decibels(rms: Double) -> Double {
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }

    /// Whether one window counts toward the sounding total. A negative RMS is
    /// impossible to measure and reads as silence — see `carriesSpeech`.
    public static func isSound(rms: Double) -> Bool {
        decibels(rms: rms) >= windowThreshold
    }

    /// Whether a lane that sounded for this long is worth transcribing.
    public static func carriesSpeech(voicedSeconds: Double) -> Bool {
        voicedSeconds >= minimumVoicedSeconds
    }
}
