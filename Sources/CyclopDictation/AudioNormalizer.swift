import Foundation

/// Peak normalisation, ported from the Python app's `audio_processor`.
///
/// Whisper handles quiet input badly — it skips words or invents them — so the
/// peak is lifted to a target with headroom. Loud input is never made quieter,
/// and near-silence is left alone rather than amplified into noise.
public enum AudioNormalizer {
    public static func gain(peak dbfs: Float, target: Float = -3.0, floor: Float = -50.0) -> Float {
        guard dbfs > floor, dbfs < target else { return 0 }
        return target - dbfs
    }

    /// Scales the buffer in place, returning the gain applied in dB.
    @discardableResult
    public static func normalize(_ samples: inout [Float], target: Float = -3.0, floor: Float = -50.0) -> Float {
        guard let peak = samples.map(abs).max(), peak > 0 else { return 0 }
        let peakDBFS = 20 * log10(peak)
        let applied = gain(peak: peakDBFS, target: target, floor: floor)
        guard applied > 0 else { return 0 }
        let factor = pow(10, applied / 20)
        for index in samples.indices {
            samples[index] = max(-1, min(1, samples[index] * factor))
        }
        return applied
    }
}
