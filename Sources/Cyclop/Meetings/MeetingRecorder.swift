import AVFoundation
import CyclopMeetings
import ScreenCaptureKit

/// Captures the meeting: screen and system audio into one mp4, the microphone
/// into a file of its own.
///
/// Two files rather than one mixed track, because the microphone lane is the
/// owner of this Mac and nobody else — recorded apart, that label becomes a
/// fact instead of the model's guess.
@MainActor
final class MeetingRecorder: NSObject {
    struct RecordingResult {
        let duration: TimeInterval
        let hasMicrophoneLane: Bool
    }

    enum Failure: LocalizedError {
        case noDisplay
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "no display to record"
            case .permissionDenied: return "screen recording is not allowed"
            }
        }
    }

    private(set) var isRecording = false

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var microphoneWriter: AVAssetWriter?
    private var microphoneInput: AVAssetWriterInput?
    private var startedAt: Date?
    private var microphoneWroteSamples = false
    // Set synchronously in the same MainActor turn as markAsFinished() (see
    // stop()), and checked at the top of appendMicrophone(). Needed because
    // finishWriting() below is a suspension point: a sample buffer already
    // queued on cyclop.meeting.mic before stop() was called can still hop in
    // through appendMicrophone while finishWriting is in flight, and its own
    // writer.status/isReadyForMoreMediaData checks don't reflect that
    // markAsFinished() already ran — appending to a finished input raises
    // NSInternalInconsistencyException, the same exception class as calling
    // finishWriting before startWriting. No lock needed: both this flag's
    // writer and appendMicrophone run on the MainActor executor.
    private var isFinishingMicrophone = false

    func start(into folder: MeetingFolder) async throws {
        guard !isRecording else { return }

        do {
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
            } catch {
                // The permission dialog is the usual reason this throws: the
                // request is refused before it reaches us.
                throw Failure.permissionDenied
            }
            guard let display = content.displays.first else { throw Failure.noDisplay }

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.captureMicrophone = true
            // The microphone arrives as its own stream so it can be written apart.
            configuration.width = min(display.width, 1920)
            configuration.height = min(display.height, 1080)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 6

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = folder.videoURL
            recordingConfiguration.outputFileType = .mp4
            recordingConfiguration.videoCodecType = .hevc
            // SCRecordingOutput's initializer takes a non-optional delegate (the
            // header has no nullable annotation on it, unlike SCStream's), so
            // `delegate: nil` does not compile here — see the conformance
            // below for what MeetingRecorder does with it.
            let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
            try stream.addRecordingOutput(output)

            try prepareMicrophoneWriter(at: folder.microphoneURL)
            try stream.addStreamOutput(
                self, type: .microphone,
                sampleHandlerQueue: DispatchQueue(label: "cyclop.meeting.mic"))

            try await stream.startCapture()

            self.stream = stream
            self.recordingOutput = output
            self.startedAt = Date()
            self.isRecording = true
        } catch {
            // Setup can fail after prepareMicrophoneWriter already created a
            // writer (addStreamOutput or startCapture throwing, for instance).
            // Drop it here rather than leaving a never-started AVAssetWriter
            // referenced by self: isRecording never became true on this path,
            // so nothing else will clean it up before the next start() call
            // reuses these two properties.
            microphoneWriter = nil
            microphoneInput = nil
            throw error
        }
    }

    func stop() async -> RecordingResult {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        isRecording = false

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        recordingOutput = nil

        isFinishingMicrophone = true
        microphoneInput?.markAsFinished()
        // Guarded on .writing rather than unwrapping unconditionally: if start(into:)
        // threw after prepareMicrophoneWriter but before the first sample arrived
        // (addStreamOutput or startCapture failing), the writer is still .unknown —
        // startWriting() was never called — and AVAssetWriter raises an
        // NSInternalInconsistencyException if finishWriting is invoked in that state.
        if let writer = microphoneWriter, writer.status == .writing {
            await writer.finishWriting()
        }
        let hadMicrophone = microphoneWroteSamples
        microphoneWriter = nil
        microphoneInput = nil
        microphoneWroteSamples = false
        isFinishingMicrophone = false
        startedAt = nil

        return RecordingResult(duration: duration, hasMicrophoneLane: hadMicrophone)
    }

    private func prepareMicrophoneWriter(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000,
            ]
        )
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        microphoneWriter = writer
        microphoneInput = input
    }
}

// Only didFailWithError is implemented: recordingOutputDidStartRecording and
// recordingOutputDidFinishRecording aren't needed yet, and this delegate
// exists in the first place only because SCRecordingOutput's initializer
// requires a non-optional one (see the comment at the call site in
// start(into:)). Without this, a mid-recording failure of the video lane —
// disk full, most plausibly — would be invisible: unlike the microphone,
// there is no equivalent of microphoneWroteSamples for the screen side to
// notice anything went wrong.
extension MeetingRecorder: SCRecordingOutputDelegate {
    /// ScreenCaptureKit gives no thread guarantee for this callback, and the
    /// body needs no isolation: logging touches nothing on self. An
    /// `@MainActor`-isolated conformance here would compile to a thunk that
    /// traps if the callback ever arrives off the main thread — the same
    /// reason SCStreamOutput.stream(_:didOutputSampleBuffer:of:) below is
    /// `nonisolated` with an explicit hop rather than isolated outright.
    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: Error
    ) {
        NSLog("Cyclop: meeting video recording failed: %@", error.localizedDescription)
    }
}

extension MeetingRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .microphone, sampleBuffer.isValid else { return }
        Task { @MainActor in
            self.appendMicrophone(sampleBuffer)
        }
    }
}

private extension MeetingRecorder {
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinishingMicrophone,
            let writer = microphoneWriter, let input = microphoneInput
        else { return }

        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            microphoneWroteSamples = true
        }
    }
}
