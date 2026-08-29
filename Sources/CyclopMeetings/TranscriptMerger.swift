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

    public static func merge(
        microphone: [TranscriptSegment],
        system: [TranscriptSegment],
        ownerName: String
    ) -> [TranscriptSegment] {
        let owner = ownerLabel(for: ownerName)

        let mine = microphone.map {
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
