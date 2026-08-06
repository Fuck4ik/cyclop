import Foundation

/// Loudness of what the microphone is hearing, for the waveform to breathe on.
///
/// Written from the real-time audio thread, read from the main thread by the
/// view. Pull rather than push on purpose: the view already redraws on a
/// display-linked timer, so publishing every buffer would only queue work that
/// arrives between frames and is thrown away — and publishing from the audio
/// thread is the mistake that once cost this app the last word of every take.
public final class AudioLevel: @unchecked Sendable {
    private var value: Float = 0
    private let lock = NSLock()

    /// Below this the signal is room tone, not speech, and the wave should rest.
    private let floorDB: Float = -50
    /// How fast the wave follows a rising voice. Near-instant: a wave that lags
    /// the voice reads as lag in the app.
    private let attack: Float = 0.55
    /// How fast it falls back. Slower than it rises, so pauses between words
    /// leave a swell rather than a flat line — the same asymmetry a VU meter
    /// uses, and the reason its needle looks alive rather than twitchy.
    private let release: Float = 0.12

    public init() {}

    /// Takes one buffer straight off the audio thread.
    public func report(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }

        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let rms = (sum / Float(chunk.count)).squareRoot()

        // dBFS, then mapped onto 0…1 across the floor. Linear amplitude would
        // spend almost its whole range on shouting: ordinary speech sits around
        // -30 dBFS, which is 0.03 linear — a wave that never left the baseline.
        let db = rms > 0 ? 20 * log10(rms) : floorDB
        let target = max(0, min(1, (db - floorDB) / -floorDB))

        lock.lock()
        let rate = target > value ? attack : release
        value += (target - value) * rate
        lock.unlock()
    }

    /// Current level, 0…1.
    public var current: Float {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}
