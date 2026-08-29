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
    private let participants: [Participant]
    private let notes: [ScreenNote]
    private let skippedFrames: Int
    private let remarks: [String]

    public init(
        date: Date,
        duration: TimeInterval,
        videoFileName: String,
        summary: String,
        segments: [TranscriptSegment],
        hasMicrophoneLane: Bool,
        participants: [Participant] = [],
        notes: [ScreenNote] = [],
        skippedFrames: Int = 0,
        remarks: [String] = []
    ) {
        self.date = date
        self.duration = duration
        self.videoFileName = videoFileName
        self.summary = summary
        self.segments = segments
        self.hasMicrophoneLane = hasMicrophoneLane
        self.participants = participants
        // Useless frames are dropped once, here, so neither the counter nor
        // the feed has to remember to filter them again.
        self.notes = notes.filter(\.isUseful).sorted { $0.start < $1.start }
        self.skippedFrames = skippedFrames
        self.remarks = remarks
    }

    public func render() -> String {
        var lines: [String] = []

        lines.append("# Встреча \(Self.headerFormatter.string(from: date))")
        lines.append("")
        lines.append("**Длительность:** \(Self.clock(duration))  ")
        lines.append("**Запись:** `\(videoFileName)`")

        if !notes.isEmpty || skippedFrames > 0 {
            lines[lines.count - 1] += "  "
            lines.append(
                "**Кадров разобрано:** \(notes.count) из \(notes.count + skippedFrames)")
        }

        if !hasMicrophoneLane {
            lines.append("")
            lines.append(
                "> У этой встречи своя дорожка не записалась, поэтому всех "
                + "говорящих разделила модель — имена в ленте не проверены."
            )
        }

        if !participants.isEmpty {
            lines.append("")
            lines.append("## Участники")
            lines.append("")
            lines.append(
                "Имена взяты из интерфейса звонка и из реплик. Роли пока не "
                + "определяются автоматически — впишите их сами, если нужны. "
                + "Правьте прямо здесь: лента ниже подписана этими же именами."
            )
            lines.append("")
            lines.append("| Имя | Роль | Уверенность | На чём основано |")
            lines.append("|---|---|---|---|")
            for participant in participants {
                lines.append(
                    "| \(Self.cell(participant.name)) | \(Self.cell(participant.role ?? "—")) "
                    + "| \(participant.confidence.word) | \(Self.cell(participant.evidence)) |"
                )
            }
        }

        if !remarks.isEmpty {
            lines.append("")
            lines.append("### Замечания к разметке")
            lines.append("")
            for remark in remarks {
                lines.append("- \(remark)")
            }
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
        var pending = notes
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            let nextStart = isLast ? TimeInterval.greatestFiniteMagnitude : segments[index + 1].start
            let attached = pending.prefix { $0.start < nextStart }
            pending.removeFirst(attached.count)

            // The hard break belongs to a line that has a next line right
            // under it. A segment followed by a screen block does not.
            lines.append(attached.isEmpty && !isLast ? segment.line + "  " : segment.line)

            for note in attached {
                lines.append("")
                lines.append("> **Экран \(note.timecode) — \(note.title)**")
                if !note.details.isEmpty {
                    lines.append("> \(note.details)")
                }
                if let presenter = note.presenter {
                    lines.append("> Демонстрирует \(presenter).")
                }
                lines.append(">")
                lines.append("> ![\(Self.alt(note.title))](screens/\(note.fileName))")
                lines.append("")
            }
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

    /// A table cell holds text that came from the model. The evidence is a
    /// verbatim quote, and the parser upstream deliberately keeps any `|` it
    /// contains — unescaped, one such quote shifts its row's columns and
    /// usually wrecks the rest of the section.
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    /// Alt text sits inside `![…]`, where a bracket ends it early and takes
    /// the image link with it.
    private static func alt(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}
