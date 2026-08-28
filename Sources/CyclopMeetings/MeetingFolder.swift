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

    /// Fixed locale and time zone: the folder name is parsed back, so it must
    /// not depend on where the Mac happens to be set.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
