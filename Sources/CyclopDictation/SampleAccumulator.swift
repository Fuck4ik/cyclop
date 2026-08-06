import Foundation

/// Collects Float samples handed in from a real-time audio thread, for a
/// caller on another thread (typically the main actor) to take all at once.
///
/// `append` and `drain` are synchronous and lock-protected on purpose. The
/// alternative — bouncing each buffer through `Task { @MainActor in ... } `—
/// only queues the append; it does not happen before the `Task` gets a turn
/// on the run loop. A caller that reads the accumulated samples right away
/// (stop(), called synchronously the instant a key is released) can then run
/// to completion before the last queued `Task` is even dequeued, silently
/// dropping the very last buffer — which is exactly the one carrying the
/// last word, since it arrives the moment the user stops talking. A lock
/// makes `append` finish before `drain` can see its effects, with no queue
/// in between to lose a race against.
public final class SampleAccumulator: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    public init() {}

    public func append(_ chunk: [Float]) {
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    /// Returns everything collected so far and resets for the next recording.
    @discardableResult
    public func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples.removeAll(keepingCapacity: true)
        return result
    }
}
