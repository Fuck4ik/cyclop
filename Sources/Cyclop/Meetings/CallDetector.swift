import CoreAudio
import Foundation

/// Notices that some app started listening to the microphone.
///
/// Watches the device rather than a process list, so Telegram, Zoom and a call
/// in the browser all look the same. Deliberately dumb in this stage: the
/// smart part — not offering twice, telling a call from a voice message —
/// belongs to the stage that adds automatic recording.
final class CallDetector {
    /// A call is a conversation, not a two-second voice message; half a minute
    /// of a busy microphone is the cheapest way to tell them apart.
    private static let threshold: TimeInterval = 30

    private let onCallStarted: @MainActor () -> Void
    /// Whether the microphone that is busy is busy with us.
    ///
    /// The device flag below says a microphone is in use, never by whom, and
    /// dictation holds the same microphone for as long as the key is held.
    /// Dictate a long paragraph and the app offers to record the call you are
    /// not on.
    private let isOwnCapture: @MainActor () -> Bool
    private var timer: Timer?
    private var busySince: Date?
    private var alreadyOffered = false

    init(
        isOwnCapture: @escaping @MainActor () -> Bool,
        onCallStarted: @escaping @MainActor () -> Void
    ) {
        self.isOwnCapture = isOwnCapture
        self.onCallStarted = onCallStarted
    }

    func start() {
        guard timer == nil else { return }
        // Polling rather than a property listener: the callback arrives on a
        // CoreAudio thread and the state here is read from the main one, so a
        // five-second tick is both simpler and enough for a 30-second rule.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        busySince = nil
        alreadyOffered = false
    }

    private func tick() {
        // The timer is scheduled in start(), which runs on the MainActor, so
        // it was added to the main run loop and fires here on the main
        // thread. Stating that is what lets this read dictation's state
        // without a hop — a hop would answer one tick late, and the answer
        // decides whether this tick counts toward the threshold at all.
        let ours = MainActor.assumeIsolated { isOwnCapture() }
        // Our own capture resets the clock rather than merely skipping the
        // offer: a paragraph dictated for a minute must not leave the
        // detector one tick away from offering the moment the key is let go.
        guard Self.isMicrophoneBusy(), !ours else {
            busySince = nil
            alreadyOffered = false
            return
        }
        guard !alreadyOffered else { return }

        guard let since = busySince else {
            busySince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= Self.threshold else { return }

        alreadyOffered = true
        Task { @MainActor in self.onCallStarted() }
    }

    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` answers for the device as
    /// a whole — which is exactly the question here.
    private static func isMicrophoneBusy() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return false }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &runningAddress, 0, nil, &runningSize, &running
        ) == noErr else { return false }

        return running == 1
    }
}
