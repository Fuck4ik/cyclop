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
    /// The split tail, cut off before the rest is read.
    ///
    /// It used to be one branch of a single pattern covering the whole line,
    /// and that made the line all-or-nothing: a stray `|` inside the evidence,
    /// or a `split` with no name after it, dropped the resolution entirely —
    /// name, confidence and all. The parser has to degrade the way
    /// `TranscriptParser` does, keeping whatever it could read.
    private static let splitTail = try! NSRegularExpression(
        pattern: #"\s*\|\s*split\s+(\d{1,2}):(\d{2}):(\d{2})(?:\s+(.+?))?\s*$"#
    )

    /// Asterisks and spaces, stripped from the ends of every field: the model
    /// writes whole lines in bold, and a trailing pair used to ride into the
    /// split name and from there into the speaker's displayed name.
    private static let decoration = CharacterSet(charactersIn: "* ")

    public static func resolutions(from text: String) -> [SpeakerResolution] {
        var resolutions: [SpeakerResolution] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: decoration)
            guard !line.isEmpty else { continue }

            var splitAt: TimeInterval?
            var splitName: String?
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = splitTail.firstMatch(in: line, range: range),
               let hours = Int(string(match, 1, in: line)),
               let minutes = Int(string(match, 2, in: line)),
               let seconds = Int(string(match, 3, in: line)) {
                let name = string(match, 4, in: line).trimmingCharacters(in: decoration)
                if !name.isEmpty {
                    splitAt = TimeInterval(hours * 3600 + minutes * 60 + seconds)
                    splitName = name
                }
                // The tail goes whether or not it named anyone: a split with no
                // name cannot be acted on, but it has no business being read as
                // part of the evidence either.
                if let cut = Range(match.range, in: line) {
                    line = String(line[line.startIndex..<cut.lowerBound])
                }
            }

            let parts = line.components(separatedBy: "|")
            guard parts.count >= 2 else { continue }
            let head = parts[0].components(separatedBy: "=")
            guard head.count >= 2 else { continue }

            let label = head[0].trimmingCharacters(in: decoration)
            // An `=` inside the name is put back rather than treated as a
            // second separator — the first one is the only one that divides.
            let name = head[1...].joined(separator: "=").trimmingCharacters(in: decoration)
            guard !label.isEmpty, !name.isEmpty else { continue }

            resolutions.append(SpeakerResolution(
                label: label,
                name: name,
                confidence: confidence(from: parts[1]),
                // Everything past the second separator is the evidence, `|`
                // included: it is a quote from the meeting, not ours to cut.
                evidence: parts.count > 2
                    ? parts[2...].joined(separator: "|").trimmingCharacters(in: .whitespaces)
                    : "",
                splitAt: splitAt,
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
