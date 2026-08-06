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

        var errorDescription: String? {
            switch self {
            case .noInput: return localized("No microphone available")
            case .converterUnavailable: return localized("Cannot convert microphone input")
            }
        }
    }

    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private(set) var isRecording = false

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
        samples.removeAll(keepingCapacity: true)

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

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
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
            Task { @MainActor in self.samples.append(contentsOf: chunk) }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops, normalises and writes the file. Returns nil when nothing was said.
    func stop() -> URL? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil

        guard samples.count > Int(Self.sampleRate / 4) else { return nil }
        var buffer = samples
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
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(buffer.count)) else { return }
        pcm.frameLength = AVAudioFrameCount(buffer.count)
        buffer.withUnsafeBufferPointer { source in
            pcm.floatChannelData![0].update(from: source.baseAddress!, count: buffer.count)
        }
        try file.write(from: pcm)
    }
}
