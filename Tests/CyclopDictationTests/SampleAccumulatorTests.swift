import XCTest
@testable import CyclopDictation

/// Synthetic proof of the fix for the lost-last-word bug, run without a
/// microphone: `AudioRecorder`'s tap callback and `stop()` both live in the
/// `Cyclop` executable target, which a test target cannot import (see
/// Package.swift), so the concurrency-critical accumulation logic was pulled
/// out into `SampleAccumulator` here, in `CyclopDictation`, specifically so it
/// could be exercised like this.
final class SampleAccumulatorTests: XCTestCase {
    /// The property the whole fix rests on: a `drain()` must return exactly
    /// what was appended before it — no queue in between to reorder against.
    func testDrainReturnsExactlyWhatWasAppended() {
        let accumulator = SampleAccumulator()
        accumulator.append([1, 2, 3])
        accumulator.append([4, 5])
        XCTAssertEqual(accumulator.drain(), [1, 2, 3, 4, 5])
    }

    func testDrainResetsForTheNextRecording() {
        let accumulator = SampleAccumulator()
        accumulator.append([1, 2, 3])
        accumulator.drain()
        XCTAssertEqual(accumulator.drain(), [])
    }

    /// Stands in for the real shape of a recording: many small buffers, the
    /// size the tap callback hands over roughly every 4096 frames, appended
    /// back to back from a background queue standing in for the audio render
    /// thread. Every sample must be accounted for — a torn or dropped append
    /// under concurrent access would show up as a wrong total.
    func testConcurrentAppendsAreNotLost() {
        let accumulator = SampleAccumulator()
        let bufferCount = 500
        let samplesPerBuffer = 137 // odd size, so a torn append changes the total

        DispatchQueue.concurrentPerform(iterations: bufferCount) { index in
            accumulator.append(Array(repeating: Float(index), count: samplesPerBuffer))
        }

        XCTAssertEqual(accumulator.drain().count, bufferCount * samplesPerBuffer)
    }

    /// The exact scenario from the bug report: the last buffer is appended,
    /// then drained immediately after, with nothing queued in between. Under
    /// the old `Task { @MainActor in ... }` approach this ordering was not
    /// guaranteed; under a lock it always holds.
    func testDrainImmediatelyAfterAppendSeesTheLastBuffer() {
        let accumulator = SampleAccumulator()
        for index in 0..<50 {
            accumulator.append([Float(index)])
            XCTAssertEqual(accumulator.drain(), [Float(index)])
        }
    }
}
