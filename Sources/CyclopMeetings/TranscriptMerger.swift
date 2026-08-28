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

    public static func merge(
        microphone: [TranscriptSegment],
        system: [TranscriptSegment],
        ownerName: String
    ) -> [TranscriptSegment] {
        let trimmed = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = trimmed.isEmpty ? fallbackOwnerName : trimmed

        let mine = microphone.map {
            TranscriptSegment(start: $0.start, speaker: owner, text: $0.text)
        }
        // Stable by construction: on an equal timecode the owner's line comes
        // first, because `mine` is enumerated before `system` and the sort
        // below only compares start times.
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
