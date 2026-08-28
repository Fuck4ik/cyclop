import Foundation

/// Where one meeting lives on disk.
///
/// The date is carried by the folder name rather than by an index file: the
/// list of past meetings is then just a directory listing, and a folder moved
/// into Google Drive by hand stays readable. The name is also why the format
/// is fixed and parsed back — it is the only source of the start time.
public struct MeetingFolder: Equatable, Sendable {
    public static let videoFileName = "meeting.mp4"

    public let url: URL
    public let startedAt: Date

    public init(root: URL, startedAt: Date) {
        self.startedAt = startedAt
        self.url = root.appendingPathComponent(
            "\(Self.formatter.string(from: startedAt)) Встреча",
            isDirectory: true
        )
    }

    public init?(existing url: URL) {
        let name = url.lastPathComponent
        guard name.hasSuffix(" Встреча") else { return nil }
        let stamp = String(name.dropLast(" Встреча".count))
        guard let date = Self.formatter.date(from: stamp) else { return nil }
        self.url = url
        self.startedAt = date
    }

    public var videoURL: URL { url.appendingPathComponent(Self.videoFileName) }
    public var microphoneURL: URL { url.appendingPathComponent("mic.m4a") }
    public var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    public var stateURL: URL { url.appendingPathComponent(".state.json") }

    /// The model's answer as it came, kept only when nothing in it parsed.
    ///
    /// That answer was paid for and is the only evidence of what the model
    /// actually said; discarding it would leave a failed meeting with nothing
    /// to look at and nothing to fix the parser against.
    public var rawAnswerURL: URL { url.appendingPathComponent("raw-answer.txt") }

    /// Fixed locale, local time zone.
    ///
    /// The locale is pinned because the name is parsed back and has to stay
    /// the same ASCII digits everywhere. The zone deliberately is not: the
    /// name is wall-clock time, and it has to agree with the header of
    /// `transcript.md` and the row in the list, both of which are local. Under
    /// UTC a meeting held at 15:30 in Moscow was filed as `12-30`, and one
    /// held after 21:00 was filed under the day before — findable by nobody.
    /// Parsing stays sound: the same Mac reads the name back through this same
    /// formatter, so the `Date` round-trips.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter
    }()
}
