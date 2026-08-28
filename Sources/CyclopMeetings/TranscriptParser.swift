import Foundation

/// Turns the model's answer into segments.
///
/// Deliberately forgiving. The model is asked for one exact shape, but it
/// drifts: asterisks disappear, an hour-less timecode shows up, an
/// introductory sentence gets added on top. A transcript is worth keeping
/// even when its formatting slipped, so anything with a timecode is taken and
/// everything else is skipped.
public enum TranscriptParser {
    /// `**[01:02:03] Speaker:** text`, with the asterisks and the hours
    /// optional.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\**\[(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\]\s*([^:*]+?)\**\s*:\**\s*(.*)$"#
    )

    public static func segments(from text: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = pattern.firstMatch(in: line, range: range) else {
                // A line without a timecode is either a preamble before the
                // first segment (dropped) or a speech that wrapped (kept).
                if let last = segments.popLast() {
                    segments.append(TranscriptSegment(
                        start: last.start,
                        speaker: last.speaker,
                        text: "\(last.text) \(line)"
                    ))
                }
                continue
            }

            let hours = number(match, 1, in: line) ?? 0
            let minutes = number(match, 2, in: line) ?? 0
            let seconds = number(match, 3, in: line) ?? 0
            let speaker = string(match, 4, in: line).trimmingCharacters(in: .whitespaces)
            let body = string(match, 5, in: line).trimmingCharacters(in: .whitespaces)
            guard !speaker.isEmpty else { continue }

            segments.append(TranscriptSegment(
                start: TimeInterval(hours * 3600 + minutes * 60 + seconds),
                speaker: speaker,
                text: body
            ))
        }
        return segments
    }

    private static func string(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String {
        guard let range = Range(match.range(at: index), in: line) else { return "" }
        return String(line[range])
    }

    private static func number(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> Int? {
        Int(string(match, index, in: line))
    }
}
