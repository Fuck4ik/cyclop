import Foundation

/// What one frame turned out to hold.
///
/// `details` carries identifiers verbatim because the file is read by a model
/// later, and a model without eyes gets nothing from the picture. `uiNames`
/// comes along for free: the call's own interface labels its tiles, and the
/// frame was going to be sent anyway.
public struct ScreenNote: Equatable, Sendable {
    public let start: TimeInterval
    public let title: String
    public let details: String
    public let presenter: String?
    public let uiNames: [String]
    public let slug: String
    /// The model's own verdict. A frame of an empty desktop costs a request
    /// either way, but it must not cost a block in the transcript.
    public let isUseful: Bool

    public init(
        start: TimeInterval,
        title: String,
        details: String,
        presenter: String?,
        uiNames: [String],
        slug: String,
        isUseful: Bool
    ) {
        self.start = start
        self.title = title
        self.details = details
        self.presenter = presenter
        self.uiNames = uiNames
        self.slug = slug
        self.isUseful = isUseful
    }

    /// `30-00_slug.jpg`. Minutes and seconds rather than the full clock: an
    /// hour-long meeting reads better as `41-40` than as `00-41-40`, and past
    /// an hour the minutes simply keep counting.
    public var fileName: String {
        let total = Int(start.rounded(.down))
        let stamp = String(format: "%02d-%02d", total / 60, total % 60)
        return slug.isEmpty ? "\(stamp).jpg" : "\(stamp)_\(slug).jpg"
    }

    public var timecode: String {
        let total = Int(start.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// Turns the model's answer into notes.
///
/// Blocks separated by a timecode line, fields as `key: value`. Chosen over
/// JSON for the same reason the transcript is lines: the model drifts, and a
/// half-broken block still yields its title and details, while a half-broken
/// JSON yields nothing.
public enum ScreenNoteParser {
    private static let timecodePattern = try! NSRegularExpression(
        pattern: #"^\**\[?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\]?\**\s*$"#
    )

    public static func notes(from text: String) -> [ScreenNote] {
        var notes: [ScreenNote] = []
        var start: TimeInterval?
        var fields: [String: String] = [:]

        func flush() {
            // Both the fields and the timecode are cleared: a timecode that
            // outlived its block would adopt whatever line came next.
            defer { fields = [:]; start = nil }
            guard let start else { return }
            let title = fields["title"] ?? ""
            guard !title.isEmpty else { return }
            notes.append(ScreenNote(
                start: start,
                title: title,
                details: fields["details"] ?? "",
                presenter: fields["presenter"].flatMap { $0.isEmpty ? nil : $0 },
                uiNames: (fields["names"] ?? "")
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                slug: slugify(fields["slug"] ?? ""),
                isUseful: (fields["useful"] ?? "yes").lowercased().hasPrefix("y")
                    || (fields["useful"] ?? "").lowercased().hasPrefix("д")
            ))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = timecodePattern.firstMatch(in: line, range: range) {
                flush()
                let hours = number(match, 1, in: line) ?? 0
                let minutes = number(match, 2, in: line) ?? 0
                let seconds = number(match, 3, in: line) ?? 0
                start = TimeInterval(hours * 3600 + minutes * 60 + seconds)
                continue
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            // First value wins. A stray field line between two blocks would
            // otherwise overwrite what the block that just ended had already
            // collected, and the frame would end up described by the next
            // one's words.
            if fields[key] == nil { fields[key] = value }
        }
        flush()
        return notes
    }

    /// The slug becomes a file name, so anything a file name cannot hold is
    /// replaced rather than trusted: the model is asked for a clean slug and
    /// occasionally answers with a sentence.
    private static func slugify(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let collapsed = raw.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        return String(collapsed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .prefix(60)
            .description
    }

    private static func number(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> Int? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return Int(line[range])
    }
}
