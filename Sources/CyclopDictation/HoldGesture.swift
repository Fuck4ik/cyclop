import Foundation

/// Push-to-talk state, kept apart from the event tap so it can be tested.
///
/// The key repeat fires while a modifier is held down, so a press that arrives
/// while one is already in flight is not a new recording.
public struct HoldGesture {
    public enum Outcome: Equatable {
        /// Too short to be speech — a stray brush of the key.
        case ignoredTap
        case recorded(TimeInterval)
    }

    private let minimumHold: TimeInterval
    private var pressedAt: TimeInterval?

    public init(minimumHold: TimeInterval = 0.25) {
        self.minimumHold = minimumHold
    }

    /// Returns whether this press starts a recording.
    public mutating func press(at time: TimeInterval) -> Bool {
        guard pressedAt == nil else { return false }
        pressedAt = time
        return true
    }

    public mutating func release(at time: TimeInterval) -> Outcome {
        guard let started = pressedAt else { return .ignoredTap }
        pressedAt = nil
        let held = time - started
        return held >= minimumHold ? .recorded(held) : .ignoredTap
    }
}
