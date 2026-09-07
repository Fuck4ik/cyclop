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

    /// How long the recording is, as a recording — the video track decides
    /// this for meeting.mp4. What the transcript header shows.
    static func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.duration).seconds
    }

    /// How far the audio actually reaches, which is not the same number.
    ///
    /// In meeting.mp4 the asset duration is the video track's, and the audio
    /// track can end earlier — a stream whose audio dropped out, a writer that
    /// lost the tail. Chunks are cut from the audio, so they have to be
    /// planned against the audio: a chunk starting past the last sample
    /// exports nothing and would still be base64'd and posted to a paid
    /// endpoint. The track's own end is used rather than its duration, because
    /// the reader's time range is in asset time and the track may start late.
    static func audioDuration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let range = try await track.load(.timeRange)
        return (range.start + range.duration).seconds
    }

    static func hasAudioTrack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try? await asset.loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
    }

    /// Whether this lane is worth sending to a model at all.
    ///
    /// True when it cannot be measured: a lane that failed to open is a
    /// problem for the transcription path to report properly, and refusing a
    /// whole meeting over a failed measurement would turn a readable
    /// recording into a lost one.
    static func carriesSpeech(at url: URL) async -> Bool {
        do {
            return SpeechLevel.carriesSpeech(voicedSeconds: try await voicedSeconds(of: url))
        } catch {
            NSLog("Cyclop: could not measure %@ (%@)", url.lastPathComponent,
                error.localizedDescription)
            return true
        }
    }

    /// How many seconds of this lane actually sound, by `SpeechLevel`'s rule.
    ///
    /// The whole track is read: speech can start in the last minute of an
    /// hour, so measuring the beginning would answer a different question.
    /// It is cheap enough to do so — 36 minutes of audio measured in 1.2 s,
    /// against a transcription that costs minutes and money.
    static func voicedSeconds(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Same reasoning as in `compressed` below: reader and output are
        // NS_SWIFT_NONSENDABLE and are touched only on the one queue created
        // inside the continuation.
        nonisolated(unsafe) let reader = try AVAssetReader(asset: asset)
        nonisolated(unsafe) let output = AVAssetReaderTrackOutput(
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
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Off the cooperative pool: this is a synchronous decode of the
            // whole track, and it would hold a pool thread for all of it.
            DispatchQueue(label: "cyclop.meeting.level").async {
                let windowSamples = Int(SpeechLevel.windowDuration * Double(sampleRate))
                var sounded = 0.0
                var squares = 0.0
                var filled = 0
                while let buffer = output.copyNextSampleBuffer() {
                    defer { CMSampleBufferInvalidate(buffer) }
                    guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                    var length = 0
                    var bytes: UnsafeMutablePointer<Int8>?
                    guard CMBlockBufferGetDataPointer(
                        block, atOffset: 0, lengthAtOffsetOut: nil,
                        totalLengthOut: &length, dataPointerOut: &bytes) == noErr,
                        let bytes
                    else { continue }
                    let count = length / MemoryLayout<Int16>.size
                    bytes.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                        for index in 0..<count {
                            let value = Double(samples[index]) / Double(Int16.max)
                            squares += value * value
                            filled += 1
                            guard filled == windowSamples else { continue }
                            let rms = (squares / Double(windowSamples)).squareRoot()
                            if SpeechLevel.isSound(rms: rms) {
                                sounded += SpeechLevel.windowDuration
                            }
                            squares = 0
                            filled = 0
                        }
                    }
                }
                // The trailing partial window is dropped rather than scaled:
                // it is at most a tenth of a second against a threshold of
                // five, and scaling a short window would only make a quiet
                // tail look louder than it was.
                if reader.status == .failed {
                    continuation.resume(
                        throwing: reader.error ?? CocoaError(.fileReadCorruptFile))
                } else {
                    continuation.resume(returning: sounded)
                }
            }
        }
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
        guard chunk.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
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
            // The continuation throws rather than always resuming cleanly: a
            // nil from `copyNextSampleBuffer()` means either the end of the
            // range or a reader that failed partway through, and treating
            // both as a finish would hand the caller a silently truncated
            // file instead of an error. Both resume paths below return
            // immediately afterward, so the continuation resumes exactly once
            // no matter which branch is taken.
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

        // A reader that found no samples in its range still finishes cleanly
        // and still leaves a valid m4a — header, no audio. That file would be
        // base64'd and posted to a paid endpoint for a guaranteed empty
        // answer, so it is checked here instead of trusted.
        let written = (try? await duration(of: destination)) ?? 0
        guard written > 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
