import Foundation

/// Which animation the notch shows while dictation runs.
///
/// Two of them exist because they are different answers to the same question,
/// and which one is better is a matter of taste rather than of argument: the
/// bloom is quiet and belongs to the hardware, the wave is loud and belongs to
/// the voice. The choice lives in the menu bar next to the other switches.
enum DictationWaveStyle: String, CaseIterable {
    /// Light spilling out of the notch, growing with the voice.
    case bloom
    /// The iOS-style travelling line with colour separated out of it.
    case siri
    /// Several threads of different frequency woven through each other.
    case strands

    var title: String {
        switch self {
        case .bloom: return localized("Glow")
        case .siri: return localized("Siri Wave")
        case .strands: return localized("Strands")
        }
    }

    /// How far past the notch the canvas may reach. The bloom needs the room:
    /// its halo is blurred by tens of points and would be cut off at the edge.
    /// The wave is a drawn line with visible ends, so anything past the cutout
    /// reads as a strip hanging out from under it — it stays inside.
    var extraWidth: CGFloat {
        switch self {
        case .bloom: return 160
        // Both draw lines with visible ends, so they stay inside the cutout.
        case .siri, .strands: return 0
        }
    }

    /// How far down its own canvas each animation draws. Subtracted from the
    /// offset so every style starts at the notch's lower edge rather than
    /// wherever its canvas happens to put it — the source of a few stray points
    /// of gap that read as the animation hanging below the cutout.
    var coreInset: CGFloat {
        switch self {
        case .bloom: return DictationWave.coreInset
        case .siri: return DictationSiriWave.coreInset
        case .strands: return DictationStrands.coreInset
        }
    }

    private static let key = "dictation.waveStyle"

    static var current: DictationWaveStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let style = DictationWaveStyle(rawValue: raw) else { return .bloom }
            return style
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
