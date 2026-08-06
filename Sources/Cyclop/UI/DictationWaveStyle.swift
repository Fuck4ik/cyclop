import Foundation

/// Which animation the notch shows while dictation runs.
///
/// Two of them exist because they are different answers to the same question,
/// and which one is better is a matter of taste rather than of argument: the
/// strands are a woven cloud of light, the wave is a single travelling line
/// with colour separated out of it. The choice lives in the menu bar next to
/// the other switches.
enum DictationWaveStyle: String, CaseIterable {
    /// Several threads of different frequency woven through each other.
    case strands
    /// The iOS-style travelling line with colour separated out of it.
    case siri

    var title: String {
        switch self {
        case .strands: return localized("Strands")
        case .siri: return localized("Siri Wave")
        }
    }

    /// How far down its own canvas each animation draws. Subtracted from the
    /// offset so every style starts at the notch's lower edge rather than
    /// wherever its canvas happens to put it — the source of a few stray points
    /// of gap that read as the animation hanging below the cutout.
    var coreInset: CGFloat {
        switch self {
        case .strands: return DictationStrands.coreInset
        case .siri: return DictationSiriWave.coreInset
        }
    }

    private static let key = "dictation.waveStyle"

    /// Strands by default. An unknown value in defaults — the glow that used to
    /// live here, or anything else left over — resolves to it as well.
    static var current: DictationWaveStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let style = DictationWaveStyle(rawValue: raw) else { return .strands }
            return style
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
