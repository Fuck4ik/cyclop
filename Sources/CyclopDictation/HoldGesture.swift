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

    /// Determines whether the right Option key is currently held.
    ///
    /// CGEventFlags.maskAlternate is set when *any* Option is held. To distinguish
    /// the right Option from the left, we check the device-specific mask NX_DEVICERALTKEYMASK.
    /// This is necessary because both Options set the same generic bit, but only the right one
    /// should trigger push-to-talk — the left one is used for typing special characters and
    /// should not interfere with dictation.
    ///
    /// Scenario: user holds left Option (typing) and presses right Option (starting dictation).
    /// If we relied on maskAlternate alone, the right-Option-down event would work by accident,
    /// but releasing the right Option (while left is still held) would see maskAlternate still
    /// set and incorrectly report the key as still pressed. The gesture would not close, leaving
    /// the recording stuck open.
    public static func isRightOptionDown(rawFlags: UInt64) -> Bool {
        // NX_DEVICERALTKEYMASK for right Option
        let NX_DEVICERALTKEYMASK: UInt64 = 0x40
        return (rawFlags & NX_DEVICERALTKEYMASK) != 0
    }
}
