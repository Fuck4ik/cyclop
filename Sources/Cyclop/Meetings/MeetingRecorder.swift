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

    /// Called when the capture dies on its own: disk full, display
    /// disconnected, screen recording revoked mid-meeting. Without it the
    /// timer would go on counting over a file that stopped growing, which is
    /// exactly the case the spec asks to be said out loud.
    var onCaptureFailure: ((Error) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var microphoneWriter: AVAssetWriter?
    private var microphoneInput: AVAssetWriterInput?
    private var startedAt: Date?
    private var microphoneWroteSamples = false
    /// The host-clock reading of the moment capture began. Sample buffers are
    /// stamped against the same clock, which is what makes the microphone
    /// offset below a measurement rather than a guess.
    private var captureStartedAt: CMTime?
    private var microphoneOffset: TimeInterval = 0
    private var didFinishRecordingFile = false
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private var finishGeneration = 0
    private var reportedFailure = false
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

        didFinishRecordingFile = false
        reportedFailure = false
        microphoneOffset = 0
        captureStartedAt = nil

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
            // One scale factor for both sides, not a clamp per side: clamping
            // them apart squeezes anything that is not 16:9 — a 16:10 display
            // loses its proportions and a portrait one is mangled outright.
            // These frames have to stay readable, they are what the screenshot
            // stage will be cut from.
            let scale = min(
                1, 1920 / Double(display.width), 1080 / Double(display.height))
            configuration.width = Self.evenDimension(Double(display.width) * scale)
            configuration.height = Self.evenDimension(Double(display.height) * scale)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 6

            let filter = SCContentFilter(display: display, excludingWindows: [])
            // delegate: self — a stream that dies mid-meeting (disk full, the
            // display unplugged, the permission taken away) reports it only
            // here, and with nil it would be a silent stop under a running
            // timer.
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

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
            // Read on the same clock the sample buffers are stamped against,
            // as close to the first frame as this code can get.
            self.captureStartedAt = CMClockGetTime(CMClockGetHostTimeClock())
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

    func stop() async -> MeetingRecording {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        isRecording = false

        if let stream {
            try? await stream.stopCapture()
            // stopCapture() returns when the stream is torn down, not when
            // the file is closed: SCRecordingOutput finishes writing the moov
            // atom afterwards and says so through the delegate. Reading the
            // file before that lands races the writer — and MeetingProcessor's
            // very first act is to measure this recording, so the race would
            // show up as an intermittently short or unopenable file.
            await waitForRecordingToFinish()
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
        let offset = microphoneOffset
        microphoneWriter = nil
        microphoneInput = nil
        microphoneWroteSamples = false
        isFinishingMicrophone = false
        startedAt = nil
        captureStartedAt = nil
        microphoneOffset = 0

        return MeetingRecording(
            duration: duration, hasMicrophoneLane: hadMicrophone, microphoneOffset: offset)
    }

    /// Waits for the recording file to be closed, with a ceiling.
    ///
    /// The delegate callback is the only signal ScreenCaptureKit gives, and a
    /// stream that already died may never send it — so the wait cannot be
    /// unbounded. Finalisation takes tens of milliseconds; five seconds is far
    /// past that, and still cheaper than reading a half-written moov atom.
    private func waitForRecordingToFinish() async {
        guard !didFinishRecordingFile else { return }
        finishGeneration += 1
        let generation = finishGeneration
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishWaiter = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                // Tied to the wait it was started for: the callback usually
                // arrives in milliseconds and leaves this sleeper running for
                // the rest of its five seconds, by which time the next
                // meeting may already be stopping. Without the generation it
                // would cut that one's wait short.
                guard self.finishGeneration == generation else { return }
                self.resumeFinishWaiter()
            }
        }
    }

    /// Whoever gets here first wins; the other finds nothing to resume. Both
    /// callers run on the MainActor, so no lock is needed to make that true.
    private func resumeFinishWaiter() {
        guard let waiter = finishWaiter else { return }
        finishWaiter = nil
        waiter.resume()
    }

    private func markRecordingFinished() {
        didFinishRecordingFile = true
        resumeFinishWaiter()
    }

    /// Reported once per recording: a dying capture tends to say so twice —
    /// the recording output fails and the stream stops right behind it — and
    /// the controller must not stop the same meeting twice over.
    private func reportCaptureFailure(_ error: Error) {
        guard isRecording, !reportedFailure else { return }
        reportedFailure = true
        onCaptureFailure?(error)
    }

    /// HEVC wants even dimensions, and a scaled odd display size lands on odd
    /// numbers half the time.
    private static func evenDimension(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
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

// Two of the three callbacks are implemented. didFinishRecording is what
// stop() waits on — it is the only word there is that the file has been
// closed. didFailWithError covers a mid-recording death of the video lane —
// disk full, most plausibly — which nothing else would notice: unlike the
// microphone, the screen side has no equivalent of microphoneWroteSamples.
// recordingOutputDidStartRecording is genuinely not needed: startCapture()
// returning already says the capture began.
extension MeetingRecorder: SCRecordingOutputDelegate {
    /// ScreenCaptureKit gives no thread guarantee for these callbacks, so the
    /// conformance is `nonisolated` and hops explicitly. An
    /// `@MainActor`-isolated conformance would compile to a thunk that traps
    /// if the callback ever arrives off the main thread — the same reason
    /// SCStreamOutput.stream(_:didOutputSampleBuffer:of:) below does it this
    /// way too.
    nonisolated func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: Error
    ) {
        NSLog("Cyclop: meeting video recording failed: %@", error.localizedDescription)
        Task { @MainActor in
            // Nothing further will be written, so there is nothing left to
            // wait for either: release stop() before its ceiling expires.
            self.markRecordingFinished()
            self.reportCaptureFailure(error)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.markRecordingFinished() }
    }
}

extension MeetingRecorder: SCStreamDelegate {
    /// The stream stopping by itself is always an error — a clean stopCapture()
    /// does not come through here. The recording output is left to close its
    /// own file; stop() still waits for it.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Cyclop: meeting capture stopped: %@", error.localizedDescription)
        Task { @MainActor in self.reportCaptureFailure(error) }
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
            // mic.m4a's zero is this first sample, while meeting.mp4's zero is
            // the start of the capture. Those are not the same instant: the
            // microphone permission dialog sits in exactly that gap, and it
            // can hold for as long as a person takes to answer it. The merge
            // weaves the two lanes by timecode, so the gap is measured here
            // once and carried through to it — granting the microphone ten
            // seconds in would otherwise put every owner line ten seconds
            // early for the whole meeting.
            if let started = captureStartedAt {
                let gap = (sampleBuffer.presentationTimeStamp - started).seconds
                microphoneOffset = gap.isFinite ? max(0, gap) : 0
            }
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            microphoneWroteSamples = true
        }
    }
}
