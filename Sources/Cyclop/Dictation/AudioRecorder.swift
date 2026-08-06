import AVFoundation
import CyclopDictation

/// Microphone capture at the rate Whisper wants: 16 kHz mono.
///
/// The samples stay in memory and are normalised there; the file is written
/// once, at the end, and only so the recording can be replayed from history.
/// The transcriber is handed the same path, but nothing re-reads the audio
/// three times over the way the standalone app did.
@MainActor
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case noInput
        case converterUnavailable
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noInput: return localized("No microphone available")
            case .converterUnavailable: return localized("Cannot convert microphone input")
            case .writeFailed: return localized("Cannot save the recording")
            }
        }
    }

    private let engine = AVAudioEngine()
    // Sendable and lock-protected, so the render thread's tap callback can
    // append synchronously — no actor hop, no queue for stop() to race
    // against. See SampleAccumulator's own comment for why that matters.
    private nonisolated let accumulator = SampleAccumulator()
    private var converter: AVAudioConverter?
    private(set) var isRecording = false

    /// Fired when the recording is cut short by a device change rather than
    /// by the user releasing the key — see `handleConfigurationChange`. Nil
    /// (nothing usable was captured before the switch) is a valid value.
    var onInterrupted: ((URL?) -> Void)?

    private var configurationObserver: NSObjectProtocol?

    nonisolated deinit {
        // Mirrors HotkeyMonitor's deinit: if stop() was never called — e.g.
        // the controller that owns this recorder is torn down mid-recording,
        // which happens for real when NotchController.rebuild() reacts to a
        // screen configuration change — the engine must not outlive this
        // object. Left running, it keeps pulling microphone samples into an
        // accumulator nobody will ever drain again: the mic stays open and
        // memory grows without bound until the app is relaunched. Touching
        // engine and the observer directly (no actor hop) is safe here for
        // the same reason it is for the tap and source in HotkeyMonitor: this
        // whole object graph is rooted at @MainActor, so the last reference
        // can only be released on the main thread, and nothing else is left
        // that could still be racing this call for access to self.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let configurationObserver = self.configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    private static let sampleRate: Double = 16_000

    static var folder: URL = {
        let fm = FileManager.default
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cyclop", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    func start() throws {
        guard !isRecording else { return }
        // Defensive: a buffer from the *previous* take can in theory still be
        // mid-flight on the render thread when its stop() already called
        // removeTap and drained — Apple does not guarantee zero in-flight
        // callbacks the instant removeTap returns. Flushing here keeps such a
        // stray sample out of this new recording instead of prefixing it.
        accumulator.drain()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else { throw RecorderError.noInput }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        // Capture the accumulator only, not self: it is the one thing this
        // closure needs from the instance, and capturing it directly (rather
        // than `[weak self]` plus a hop back to the instance) also avoids a
        // retain cycle through engine -> tap block -> self -> engine.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [accumulator] buffer, _ in
            let ratio = Self.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

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
            guard error == nil, let channel = converted.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            accumulator.append(chunk)
        }

        // The engine reconfigures itself — without asking — when the input
        // device changes: the microphone is unplugged, or the system default
        // switches. The tap and converter above were built for the format
        // that was current at start(); left alone, the next buffer either
        // crashes on a format mismatch or converts silently into nothing.
        // Ending the take immediately, on whatever is left in the
        // accumulator, beats both.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops, normalises and writes the file. Returns nil when nothing was said.
    func stop() -> URL? {
        guard isRecording else { return nil }
        return finish()
    }

    /// Ends capture and writes whatever was collected. Shared by the normal
    /// stop() path and by handleConfigurationChange(): a device switch
    /// mid-recording should end the take the same way a key release does,
    /// not throw away everything said before the switch.
    private func finish() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil

        var buffer = accumulator.drain()
        guard buffer.count > Int(Self.sampleRate / 4) else { return nil }
        let gain = AudioNormalizer.normalize(&buffer)
        if gain > 0 { NSLog("Cyclop: dictation normalised by +%.1f dB", gain) }

        let url = Self.folder.appendingPathComponent("dictation-\(Self.stamp.string(from: Date())).wav")
        do {
            try write(buffer, to: url)
            return url
        } catch {
            NSLog("Cyclop: cannot write dictation: \(error.localizedDescription)")
            return nil
        }
    }

    private func handleConfigurationChange() {
        guard isRecording else { return }
        NSLog("Cyclop: audio input reconfigured mid-recording, ending dictation early")
        onInterrupted?(finish())
    }

    private func write(_ buffer: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(buffer.count)) else {
            // Only fails under extreme memory pressure — format and frame
            // count above are always valid — but silently returning here used
            // to let stop() hand back a URL to a file nothing had been
            // written to, rather than surfacing the failure.
            throw RecorderError.writeFailed
        }
        pcm.frameLength = AVAudioFrameCount(buffer.count)
        buffer.withUnsafeBufferPointer { source in
            pcm.floatChannelData![0].update(from: source.baseAddress!, count: buffer.count)
        }
        try file.write(from: pcm)
    }
}
