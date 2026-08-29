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

    /// The same model dictation uses, named once. A second literal here would
    /// have been a second thing to remember when the model changes.
    private static let model = CloudTranscription.defaultModel

    private let client: AudioTranscriptionClient

    /// The stages of the meeting currently being processed, kept so that a
    /// failure can record how far it got without the caller having to know.
    private var currentStages = MeetingStages()

    init(client: AudioTranscriptionClient = AudioTranscriptionClient()) {
        self.client = client
    }

    func process(
        _ folder: MeetingFolder,
        recording: MeetingRecording,
        ownerName: String,
        progress: @escaping @Sendable (MeetingProgress) -> Void
    ) async throws {
        // Both reset before the first write, which can throw: an early exit
        // past them would leave the previous meeting's stages in place, and
        // the failure of this one would be recorded with another's progress.
        var stages = MeetingStages()
        currentStages = MeetingStages()

        try write(.processing, recording, to: folder)

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
        if recording.hasMicrophoneLane, await MeetingAudio.hasAudioTrack(folder.microphoneURL) {
            do {
                // mic.m4a counts from its own first sample, the meeting counts
                // from the start of the capture. The lanes are merged by
                // timecode, so the difference between those two zeros is put
                // back before the merge ever sees them.
                microphone = try await transcribe(
                    source: folder.microphoneURL, scratch: scratch, lane: .microphone,
                    progress: progress
                ).segments.map { $0.shifted(by: recording.microphoneOffset) }
            } catch {
                NSLog("Cyclop: meeting microphone lane failed (%@)", error.localizedDescription)
            }
        }

        let segments = TranscriptMerger.merge(
            microphone: microphone, system: system.segments, ownerName: ownerName)

        // The transcript goes to disk the moment it exists, before the frames
        // and the names that now stand between it and the end of processing.
        // Those take minutes and a dozen requests; a crash or a quit in that
        // window used to lose the one thing that cannot be recorded again.
        // The file is rewritten at the end with everything else in it.
        try? TranscriptDocument(
            date: folder.startedAt,
            duration: recording.duration,
            videoFileName: MeetingFolder.videoFileName,
            summary: "",
            segments: segments,
            hasMicrophoneLane: !microphone.isEmpty
        ).render().write(to: folder.transcriptURL, atomically: true, encoding: .utf8)

        stages.transcribed = true
        currentStages = stages
        try? write(.processing, recording, stages: stages, to: folder)

        // Frames and names are auxiliary in the same sense the summary is:
        // their failure costs a section, not the meeting. Everything here is
        // wrapped so that a transcript is written no matter what went wrong.
        var notes: [ScreenNote] = []
        var rendered: [ScreenNote] = []
        var skipped = 0
        var participants: [Participant] = []
        var named = segments

        let lines = segments.map(\.line).joined(separator: "\n")

        if FileManager.default.fileExists(atPath: folder.videoURL.path) {
            do {
                (notes, rendered, skipped) = try await readScreens(
                    folder: folder, transcript: lines,
                    duration: recording.duration, progress: progress)
                // Seen from outside readScreens, the stage either ran to
                // completion or it did not — the three flags move together.
                stages.framesPlanned = true
                stages.framesExtracted = true
                stages.framesRead = true
                currentStages = stages
                try? write(.processing, recording, stages: stages, to: folder)
            } catch {
                NSLog("Cyclop: meeting frames failed (%@)", error.localizedDescription)
            }
        }

        progress(.participants)
        do {
            let names = ParticipantRoster.candidateNames(
                owner: ownerName.isEmpty ? nil : ownerName, calendar: [], notes: notes)
            if !names.isEmpty {
                let answer = try await client.complete(
                    prompt: MeetingPrompts.participants(
                        transcript: lines,
                        profiles: SpeakerProfiler.profiles(of: segments),
                        names: names),
                    model: Self.model)
                let resolutions = SpeakerResolutionParser.resolutions(from: answer)
                named = SpeakerRelabeler.apply(resolutions, to: segments)
                participants = resolutions.map {
                    Participant(name: $0.name, role: nil,
                                confidence: $0.confidence, evidence: $0.evidence)
                }
                stages.participantsResolved = true
                currentStages = stages
                try? write(.processing, recording, stages: stages, to: folder)
            }
        } catch {
            NSLog("Cyclop: meeting participants failed (%@)", error.localizedDescription)
        }

        // The summary is asked for last and its failure is swallowed: losing
        // it costs a section, losing the transcript costs the meeting.
        progress(.summary)
        var summary = ""
        do {
            let summaryLines = named.map(\.line).joined(separator: "\n")
            summary = try await client.complete(
                prompt: MeetingPrompts.summary(for: summaryLines), model: Self.model)
        } catch {
            NSLog("Cyclop: meeting summary failed (%@)", error.localizedDescription)
        }

        let document = TranscriptDocument(
            date: folder.startedAt,
            duration: recording.duration,
            videoFileName: MeetingFolder.videoFileName,
            summary: summary,
            segments: named,
            hasMicrophoneLane: !microphone.isEmpty,
            participants: participants,
            notes: rendered,
            skippedFrames: skipped
        )
        try document.render().write(to: folder.transcriptURL, atomically: true, encoding: .utf8)
        try write(.ready, recording, stages: stages, to: folder)
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
        // The chunk plan is built from the audio's own measured length, not
        // from the caller's stopwatch and not from the asset: the stopwatch
        // counts wall-clock time, and meeting.mp4's asset duration is its
        // video track's, either of which can run past where the audio ends.
        // A chunk starting past the last sample has nothing to export — and
        // it would still cost a request.
        let measured = try await MeetingAudio.audioDuration(of: source)
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

    /// From a transcript to described screens on disk.
    ///
    /// Returns what was kept and how many moments were dropped — the header
    /// says both, because silently losing coverage reads as full coverage.
    private func readScreens(
        folder: MeetingFolder,
        transcript: String,
        duration: TimeInterval,
        progress: @escaping @Sendable (MeetingProgress) -> Void
    ) async throws -> (all: [ScreenNote], rendered: [ScreenNote], skipped: Int) {
        let budget = FramePlan.budget(forDuration: duration)
        let answer = try await client.complete(
            prompt: MeetingPrompts.frameCandidates(for: transcript, budget: budget),
            model: Self.model)
        let planned = FramePlan.selected(
            from: FrameCandidateParser.candidates(from: answer), budget: budget)
        guard !planned.isEmpty else { return ([], [], 0) }

        let frames = await MeetingFrames.jpeg(
            from: folder.videoURL, at: planned.map(\.start))

        // The third filter: a frame showing the same screen as the one kept
        // before it buys nothing and costs a request.
        var kept: [(candidate: FrameCandidate, data: Data)] = []
        for candidate in planned {
            guard let data = frames[candidate.start] else { continue }
            // Priority 1 means the transcript is incomplete without this
            // screen, and the similarity filter cannot be trusted to keep it:
            // it averages the difference over the whole frame, so an opened
            // menu or a single switched flag drowns below the threshold and
            // the very moment the model asked for would be dropped as a
            // duplicate.
            let mustKeep = candidate.priority == 1
            if !mustKeep, let previous = kept.last?.data,
               !MeetingFrames.differs(data, from: previous) {
                continue
            }
            kept.append((candidate, data))
        }

        try FileManager.default.createDirectory(
            at: folder.screensURL, withIntermediateDirectories: true)

        var notes: [ScreenNote] = []
        let batches = stride(from: 0, to: kept.count, by: 4).map {
            Array(kept[$0..<min($0 + 4, kept.count)])
        }
        for (index, batch) in batches.enumerated() {
            progress(.frames(index: index + 1, count: batches.count))
            do {
                let described = try await client.complete(
                    prompt: MeetingPrompts.screenNotes(for: batch.map {
                        (timecode: timecode($0.candidate.start),
                         expectation: $0.candidate.expectation,
                         context: context(around: $0.candidate.start, in: transcript))
                    }),
                    images: batch.map(\.data),
                    model: Self.model
                )
                notes += ScreenNoteParser.notes(from: described)
            } catch {
                // One batch pays for itself and not for its neighbours: the
                // requests already answered are worth keeping.
                NSLog("Cyclop: meeting frame batch %d failed (%@)",
                      index + 1, error.localizedDescription)
            }
        }

        var rendered: [ScreenNote] = []
        for note in ScreenHarvest.renderable(notes, captured: Set(kept.map(\.candidate.start))) {
            guard let data = kept.first(where: { $0.candidate.start == note.start })?.data,
                  (try? data.write(to: folder.screensURL.appendingPathComponent(note.fileName))) != nil
            else { continue }
            rendered.append(note)
        }
        // Counted against what was planned, so the header reads as «so many of
        // the moments we set out to catch» however the middle went.
        return (notes, rendered, planned.count - rendered.count)
    }

    private func timecode(_ time: TimeInterval) -> String {
        let total = Int(time.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Half a minute of speech on either side. Enough for the vision model to
    /// know what it is looking for, short enough that four of them fit next to
    /// four images.
    private func context(around time: TimeInterval, in transcript: String) -> String {
        transcript
            .components(separatedBy: .newlines)
            .filter { line in
                guard let segment = TranscriptParser.segments(from: line).first else { return false }
                return abs(segment.start - time) <= 30
            }
            .joined(separator: " ")
    }

    /// Every write carries the whole measurement, not just the status: a retry
    /// after a relaunch has nothing else to learn the microphone offset from.
    private func write(
        _ state: MeetingState,
        _ recording: MeetingRecording,
        stages: MeetingStages? = nil,
        failure: MeetingFailure? = nil,
        to folder: MeetingFolder
    ) throws {
        try MeetingStateFile(
            state: state,
            duration: recording.duration,
            microphoneOffset: recording.microphoneOffset,
            stages: stages,
            failure: failure?.stored
        ).encoded().write(to: folder.stateURL, options: .atomic)
    }

    /// Called when something threw: the recording stays, the reason is written
    /// down, and the meeting can be retried from the list. The stages come
    /// along so that a retry can tell what had already been paid for — losing
    /// them on the failure path would leave them useful only where nothing
    /// went wrong.
    func markFailed(
        _ folder: MeetingFolder,
        recording: MeetingRecording,
        stages: MeetingStages? = nil,
        reason: MeetingFailure
    ) {
        try? write(.failed, recording, stages: stages ?? currentStages, failure: reason, to: folder)
    }
}
