import Foundation

/// How much one diarisation label speaks and when.
///
/// This is what makes structural mistakes visible. On a real meeting the model
/// tore one person into two labels — the first ended at 54:59 and the second
/// picked up at 55:00 — and no amount of reading the words would have shown
/// that as clearly as the two spans side by side.
public struct SpeakerProfile: Equatable, Sendable {
    public let label: String
    public let characters: Int
    public let lines: Int
    public let first: TimeInterval
    public let last: TimeInterval

    public init(label: String, characters: Int, lines: Int, first: TimeInterval, last: TimeInterval) {
        self.label = label
        self.characters = characters
        self.lines = lines
        self.first = first
        self.last = last
    }

    /// The shape the prompt carries. Compact on purpose: it rides along with
    /// the whole transcript, and every token here is one not spent on words.
    public var line: String {
        "\(label): реплик — \(lines), символов — \(characters), "
            + "с \(Self.clock(first)) по \(Self.clock(last))"
    }

    private static func clock(_ time: TimeInterval) -> String {
        let total = Int(time.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

public enum SpeakerProfiler {
    /// Sorted by how much each label speaks: the model reads the top of the
    /// list most carefully, and that is where the identities that matter are.
    public static func profiles(of segments: [TranscriptSegment]) -> [SpeakerProfile] {
        var byLabel: [String: (characters: Int, lines: Int, first: TimeInterval, last: TimeInterval)] = [:]

        for segment in segments {
            let existing = byLabel[segment.speaker]
            byLabel[segment.speaker] = (
                characters: (existing?.characters ?? 0) + segment.text.count,
                lines: (existing?.lines ?? 0) + 1,
                first: existing.map { min($0.first, segment.start) } ?? segment.start,
                last: max(existing?.last ?? 0, segment.start)
            )
        }

        return byLabel
            .map { SpeakerProfile(
                label: $0.key, characters: $0.value.characters, lines: $0.value.lines,
                first: $0.value.first, last: $0.value.last) }
            .sorted { ($0.characters, $0.label) > ($1.characters, $1.label) }
    }
}

/// One person at the meeting.
public struct Participant: Equatable, Sendable {
    /// How much the name and the role can be trusted. Written into the file
    /// because a model reads it later and must not take a guess for a fact.
    public enum Confidence: String, Sendable, Equatable {
        case fact
        case high
        case medium
        case low

        public var word: String {
            switch self {
            case .fact: return "факт"
            case .high: return "высокая"
            case .medium: return "средняя"
            case .low: return "низкая"
            }
        }
    }

    public let name: String
    public let role: String?
    public let confidence: Confidence
    public let evidence: String

    public init(name: String, role: String?, confidence: Confidence, evidence: String) {
        self.name = name
        self.role = role
        self.confidence = confidence
        self.evidence = evidence
    }
}

public enum ParticipantRoster {
    /// The closed set of names the model is allowed to choose from.
    ///
    /// Order is deliberate — owner, then the invitation, then what the call's
    /// interface showed — and it is the order of how much each source is
    /// trusted. Names seen in the interface are kept even when the frame they
    /// came from was useless: an empty desktop still had the tiles on it.
    public static func candidateNames(
        owner: String?, calendar: [String], notes: [ScreenNote]
    ) -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            names.append(trimmed)
        }

        owner.map(add)
        calendar.forEach(add)
        notes.flatMap(\.uiNames).sorted().forEach(add)
        return names
    }
}
