import XCTest
@testable import CyclopDictation

final class AudioLevelTests: XCTestCase {
    /// Feeds the same buffer until the smoothing settles, so a test asserts the
    /// level a sustained sound reaches rather than the first step towards it.
    private func settle(_ meter: AudioLevel, _ chunk: [Float], times: Int = 40) {
        for _ in 0..<times { meter.report(chunk) }
    }

    func testSilenceStaysAtRest() {
        let meter = AudioLevel()
        settle(meter, [Float](repeating: 0, count: 512))
        XCTAssertEqual(meter.current, 0, accuracy: 0.001)
    }

    func testLouderSoundGivesHigherLevel() {
        let quiet = AudioLevel()
        let loud = AudioLevel()
        settle(quiet, [Float](repeating: 0.02, count: 512))
        settle(loud, [Float](repeating: 0.4, count: 512))
        XCTAssertGreaterThan(loud.current, quiet.current)
    }

    func testFullScaleReachesTheTop() {
        let meter = AudioLevel()
        settle(meter, [Float](repeating: 1, count: 512))
        XCTAssertEqual(meter.current, 1, accuracy: 0.01)
    }

    func testLevelStaysInRange() {
        let meter = AudioLevel()
        // Beyond full scale — clipping input must not push the wave off-screen.
        settle(meter, [Float](repeating: 4, count: 512))
        XCTAssertLessThanOrEqual(meter.current, 1)
        XCTAssertGreaterThanOrEqual(meter.current, 0)
    }

    func testRisesFasterThanItFalls() {
        let rising = AudioLevel()
        let speech = [Float](repeating: 0.3, count: 512)
        rising.report(speech)
        let afterOneLoudBuffer = rising.current

        let falling = AudioLevel()
        settle(falling, speech)
        let sustained = falling.current
        falling.report([Float](repeating: 0, count: 512))
        let afterOneSilentBuffer = falling.current

        // One loud buffer covers more of the way up than one silent buffer
        // covers of the way down: pauses between words should leave a swell.
        XCTAssertGreaterThan(afterOneLoudBuffer / sustained, 1 - afterOneSilentBuffer / sustained)
    }

    func testEmptyBufferIsIgnored() {
        let meter = AudioLevel()
        settle(meter, [Float](repeating: 0.3, count: 512))
        let before = meter.current
        meter.report([])
        XCTAssertEqual(meter.current, before, accuracy: 0.0001)
    }

    func testResetReturnsToRest() {
        let meter = AudioLevel()
        settle(meter, [Float](repeating: 0.3, count: 512))
        meter.reset()
        XCTAssertEqual(meter.current, 0, accuracy: 0.0001)
    }
}
