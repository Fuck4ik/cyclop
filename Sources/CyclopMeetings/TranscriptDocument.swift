import Foundation

/// The `transcript.md` that ends up next to the recording.
///
/// Assembled here rather than while writing to disk so the shape can be
/// checked without a file system, and so a failed summary costs only its own
/// section: the transcript is the part that cannot be produced again, and it
/// is written no matter what else went wrong.
public struct TranscriptDocument {
    private let date: Date
    private let duration: TimeInterval
    private let videoFileName: String
    private let summary: String
    private let segments: [TranscriptSegment]
    private let hasMicrophoneLane: Bool

    public init(
        date: Date,
        duration: TimeInterval,
        videoFileName: String,
        summary: String,
        segments: [TranscriptSegment],
        hasMicrophoneLane: Bool
    ) {
        self.date = date
        self.duration = duration
        self.videoFileName = videoFileName
        self.summary = summary
        self.segments = segments
        self.hasMicrophoneLane = hasMicrophoneLane
    }

    public func render() -> String {
        var lines: [String] = []

        lines.append("# Встреча \(Self.headerFormatter.string(from: date))")
        lines.append("")
        lines.append("**Длительность:** \(Self.clock(duration))  ")
        lines.append("**Запись:** `\(videoFileName)`")

        if !hasMicrophoneLane {
            lines.append("")
            lines.append(
                "> У этой встречи своя дорожка не записалась, поэтому всех "
                + "говорящих разделила модель — имена в ленте не проверены."
            )
        }

        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryText.isEmpty {
            lines.append("")
            lines.append("## Итоги")
            lines.append("")
            lines.append(summaryText)
        }

        lines.append("")
        lines.append("## Расшифровка")
        lines.append("")
        // Two trailing spaces are a Markdown hard break, the same one the
        // duration line above carries. Without them every renderer folds the
        // whole feed into a single soft-wrapped paragraph — the transcript is
        // the point of this file, and one paragraph is unreadable. The last
        // line gets none: there is nothing after it to break away from, and
        // the file would end in stray whitespace.
        for (index, segment) in segments.enumerated() {
            lines.append(index == segments.count - 1 ? segment.line : segment.line + "  ")
        }
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private static let headerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    private static func clock(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
