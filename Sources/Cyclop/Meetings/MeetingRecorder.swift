import AVFoundation
import CyclopMeetings
import ScreenCaptureKit

/// Whether the microphone is muted right now, readable from the render thread.
///
/// The tap runs on the audio render thread, which cannot hop to an actor to
/// ask: by the time an answer came back the buffer would be gone. A lock
/// around one Bool is the whole mechanism — the same shape `AudioLevel` uses
/// in dictation for the same reason.
final class MicrophoneGate: @unchecked Sendable {
    private var muted = false
    private let lock = NSLock()

    var isMuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return muted
    }

    func set(muted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.muted = muted
    }
}

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

    /// True from the first line of `stop()` to its last.
    ///
    /// A flag of its own rather than a wider reading of `isRecording`: the two
    /// answer different questions now that `stop()` suspends. `isRecording`
    /// answers "is a capture live" and has to go false at once, or the panel
    /// would keep offering to stop a recording that is already ending.
    /// `isStopping` answers "is the previous capture still being taken apart",
    /// and it stays true across the wait for the file to close — tens of
    /// milliseconds normally, the full five-second ceiling exactly on the
    /// capture-death path, which is the moment the offer card is most likely
    /// to be answered.
    ///
    /// A start let through that window would be torn down by the `stop()`
    /// still suspended inside it: the tail of `stop()` nils `stream` (the only
    /// strong reference, so the new capture ends), finishes the *new*
    /// microphone writer and clears `startedAt` — all while `isRecording` says
    /// true and the timer counts on over a capture that is already dead.
    private(set) var isStopping = false

    /// Called when the capture dies on its own: disk full, display
    /// disconnected, screen recording revoked mid-meeting. Without it the
    /// timer would go on counting over a file that stopped growing, which is
    /// exactly the case the spec asks to be said out loud.
    var onCaptureFailure: ((Error) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    /// The microphone is captured here rather than by ScreenCaptureKit, and
    /// through an engine rather than a plain capture session.
    ///
    /// Two separate reasons, both learned the hard way. ScreenCaptureKit is
    /// out because `SCStreamConfiguration.captureMicrophone` — the only way
    /// to get the `.microphone` stream output — also makes
    /// `SCRecordingOutput` mix the microphone into meeting.mp4, and
    /// `SCRecordingOutputConfiguration` gives no say over which tracks it
    /// writes: an output URL, a codec, a file type, nothing more. The owner's
    /// voice reached both lanes and a real transcript opened with the whole
    /// meeting duplicated.
    ///
    /// `AVAudioEngine` is here because it is the one that can turn on voice
    /// processing, and voice processing is what subtracts the speakers from
    /// the microphone. Without it, a Mac used without headphones records the
    /// call twice — 178 of one call's 215 owner lines were other people's
    /// words coming back through the room.
    private let engine = AVAudioEngine()
    /// Read by the tap, written from the panel. Muting stops the owner's
    /// voice reaching the file — the microphone of a Mac in a room hears the
    /// room, and a call taken on mute is exactly when someone turns to talk
    /// to whoever else is there.
    nonisolated let microphoneGate = MicrophoneGate()
    private var microphoneFile: AVAudioFile?
    /// The engine reconfigures itself without asking when the input device
    /// changes, and the tap built for the old format goes quiet.
    private var configurationObserver: NSObjectProtocol?
    private var microphoneConverter: AVAudioConverter?
    /// Encoding a buffer is file I/O and has no business on the render
    /// thread the tap runs on.
    private let microphoneQueue = DispatchQueue(label: "cyclop.meeting.mic")
    /// Held for exactly as long as the capture is live.
    ///
    /// A display that sleeps takes the capture down with it: ScreenCaptureKit
    /// loses its source and the stream dies with "no displays or windows to
    /// capture". This is not hypothetical — a 20-minute recording ended that
    /// way, at the idle timeout, while the person was still talking into it.
    /// Talking is not activity as far as that timer is concerned; it counts
    /// keys and the trackpad, so a meeting where someone listens and speaks
    /// looks exactly like an idle Mac.
    ///
    /// `beginActivity` rather than an IOKit assertion: it is the Foundation
    /// spelling of the same thing, and it is released for us if this process
    /// dies mid-meeting — an assertion leaked that way keeps the display lit
    /// until the Mac is restarted.
    private var activity: (any NSObjectProtocol)?
    private var startedAt: Date?
    private var microphoneWroteSamples = false
    /// The host-clock reading of the moment capture began. Tap buffers carry
    /// a host time from the same clock, which is what makes the microphone
    /// offset below a measurement rather than a guess.
    private var captureStartedAt: UInt64?
    private var microphoneOffset: TimeInterval = 0
    private var didFinishRecordingFile = false
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private var finishGeneration = 0
    private var reportedFailure = false
    /// Mirrors AudioRecorder's deinit in dictation: if this object is torn
    /// down while recording — the controller that owns it rebuilt, say — the
    /// engine must not outlive it, or the microphone stays open with nobody
    /// left to close it. Touching the engine without an actor hop is safe for
    /// the same reason it is there: this whole graph is rooted at
    /// @MainActor, so the last reference can only be released on the main
    /// thread, and nothing else can still be racing this call.
    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func start(into folder: MeetingFolder) async throws {
        guard !isRecording, !isStopping else { return }

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
            // captureMicrophone stays off deliberately — see `microphoneSession`
            // for what including it did to the transcript.
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

            // Prepared before the capture and started after it: the offset
            // below measures how far the microphone's first buffer trails the
            // video, which only means anything if the video is rolling first.
            let microphoneReady = await prepareMicrophone(at: folder.microphoneURL)

            try await stream.startCapture()

            self.stream = stream
            self.recordingOutput = output
            self.startedAt = Date()
            // The same clock the tap's AVAudioTime is on, read as close to
            // the first frame as this code can get. Comparing against any
            // other clock would make the offset a number without meaning.
            self.captureStartedAt = mach_absolute_time()
            if microphoneReady {
                startMicrophone()
            }
            // .userInitiated as well as the display option: a recording is
            // something a person asked for, and App Nap throttling the timers
            // of a window that is not on screen is the other half of the same
            // problem.
            self.activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: "Recording a meeting")
            self.isRecording = true
        } catch {
            // Setup can fail after prepareMicrophone already opened a file
            // and installed a tap (startCapture throwing, for instance).
            // Taken apart here rather than left referenced by self:
            // isRecording never became true on this path, so nothing else
            // will clean it up before the next start() reuses these.
            stopMicrophone()
            throw error
        }
    }

    func stop() async -> MeetingRecording {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        isRecording = false
        isStopping = true
        // Cleared on the way out rather than before the return below, so that
        // no future early exit from this function can leave the recorder
        // refusing to start for good.
        defer { isStopping = false }

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

        // Ended here rather than at the very end of stop(): everything below
        // is file work, and none of it needs the display to stay lit.
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }

        // The tap comes off before the file closes, and the queue is
        // drained after: a buffer already handed to microphoneQueue must
        // finish writing before the file reference goes, or the tail of the
        // meeting is lost.
        stopMicrophone()

        let hadMicrophone = microphoneWroteSamples
        let offset = microphoneOffset
        microphoneWroteSamples = false
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

    /// Opens the file, builds the converter and installs the tap.
    ///
    /// Returns false when there is no microphone lane to be had. False rather
    /// than a thrown error: the microphone is the auxiliary lane —
    /// `MeetingProcessor` treats its absence as a missing lane and
    /// `TranscriptDocument` says so in the file — and a refused permission or
    /// a Mac with no input device must not stop the screen and the call
    /// itself from being recorded.
    private func prepareMicrophone(at url: URL) async -> Bool {
        // Asked for by the act of starting a recording, never at launch: the
        // same discipline the rest of the app follows.
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            NSLog("Cyclop: meeting microphone refused, recording the screen alone")
            return false
        }

        let input = engine.inputNode
        // The whole reason this lane goes through an engine. Voice processing
        // is macOS's acoustic echo canceller: it subtracts what the speakers
        // are playing from what the microphone hears, which is exactly the
        // duplication this recording suffers from without headphones. It
        // throws on hardware that cannot do it, and that is not fatal — a
        // lane with echo in it is still worth more than no lane, and
        // TranscriptMerger drops the echo from the transcript afterwards.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            NSLog("Cyclop: no echo cancellation for this microphone (%@)",
                error.localizedDescription)
        }

        // Read after voice processing is on: turning it on reconfigures the
        // node, and the format from before would describe the wrong stream.
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            NSLog("Cyclop: no usable microphone for the meeting's own lane")
            return false
        }

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000,
                ]
            )
            guard let converter = AVAudioConverter(
                from: inputFormat, to: file.processingFormat)
            else {
                NSLog("Cyclop: cannot convert the microphone into the meeting's own lane")
                return false
            }
            microphoneFile = file
            microphoneConverter = converter
        } catch {
            NSLog("Cyclop: cannot open the meeting's microphone file (%@)",
                error.localizedDescription)
            return false
        }

        installMicrophoneTap(on: input, from: inputFormat)
        // The engine reconfigures itself — without asking — when the input
        // device changes: headphones plugged in mid-call, the system default
        // switched, a dock unplugged. The tap and converter above were built
        // for the format that was current a moment ago, and left alone the
        // lane goes silent for the rest of the recording. Dictation answers
        // this by ending the take; a meeting cannot, it would be ending the
        // very thing that cannot be recorded again.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildMicrophoneTap() }
        }
        return true
    }

    /// Rebuilds the tap around whatever device is current now.
    ///
    /// The file is kept: its processing format never changes, so only the
    /// converter feeding it has to be replaced. What was already written
    /// stays, and the recording carries on into the same file.
    private func rebuildMicrophoneTap() {
        guard isRecording, let file = microphoneFile else { return }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // Voice processing does not always survive the switch, and without it
        // the new device hears the speakers again.
        if !input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(true)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0,
            let converter = AVAudioConverter(from: format, to: file.processingFormat)
        else {
            NSLog("Cyclop: the microphone did not come back after the device change")
            return
        }
        microphoneConverter = converter
        installMicrophoneTap(on: input, from: format)
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("Cyclop: the engine would not restart after the device change (%@)",
                    error.localizedDescription)
            }
        }
    }

    /// Mutes or unmutes the owner's lane mid-recording.
    func setMicrophone(muted: Bool) {
        microphoneGate.set(muted: muted)
    }

    /// The tap: convert on the render thread, write on our own queue.
    ///
    /// Split that way because encoding to AAC is file I/O, and the render
    /// thread must not wait on a disk. The conversion itself stays here: it
    /// is arithmetic over a buffer that only exists for the length of this
    /// call.
    private func installMicrophoneTap(on input: AVAudioInputNode, from format: AVAudioFormat) {
        // The file and the converter are captured rather than reached for
        // through self: the tap block is retained by the engine, and a
        // capture of self would be a cycle through engine -> block -> self ->
        // engine. Same reasoning as AudioRecorder's tap in dictation.
        guard let file = microphoneFile, let converter = microphoneConverter else { return }
        let target = file.processingFormat
        let queue = microphoneQueue
        let gate = microphoneGate

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            let ratio = target.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
            else { return }

            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0 else { return }

            // Muted writes silence rather than nothing at all. A gap would
            // shorten mic.m4a against the meeting it is merged with, and
            // every timecode after the pause would slide by the length of it.
            if gate.isMuted, let channels = converted.floatChannelData {
                for channel in 0..<Int(converted.format.channelCount) {
                    channels[channel].update(repeating: 0, count: Int(converted.frameLength))
                }
            }

            // The first buffer's host time is what the offset is measured
            // from — see `microphoneOffset`. Reported from here because this
            // is the only place that sees it.
            let hostTime = when.isHostTimeValid ? when.hostTime : 0
            queue.async {
                do {
                    try file.write(from: converted)
                    Task { @MainActor in self?.microphoneDidWrite(at: hostTime) }
                } catch {
                    NSLog("Cyclop: dropped a microphone buffer (%@)", error.localizedDescription)
                }
            }
        }
    }

    /// Starting the engine is the moment the microphone actually opens.
    private func startMicrophone() {
        do {
            try engine.start()
        } catch {
            NSLog("Cyclop: the meeting's microphone engine would not start (%@)",
                error.localizedDescription)
            stopMicrophone()
        }
    }

    /// Takes the whole microphone path apart, in the one order that is safe.
    ///
    /// Tap first so nothing new arrives, then the engine, then a barrier on
    /// the writing queue so a buffer already in flight lands before the file
    /// is released — closing the file under it would lose the tail of the
    /// meeting, which is the part people replay.
    private func stopMicrophone() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        microphoneGate.set(muted: false)
        guard microphoneFile != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        microphoneQueue.sync {}
        microphoneFile = nil
        microphoneConverter = nil
    }

    /// One written buffer, reported back on the MainActor.
    private func microphoneDidWrite(at hostTime: UInt64) {
        guard !microphoneWroteSamples else { return }
        microphoneWroteSamples = true
        // mic.m4a's zero is this first buffer, while meeting.mp4's zero is
        // the start of the capture. Those are not the same instant: the
        // engine is started after the stream and the input device takes its
        // own time to deliver, which on a Bluetooth headset is long enough to
        // hear. The merge weaves the two lanes by timecode, so the gap is
        // measured once here and carried through to it.
        guard let started = captureStartedAt, hostTime > started else { return }
        let elapsed = AVAudioTime.seconds(forHostTime: hostTime - started)
        microphoneOffset = elapsed.isFinite ? max(0, elapsed) : 0
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
    /// AVCaptureAudioDataOutputSampleBufferDelegate below does it this way
    /// too.
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
