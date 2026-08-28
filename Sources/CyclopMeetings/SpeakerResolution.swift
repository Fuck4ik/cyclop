import Foundation

/// One diarisation label tied to one person.
///
/// `splitAt` exists because the model does not only mislabel, it mis-splits:
/// on a real meeting a single label held the person who opened the call and
/// the architect who spoke an hour later. Renaming such a label is worse than
/// leaving it — half the lines get the wrong name — so the boundary travels
/// with the resolution.
public struct SpeakerResolution: Equatable, Sendable {
    public let label: String
    public let name: String
    public let confidence: Participant.Confidence
    public let evidence: String
    public let splitAt: TimeInterval?
    public let splitName: String?

    public init(
        label: String,
        name: String,
        confidence: Participant.Confidence,
        evidence: String,
        splitAt: TimeInterval?,
        splitName: String?
    ) {
        self.label = label
        self.name = name
        self.confidence = confidence
        self.evidence = evidence
        self.splitAt = splitAt
        self.splitName = splitName
    }
}

public enum SpeakerResolutionParser {
    /// `Label = Name | confidence | evidence` with an optional
    /// `| split HH:MM:SS Other Name` tail.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\**([^=|]+?)\**\s*=\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]*?)(?:\s*\|\s*split\s+(\d{1,2}):(\d{2}):(\d{2})\s+(.+?))?\s*$"#
    )

    public static func resolutions(from text: String) -> [SpeakerResolution] {
        var resolutions: [SpeakerResolution] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = pattern.firstMatch(in: line, range: range) else { continue }

            let label = string(match, 1, in: line).trimmingCharacters(in: .whitespaces)
            let name = string(match, 2, in: line).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !name.isEmpty else { continue }

            var splitAt: TimeInterval?
            var splitName: String?
            if let hours = Int(string(match, 5, in: line)),
               let minutes = Int(string(match, 6, in: line)),
               let seconds = Int(string(match, 7, in: line)) {
                splitAt = TimeInterval(hours * 3600 + minutes * 60 + seconds)
                let tail = string(match, 8, in: line).trimmingCharacters(in: .whitespaces)
                splitName = tail.isEmpty ? nil : tail
            }

            resolutions.append(SpeakerResolution(
                label: label,
                name: name,
                confidence: confidence(from: string(match, 3, in: line)),
                evidence: string(match, 4, in: line).trimmingCharacters(in: .whitespaces),
                splitAt: splitName == nil ? nil : splitAt,
                splitName: splitName
            ))
        }
        return resolutions
    }

    /// An unrecognised word degrades to the lowest confidence rather than
    /// dropping the line: a name with a cautious label still beats a number.
    private static func confidence(from raw: String) -> Participant.Confidence {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "факт", "fact": return .fact
        case "высокая", "high": return .high
        case "средняя", "medium": return .medium
        default: return .low
        }
    }

    private static func string(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String {
        guard let range = Range(match.range(at: index), in: line) else { return "" }
        return String(line[range])
    }
}

public enum SpeakerRelabeler {
    /// Labels the model said nothing about keep their number: an invented name
    /// is worse than an honest «Участник 3».
    public static func apply(
        _ resolutions: [SpeakerResolution], to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !resolutions.isEmpty else { return segments }
        let byLabel = Dictionary(resolutions.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })

        return segments.map { segment in
            guard let resolution = byLabel[segment.speaker] else { return segment }
            let name: String
            if let splitAt = resolution.splitAt, let splitName = resolution.splitName,
               segment.start >= splitAt {
                name = splitName
            } else {
                name = resolution.name
            }
            return TranscriptSegment(start: segment.start, speaker: name, text: segment.text)
        }
    }
}
