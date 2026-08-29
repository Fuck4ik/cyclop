import Foundation

/// A moment where the words alone do not carry what was on the screen.
///
/// `expectation` matters more than the timecode: the next step asks a vision
/// model a concrete question instead of «describe this frame», and a concrete
/// question is what makes a small budget of frames worth spending.
public struct FrameCandidate: Equatable, Sendable {
    public let start: TimeInterval
    public let expectation: String
    /// 1 is the most valuable. Higher numbers are dropped first when the
    /// budget bites.
    public let priority: Int

    public init(start: TimeInterval, expectation: String, priority: Int) {
        self.start = start
        self.expectation = expectation
        self.priority = priority
    }
}

/// Turns the model's answer into candidates.
///
/// Forgiving for the same reason `TranscriptParser` is: the shape is asked
/// for, not guaranteed. A line without a timecode is a preamble and costs
/// nothing to skip; a missing priority costs the whole candidate if we insist
/// on it, so it degrades to the lowest instead.
public enum FrameCandidateParser {
    /// `[01:02:03] 2 | what to expect`, hours and priority optional.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\**\[?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\]?\**\s*(\d)?\s*\|\s*(.*)$"#
    )

    public static let lowestPriority = 3

    public static func candidates(from text: String) -> [FrameCandidate] {
        var candidates: [FrameCandidate] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = pattern.firstMatch(in: line, range: range) else { continue }

            let hours = number(match, 1, in: line) ?? 0
            let minutes = number(match, 2, in: line) ?? 0
            let seconds = number(match, 3, in: line) ?? 0
            let priority = number(match, 4, in: line) ?? lowestPriority
            let expectation = string(match, 5, in: line).trimmingCharacters(in: .whitespaces)
            guard !expectation.isEmpty else { continue }

            candidates.append(FrameCandidate(
                start: TimeInterval(hours * 3600 + minutes * 60 + seconds),
                expectation: expectation,
                priority: min(max(priority, 1), lowestPriority)
            ))
        }
        return candidates
    }

    private static func string(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String {
        guard let range = Range(match.range(at: index), in: line) else { return "" }
        return String(line[range])
    }

    private static func number(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> Int? {
        Int(string(match, index, in: line))
    }
}
