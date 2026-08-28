import CyclopMeetings
import Foundation

/// From two recorded files to a finished transcript.md.
///
/// Ordered so that the irreplaceable part survives the replaceable one: the
/// transcript is written even if the summary request fails. The recording
/// cannot be made again, and a meeting without a summary is still useful,
/// while a summary without a transcript is not.
final class MeetingProcessor {
    static let model = "gemini-3.7-flash-high"

    private let client: AudioTranscriptionClient

    init(client: AudioTranscriptionClient = AudioTranscriptionClient()) {
        self.client = client
    }

    func process(
        _ folder: MeetingFolder,
        duration: TimeInterval,
        hasMicrophoneLane: Bool,
        ownerName: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        try write(.init(state: .processing, duration: duration), to: folder)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyclop-meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let system = try await transcribe(
            source: folder.videoURL, scratch: scratch, label: "system", progress: progress)

        var microphone: [TranscriptSegment] = []
        if hasMicrophoneLane, await MeetingAudio.hasAudioTrack(folder.microphoneURL) {
            microphone = try await transcribe(
                source: folder.microphoneURL, scratch: scratch, label: "mic", progress: progress)
        }

        let segments = TranscriptMerger.merge(
            microphone: microphone, system: system, ownerName: ownerName)

        // The summary is asked for last and its failure is swallowed: losing
        // it costs a section, losing the transcript costs the meeting.
        progress("итоги")
        var summary = ""
        do {
            let lines = segments.map(\.line).joined(separator: "\n")
            summary = try await client.complete(
                prompt: MeetingPrompts.summary(for: lines), model: Self.model)
        } catch {
            NSLog("Cyclop: meeting summary failed (%@)", error.localizedDescription)
        }

        let document = TranscriptDocument(
            date: folder.startedAt,
            duration: duration,
            videoFileName: MeetingFolder.videoFileName,
            summary: summary,
            segments: segments,
            hasMicrophoneLane: !microphone.isEmpty
        )
        try document.render().write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
        try write(.init(state: .ready, duration: duration), to: folder)
    }

    private func transcribe(
        source: URL,
        scratch: URL,
        label: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [TranscriptSegment] {
        // The chunk plan is built from this file's own measured duration, not
        // from the caller's stopwatch: the stopwatch counts wall-clock time
        // and can run past what a particular track actually holds (a stream
        // that started late, a writer that dropped its tail). A chunk whose
        // start lands beyond the real audio makes MeetingAudio.compressed
        // export a silent zero-byte file instead of throwing — a known,
        // documented weakness of that function — and that file would then be
        // sent to a paid API. Measuring the file being cut keeps that chunk
        // from ever being produced.
        let measured = try await MeetingAudio.duration(of: source)
        let chunks = ChunkPlan.chunks(forDuration: measured)
        var segments: [TranscriptSegment] = []

        for (index, chunk) in chunks.enumerated() {
            progress("\(label) \(index + 1)/\(chunks.count)")

            let piece = scratch.appendingPathComponent("\(label)-\(index).m4a")
            try await MeetingAudio.compressed(from: source, chunk: chunk, to: piece)

            let answer = try await client.transcribe(
                audio: try Data(contentsOf: piece),
                prompt: MeetingPrompts.transcription,
                model: Self.model
            )
            // Every chunk counts time from its own zero, so the offset is put
            // back here rather than hoped for from the model.
            segments += TranscriptParser.segments(from: answer)
                .map { $0.shifted(by: chunk.start) }
        }
        return segments
    }

    private func write(_ state: MeetingStateFile, to folder: MeetingFolder) throws {
        try state.encoded().write(to: folder.stateURL, options: .atomic)
    }

    /// Called when something threw: the recording stays, the reason is written
    /// down, and the meeting can be retried from the list.
    func markFailed(_ folder: MeetingFolder, duration: TimeInterval, reason: String) {
        try? write(.init(state: .failed, duration: duration, failure: reason), to: folder)
    }
}
