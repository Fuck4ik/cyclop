import CyclopDictation
import CyclopMeetings
import Foundation

/// From two recorded files to a finished transcript.md.
///
/// Ordered so that the irreplaceable part survives the replaceable one: the
/// transcript is written even if the summary request fails. The recording
/// cannot be made again, and a meeting without a summary is still useful,
/// while a summary without a transcript is not.
final class MeetingProcessor {
    /// Processing's own failures, the ones that have a code instead of a
    /// system message. Everything else reaches the controller as it came.
    enum Failure: Error {
        case nothingRecognised

        var reason: MeetingFailure {
            switch self {
            case .nothingRecognised: return .nothingRecognised
            }
        }
    }

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
        progress: @escaping @Sendable (MeetingProgress) -> Void
    ) async throws {
        try write(.init(state: .processing, duration: duration), to: folder)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyclop-meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let system = try await transcribe(
            source: folder.videoURL, scratch: scratch, lane: .system, progress: progress)

        // Nothing parsed means the model's shape drifted past the parser
        // entirely — the request succeeded, so no error was thrown anywhere.
        // Writing a transcript.md with an empty «Расшифровка» and calling it
        // .ready would hide that twice over: the row reads as finished, and
        // retry only shows for .failed, so there would be no way back. The
        // answer is kept next to the recording first: it was paid for, and it
        // is the only thing a parser fix could be tested against.
        guard !system.segments.isEmpty else {
            try? system.answer.write(to: folder.rawAnswerURL, atomically: true, encoding: .utf8)
            throw Failure.nothingRecognised
        }

        // The microphone lane is auxiliary in the same sense the summary
        // below is: it is the owner's separate voice track, not the meeting
        // itself. Losing it costs a lane — TranscriptDocument already renders
        // its absence as a warning and hasMicrophoneLane already tells the
        // truth from an empty array — so its failure is logged and swallowed
        // rather than thrown. The system lane above stays fatal: if it fails
        // there is nothing worth writing, and the already-paid-for system
        // transcription must not be discarded over an auxiliary lane's error.
        var microphone: [TranscriptSegment] = []
        if hasMicrophoneLane, await MeetingAudio.hasAudioTrack(folder.microphoneURL) {
            do {
                microphone = try await transcribe(
                    source: folder.microphoneURL, scratch: scratch, lane: .microphone,
                    progress: progress
                ).segments
            } catch {
                NSLog("Cyclop: meeting microphone lane failed (%@)", error.localizedDescription)
            }
        }

        let segments = TranscriptMerger.merge(
            microphone: microphone, system: system.segments, ownerName: ownerName)

        // The summary is asked for last and its failure is swallowed: losing
        // it costs a section, losing the transcript costs the meeting.
        progress(.summary)
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

    /// One lane, start to finish. The raw answers come back alongside the
    /// segments so that a lane which parsed to nothing still has something to
    /// show for the requests it paid for.
    private func transcribe(
        source: URL,
        scratch: URL,
        lane: MeetingProgress.Lane,
        progress: @escaping @Sendable (MeetingProgress) -> Void
    ) async throws -> (segments: [TranscriptSegment], answer: String) {
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
        var answers: [String] = []
        let name = lane == .system ? "system" : "mic"

        for (index, chunk) in chunks.enumerated() {
            progress(.lane(lane, index: index + 1, count: chunks.count))

            let piece = scratch.appendingPathComponent("\(name)-\(index).m4a")
            try await MeetingAudio.compressed(from: source, chunk: chunk, to: piece)

            // MeetingAudio writes AAC into an MP4 container, so that is what
            // the request has to say it is — see the type's own comment.
            let answer = try await client.transcribe(
                audio: try Data(contentsOf: piece),
                mimeType: CloudTranscription.mp4AudioMimeType,
                prompt: MeetingPrompts.transcription,
                model: Self.model
            )
            answers.append(answer)
            // Every chunk counts time from its own zero, so the offset is put
            // back here rather than hoped for from the model.
            segments += TranscriptParser.segments(from: answer)
                .map { $0.shifted(by: chunk.start) }
        }
        return (segments, answers.joined(separator: "\n\n"))
    }

    private func write(_ state: MeetingStateFile, to folder: MeetingFolder) throws {
        try state.encoded().write(to: folder.stateURL, options: .atomic)
    }

    /// Called when something threw: the recording stays, the reason is written
    /// down, and the meeting can be retried from the list.
    func markFailed(_ folder: MeetingFolder, duration: TimeInterval, reason: MeetingFailure) {
        try? write(
            .init(state: .failed, duration: duration, failure: reason.stored), to: folder)
    }
}
