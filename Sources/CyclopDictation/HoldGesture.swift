import Foundation

/// Push-to-talk state, kept apart from the event tap so it can be tested.
///
/// The key repeat fires while a modifier is held down, so a press that arrives
/// while one is already in flight is not a new recording.
public struct HoldGesture {
    public enum Outcome: Equatable {
        /// Too short to be speech — a stray brush of the key.
        case ignoredTap
        /// Two short taps in quick succession: a shortcut of its own, not a
        /// recording. Nothing was going to happen on these taps anyway, so the
        /// gesture costs the dictation nothing.
        case doubleTap
        case recorded(TimeInterval)
    }

    private let minimumHold: TimeInterval
    private let doubleTapWindow: TimeInterval
    private var pressedAt: TimeInterval?
    private var lastTapAt: TimeInterval?

    public init(minimumHold: TimeInterval = 0.25, doubleTapWindow: TimeInterval = 0.4) {
        self.minimumHold = minimumHold
        self.doubleTapWindow = doubleTapWindow
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
        guard held < minimumHold else {
            // A real recording ends any pair being assembled: releasing after
            // speaking and immediately tapping again is not a double tap, and
            // firing one there would append a stray word after every quick
            // dictation.
            lastTapAt = nil
            return .recorded(held)
        }
        if let previous = lastTapAt, time - previous <= doubleTapWindow {
            // Consumed whole: a third tap starts a new pair rather than
            // firing again off the second.
            lastTapAt = nil
            return .doubleTap
        }
        lastTapAt = time
        return .ignoredTap
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
