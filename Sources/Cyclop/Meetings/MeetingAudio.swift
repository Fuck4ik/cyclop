import AVFoundation
import CyclopMeetings

/// Turns a recording into something small enough to send.
///
/// 32 kbps mono: an hour of it is 13 MB, 18 MB once base64-encoded, which fits
/// under the request ceiling with the margin `ChunkPlan` counts on. Quality
/// beyond that buys nothing — the model reads speech, not music.
enum MeetingAudio {
    private static let bitRate = 32_000
    private static let sampleRate = 16_000

    static func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.duration).seconds
    }

    static func hasAudioTrack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try? await asset.loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
    }

    /// Reads one chunk out of the source and writes it compressed.
    ///
    /// Export rather than a raw copy: the source is HEVC video with AAC audio
    /// at full rate, and sending that whole would blow the request ceiling on
    /// anything longer than a few minutes.
    static func compressed(
        from url: URL,
        chunk: ChunkPlan.Chunk,
        to destination: URL
    ) async throws {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: url)
        // AVAssetReader/Writer and their inputs/outputs are NS_SWIFT_NONSENDABLE,
        // but every use of these four below is serialized on the single
        // `queue` created inside the continuation block — nothing else
        // touches them concurrently. `nonisolated(unsafe)` records that by
        // hand instead of the compiler proving it, which it structurally can't
        // for a completion-block API like requestMediaDataWhenReady.
        nonisolated(unsafe) let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }

        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: chunk.start, preferredTimescale: 600),
            duration: CMTime(seconds: chunk.duration, preferredTimescale: 600)
        )
        nonisolated(unsafe) let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ]
        )
        reader.add(readerOutput)

        nonisolated(unsafe) let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        nonisolated(unsafe) let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            // AVAssetWriter reserves the file at outputURL as soon as it is
            // initialized above, so a failure here can still leave an empty
            // file behind — clean it up rather than passing it on to the caller.
            let error = writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        writer.startSession(atSourceTime: .zero)

        do {
            // Throwing rather than the brief's non-throwing continuation: the
            // brief's version treats every end of `copyNextSampleBuffer()` as
            // a clean finish, which also swallows a reader that stopped
            // because it *failed* partway through — the caller would get a
            // silently truncated file instead of an error. Both resume paths
            // below return immediately afterward, so the continuation resumes
            // exactly once no matter which branch is taken.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let queue = DispatchQueue(label: "cyclop.meeting.audio")
                writerInput.requestMediaDataWhenReady(on: queue) {
                    while writerInput.isReadyForMoreMediaData {
                        guard let buffer = readerOutput.copyNextSampleBuffer() else {
                            writerInput.markAsFinished()
                            if reader.status == .failed {
                                continuation.resume(throwing: reader.error ?? CocoaError(.fileReadCorruptFile))
                            } else {
                                continuation.resume()
                            }
                            return
                        }
                        if !writerInput.append(buffer) {
                            writerInput.markAsFinished()
                            continuation.resume(throwing: writer.error ?? CocoaError(.fileWriteUnknown))
                            return
                        }
                    }
                }
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        await writer.finishWriting()
        if let error = writer.error {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
