import XCTest
@testable import CyclopDictation

final class AudioNormalizerTests: XCTestCase {
    func testQuietAudioIsBoostedToTarget() {
        // −20 dBFS peak should gain +17 dB to reach −3 dBFS.
        XCTAssertEqual(AudioNormalizer.gain(peak: -20), 17, accuracy: 0.01)
    }

    func testLoudAudioIsNeverMadeQuieter() {
        XCTAssertEqual(AudioNormalizer.gain(peak: -1), 0, accuracy: 0.01)
    }

    func testSilenceIsLeftAlone() {
        // Below the floor there is nothing but noise to amplify.
        XCTAssertEqual(AudioNormalizer.gain(peak: -60), 0, accuracy: 0.01)
    }

    func testNormalizeScalesSamplesAndNeverClips() {
        var samples: [Float] = [0.1, -0.05, 0.1]
        let applied = AudioNormalizer.normalize(&samples)
        XCTAssertGreaterThan(applied, 0)
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 1.0)
        XCTAssertEqual(samples.map(abs).max() ?? 0, 0.7079, accuracy: 0.001)
    }

    func testEmptyBufferIsSafe() {
        var samples: [Float] = []
        XCTAssertEqual(AudioNormalizer.normalize(&samples), 0)
    }

    func testFloorBoundaryIsInclusive() {
        // Peak at exactly −50.0 dBFS (the floor) should be amplified by 47.0 dB to reach −3.0 dBFS.
        XCTAssertEqual(AudioNormalizer.gain(peak: -50.0), 47.0, accuracy: 0.01)
    }

    func testBelowFloorIsNotAmplified() {
        // Peak below the floor (−50.1 dBFS) should not be amplified.
        XCTAssertEqual(AudioNormalizer.gain(peak: -50.1), 0, accuracy: 0.01)
    }

    func testTargetBoundaryIsExclusive() {
        // Peak at exactly −3.0 dBFS (the target) should not be amplified.
        XCTAssertEqual(AudioNormalizer.gain(peak: -3.0), 0, accuracy: 0.01)
    }
}
