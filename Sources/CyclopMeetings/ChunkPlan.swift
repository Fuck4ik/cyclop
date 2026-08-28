import Foundation

/// How a long recording is split for transcription.
///
/// An hour of 32 kbps audio is 13 MB, which is 18 MB once base64-encoded,
/// against a request ceiling of about 20 MB. The threshold is therefore 55
/// minutes: the remaining slack is not enough to gamble a whole meeting on.
public struct ChunkPlan {
    public struct Chunk: Equatable, Sendable {
        public let start: TimeInterval
        public let duration: TimeInterval

        public init(start: TimeInterval, duration: TimeInterval) {
            self.start = start
            self.duration = duration
        }
    }

    public static let limit: TimeInterval = 3300

    /// A tail shorter than this is folded into the chunk before it: a
    /// one-second chunk costs a full request and returns nothing worth having.
    private static let minimumTail: TimeInterval = 60

    public static func chunks(forDuration duration: TimeInterval) -> [Chunk] {
        guard duration > 0 else { return [] }
        guard duration > limit else { return [Chunk(start: 0, duration: duration)] }

        var chunks: [Chunk] = []
        var start: TimeInterval = 0
        while start < duration {
            let remaining = duration - start
            if remaining <= limit + minimumTail {
                chunks.append(Chunk(start: start, duration: remaining))
                break
            }
            chunks.append(Chunk(start: start, duration: limit))
            start += limit
        }
        return chunks
    }
}
