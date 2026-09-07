import Foundation

/// Weaves the two lanes of a meeting into one transcript.
///
/// The microphone lane is the owner of the Mac and nobody else, so its label
/// is a fact rather than the model's guess. The system lane holds everyone
/// else, and its numbering is left exactly as the model produced it: renaming
/// "Участник 2" into "Участник 1" because the owner took the first slot would
/// break the correspondence between the numbers and the voices.
public enum TranscriptMerger {
    /// Used when the owner has not filled his name in settings. Better than an
    /// empty label, which would render as "**[00:00:00] :** …".
    private static let fallbackOwnerName = "Я"

    /// A name typed by hand never approaches this; a name pasted from the
    /// clipboard can run to kilobytes and has, in practice, already ended up
    /// stored this way — see `sanitizedOwnerName(_:)`.
    private static let maxOwnerNameLength = 64

    /// The one rule for turning whatever landed in the name field into
    /// something fit to sign a lane with. Used both where Settings writes the
    /// value (so a fresh paste never gets further than this) and where this
    /// type reads it back (so a value already corrupted on disk — from before
    /// this rule existed, or from any other path that skipped it — still
    /// renders safely). One function so the two call sites cannot drift the
    /// way two separate copies of this already have in this project.
    public static func sanitizedOwnerName(_ name: String) -> String {
        // Every run of whitespace — including the newlines a clipboard paste
        // carries — collapses to one plain space, not just the edges: a name
        // pasted with line breaks in the middle must still read as one label
        // rather than stretch the transcript across several lines.
        let collapsed = name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Clamped by Character, not by UTF-8 byte count, so a multi-byte
        // grapheme — Cyrillic included — is never cut in half.
        return String(collapsed.prefix(maxOwnerNameLength))
    }

    /// The label the owner's lane actually carries, sanitized and with the
    /// fallback applied. Public because the processor has to subtract exactly
    /// this string, and computing it twice is how the two drifted apart.
    public static func ownerLabel(for ownerName: String) -> String {
        let sanitized = sanitizedOwnerName(ownerName)
        return sanitized.isEmpty ? fallbackOwnerName : sanitized
    }

    /// How far apart two lines may start and still be the same sound.
    ///
    /// The lanes are transcribed by separate requests, which cut the same
    /// speech into different segments and each stamp their own start, so one
    /// moment reaches this function several seconds apart. Three was tried
    /// first and let through an echo that matched word for word — «Ещё раз
    /// что-нибудь скажите, пожалуйста» against itself, stamped 01:15 and
    /// 01:18, which is three by the printed timecode and more than three
    /// underneath it, since a timecode is floored on the way to the page.
    /// Five holds every echo measured on that call while the nearest line
    /// that is really the owner's own stays at 0.40 similarity — well under
    /// the threshold below, so the wider window costs nothing.
    private static let echoWindow: TimeInterval = 5

    /// Share of a microphone line's words that must also appear in a system
    /// line nearby for it to be that line coming back through the speakers.
    ///
    /// Measured over every one of an hour-long call's 215 owner lines, taken
    /// without headphones. Sorted by this share, the two kinds separate: the
    /// lowest echo scores 0.50 — «Вот это хороший, да, детальный момент»
    /// against «Вот это хороший деталь, ладно» — and the highest line that is
    /// really the owner's own scores 0.38. Half sits in that gap.
    ///
    /// Two transcriptions of one sound never match word for word, which is
    /// why this is a share rather than equality, and why the share has to be
    /// this forgiving: an echo of «Давай, давай, Кать. Давай, давай» came
    /// back as «Да-да, давай, Кать. Давай-давай», and the interjections the
    /// microphone added to it drag the score down to 0.67. Dropping short
    /// words to compensate was tried and made it worse — echo bunches up at
    /// exactly 2/3 once they are gone.
    private static let echoOverlap = 0.5

    /// Whether `text` is `other` heard again through the room.
    ///
    /// Directional on purpose: the microphone line is the one that may be an
    /// echo of the system line, never the reverse — the system lane cannot
    /// hear the room. The share is taken over the microphone line's own
    /// words, so a short «Да-да, слышно» is recognised inside a long answer
    /// that contains it.
    static func isEcho(_ text: String, of other: String) -> Bool {
        let mine = words(in: text)
        guard !mine.isEmpty else { return false }
        let theirs = Set(words(in: other))
        let shared = mine.filter { theirs.contains($0) }.count
        return Double(shared) / Double(mine.count) >= echoOverlap
    }

    /// Lowercased word stems, punctuation dropped: the two lanes are
    /// transcribed by separate requests and punctuate the same sentence
    /// differently every time.
    private static func words(in text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }

    public static func merge(
        microphone: [TranscriptSegment],
        system: [TranscriptSegment],
        ownerName: String
    ) -> [TranscriptSegment] {
        let owner = ownerLabel(for: ownerName)

        // Without headphones the microphone records the call twice over: the
        // owner, and everyone else coming back out of the speakers. Both
        // lanes are then transcribed, and the transcript carries every remark
        // of every participant a second time under the owner's name — 178 of
        // 215 lines on the call this was measured on. Dropping them here
        // rather than at capture time also repairs recordings already made;
        // `MeetingRecorder` stops the echo reaching the file at all, but only
        // for meetings recorded after it.
        let mine = microphone
            .filter { line in
                !system.contains { other in
                    abs(other.start - line.start) <= echoWindow && isEcho(line.text, of: other.text)
                }
            }
            .map {
                TranscriptSegment(start: $0.start, speaker: owner, text: $0.text)
            }
        // Stable by hand: sorted(by:) gives no stability guarantee, so the
        // position in the concatenated array is carried along and breaks
        // every tie. `mine` comes first in that array, which is why on an
        // equal timecode the owner's line lands above the system lane's.
        return (mine + system).enumerated()
            .sorted { left, right in
                if left.element.start == right.element.start {
                    return left.offset < right.offset
                }
                return left.element.start < right.element.start
            }
            .map(\.element)
    }
}
