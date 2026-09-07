import XCTest
@testable import CyclopMeetings

final class SpeechLevelTests: XCTestCase {
    // The seconds below are measurements from the recordings on hand, not
    // invented bounds — see `SpeechLevel.minimumVoicedSeconds`.

    func testDigitalSilenceHoldsNoSpeech() {
        XCTAssertFalse(SpeechLevel.carriesSpeech(voicedSeconds: 0))
    }

    func testEmptyRoomHoldsNoSpeech() {
        // 1.7 s — the microphone of a meeting nobody joined: breathing, a
        // chair, the loudest thing in it a click.
        XCTAssertFalse(SpeechLevel.carriesSpeech(voicedSeconds: 1.7))
    }

    func testShortestRealConversationCounts() {
        // 33.5 s — the quietest lane among the recordings that did hold one.
        XCTAssertTrue(SpeechLevel.carriesSpeech(voicedSeconds: 33.5))
    }

    func testLongMeetingCounts() {
        XCTAssertTrue(SpeechLevel.carriesSpeech(voicedSeconds: 1237.7))
    }

    /// The threshold has to sit between the two measured populations rather
    /// than on top of either: a boundary that touches real speech turns a
    /// recorded meeting into a deleted one.
    func testThresholdSitsBetweenTheMeasuredPopulations() {
        XCTAssertGreaterThan(SpeechLevel.minimumVoicedSeconds, 1.7)
        XCTAssertLessThan(SpeechLevel.minimumVoicedSeconds, 33.5)
    }

    func testSilentWindowIsMinusInfinityRatherThanACrash() {
        XCTAssertEqual(SpeechLevel.decibels(rms: 0), -.infinity)
    }

    func testFullScaleWindowIsZeroDecibels() {
        XCTAssertEqual(SpeechLevel.decibels(rms: 1), 0, accuracy: 0.001)
    }

    func testWindowAtTheThresholdIsSound() {
        let rms = pow(10, SpeechLevel.windowThreshold / 20)

        XCTAssertTrue(SpeechLevel.isSound(rms: rms))
        XCTAssertFalse(SpeechLevel.isSound(rms: rms * 0.9))
    }

    /// An RMS can only be measured as non-negative; a negative one means the
    /// reader failed, and a failed measurement must not read as sound.
    func testImpossibleWindowIsNotSound() {
        XCTAssertFalse(SpeechLevel.isSound(rms: -1))
    }
}
