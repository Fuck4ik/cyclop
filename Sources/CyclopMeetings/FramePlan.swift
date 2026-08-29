import Foundation

/// Which of the proposed moments actually get a frame.
///
/// Two filters live here — merging near-duplicates and cutting to budget. The
/// third one, «did the screen change at all», needs the video itself and runs
/// in `MeetingFrames`: the plan is built before a single frame is decoded.
public enum FramePlan {
    /// Closer than this and it is the same screen twice. Measured against the
    /// pace of a real demo: switching a tab, letting a page load and saying a
    /// sentence about it takes longer than this.
    public static let minimumGap: TimeInterval = 45

    public static let minimumBudget = 3
    public static let maximumBudget = 40

    /// One frame per four minutes. A recorded hour holds fifteen screens worth
    /// keeping — counted by hand on a real audit call — and that is also about
    /// what the request quota tolerates in one processing run.
    public static func budget(forDuration duration: TimeInterval) -> Int {
        let raw = Int((duration / 240).rounded())
        return min(max(raw, minimumBudget), maximumBudget)
    }

    public static func selected(from candidates: [FrameCandidate], budget: Int) -> [FrameCandidate] {
        let budget = max(0, budget)
        let merged = merge(candidates.sorted { $0.start < $1.start })
        guard merged.count > budget else { return merged }

        // Sorted by priority, then by time so that ties resolve the same way
        // every run: a plan that shuffles between runs is impossible to test
        // and confusing to re-read.
        let kept = merged
            .enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .prefix(budget)
            .map(\.offset)
        let keptSet = Set(kept)
        return merged.enumerated().filter { keptSet.contains($0.offset) }.map(\.element)
    }

    /// Of two candidates within `minimumGap`, the more valuable one survives —
    /// its expectation is the sharper question to ask about that screen. The
    /// window is measured from where the group started rather than from the
    /// survivor: a survivor moves forward every time a better candidate
    /// replaces it, and a moving anchor drags the window along with it, so a
    /// burst of switches collapses into one frame covering minutes.
    private static func merge(_ sorted: [FrameCandidate]) -> [FrameCandidate] {
        var merged: [FrameCandidate] = []
        var groupStart: TimeInterval?

        for candidate in sorted {
            guard let start = groupStart, candidate.start - start < minimumGap else {
                merged.append(candidate)
                groupStart = candidate.start
                continue
            }
            if candidate.priority < merged[merged.count - 1].priority {
                merged[merged.count - 1] = candidate
            }
        }
        return merged
    }
}
