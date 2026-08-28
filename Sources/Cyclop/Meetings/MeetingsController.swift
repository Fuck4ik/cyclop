import AppKit
import CyclopMeetings
import Foundation

/// What the meetings tab shows and what the notch indicator reads.
@MainActor
final class MeetingsController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case processing(MeetingProgress)
    }

    struct Meeting: Identifiable, Equatable {
        let id: URL
        let folder: MeetingFolder
        let state: MeetingState
        let duration: TimeInterval
        /// Carried out of `.state.json` so a retry weaves the two lanes with
        /// the same offset the recorder measured — see `MeetingRecording`.
        let microphoneOffset: TimeInterval
        let failure: MeetingFailure?
    }

    static let rootFolderKey = "cyclop.meetings.root"
    static let ownerNameKey = "cyclop.meetings.ownerName"

    static var rootFolder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: rootFolderKey), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/Cyclop", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: rootFolderKey) }
    }

    static var ownerName: String {
        get { UserDefaults.standard.string(forKey: ownerNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: ownerNameKey) }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var meetings: [Meeting] = []
    /// The offer card under the notch. Cleared by an answer or by time.
    @Published private(set) var offer = false
    /// The last thing that went wrong, already in the reader's language.
    ///
    /// A recording that never starts — a denied screen-recording prompt, most
    /// of the time — used to leave the button quietly back at "Записать
    /// встречу" with the reason in the log, where nobody looks. Cleared when
    /// the next attempt begins: an old message says nothing about a new try.
    @Published private(set) var failureMessage: String?

    private let recorder = MeetingRecorder()
    private let processor = MeetingProcessor()
    private var detector: CallDetector?
    private var current: MeetingFolder?
    private var offerTimer: Timer?
    private var terminationObserver: NSObjectProtocol?

    // `state` is one published enum, but two independent things can be true
    // at once: a recording running now, and an older meeting still uploading
    // in the background. Tracking both apart and folding them together in
    // recompute() is what keeps a background progress tick from overwriting
    // a live .recording (or the reverse): assigning `state` directly from
    // both places meant whichever wrote last won, so a retry finishing in the
    // background could drop a running recording's timer off the panel.
    private var recordingSince: Date?
    private var processingFolders: Set<URL> = []
    private var processingStep: MeetingProgress = .preparing

    var isRecording: Bool { if case .recording = state { return true }; return false }

    func start() {
        refresh()
        observeCaptureFailures()
        observeDetector()
        observeTermination()
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func acceptOffer() {
        dismissOffer()
        startRecording()
    }

    func dismissOffer() {
        offerTimer?.invalidate()
        offerTimer = nil
        offer = false
    }

    private func showOffer() {
        guard !isRecording, !offer else { return }
        offer = true
        // 25 seconds: long enough to notice mid-greeting, short enough not to
        // sit over the screen for the whole call.
        offerTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissOffer() }
        }
    }

    private func startRecording() {
        // MeetingRecorder only flips its own isRecording at the very end of
        // an async setup, so two start() calls landing before that flip both
        // pass its guard. recordingSince is set synchronously below, before
        // any `await` in this function, so on the MainActor that assignment
        // and the guard above it are indivisible: a second call queued
        // behind this one always observes isRecording already true.
        guard !isRecording else { return }
        // acceptOffer() already clears the card before calling this, but a
        // recording can also start by the toggle button or a future hotkey
        // while the offer still sits on screen; either way it must go the
        // moment a recording actually starts, not just on an explicit answer.
        dismissOffer()
        failureMessage = nil
        let since = Date()
        recordingSince = since
        recompute()

        let folder = MeetingFolder(root: Self.rootFolder, startedAt: since)
        // current is claimed here, before the folder even exists on disk, not
        // only once recorder.start() confirms a live stream. The setup below
        // awaits ScreenCaptureKit's handshake, which can take the better
        // part of a second; a quit landing in that window needs current set
        // so finalizeBeforeTermination() can mark the folder failed — or
        // refresh() would later find an empty directory with no state file
        // and, before this fix, show it as an ordinary finished meeting.
        // stopRecording() below additionally requires recorder.isRecording,
        // so a stop pressed during this same window still can't race
        // MeetingRecorder's own async setup; it is simply dropped, same as
        // before this change.
        current = folder
        Task {
            do {
                try FileManager.default.createDirectory(
                    at: folder.url, withIntermediateDirectories: true)
                // Written before the handshake below, not after: refresh()
                // is public, and a call landing during the up-to-a-second
                // ScreenCaptureKit setup would otherwise find a folder with
                // no state file yet and — under the fallback added above —
                // read it as failed, even though it is simply still starting.
                try MeetingStateFile(state: .recording, duration: 0)
                    .encoded().write(to: folder.stateURL, options: .atomic)
                try await recorder.start(into: folder)
                refresh()
            } catch {
                NSLog("Cyclop: meeting recording failed to start (%@)", error.localizedDescription)
                // Said out loud, not only logged: the button would otherwise
                // slide back to "Записать встречу" as though nothing had been
                // asked for, which is exactly what a denied screen-recording
                // prompt looked like.
                failureMessage = "\(localized("Could not start recording")): \(reason(for: error))"
                try? FileManager.default.removeItem(at: folder.url)
                // Roll every optimistic marker back: recorder.start() never
                // succeeded, so nothing may go on claiming a live stream or a
                // recording folder exists.
                current = nil
                recordingSince = nil
                recompute()
            }
        }
    }

    private func stopRecording() {
        // recorder.isRecording, not just current != nil: current is now set
        // the instant startRecording() is called, before recorder.start()
        // has confirmed anything, so without this a stop pressed during that
        // setup window would call recorder.stop() while start() is still in
        // flight on the same actor — two async calls on MeetingRecorder
        // interleaved through its own suspension points, fighting over the
        // same writer and stream fields. Gating on the recorder's own flag
        // keeps stop() from running until start() has actually finished.
        guard let folder = current, recorder.isRecording else { return }
        current = nil
        recordingSince = nil
        beginProcessing(folder)
        recompute()

        Task {
            let recording = await recorder.stop()
            refresh()
            do {
                try await processor.process(
                    folder,
                    recording: recording,
                    ownerName: Self.ownerName,
                    progress: { [weak self] step in
                        Task { @MainActor in self?.reportProgress(step) }
                    }
                )
            } catch {
                NSLog("Cyclop: meeting processing failed (%@)", error.localizedDescription)
                processor.markFailed(
                    folder, recording: recording, reason: Self.failure(for: error))
            }
            endProcessing(folder)
            refresh()
        }
    }

    func retry(_ meeting: Meeting) {
        // The folder is its own re-entrancy key: a second click on the same
        // failed meeting is a no-op instead of two writers racing the same
        // transcript.md, while a retry of a different meeting, or a fresh
        // recording, goes on running alongside it untouched.
        guard !processingFolders.contains(meeting.folder.url) else { return }
        failureMessage = nil
        beginProcessing(meeting.folder)
        recompute()

        Task {
            // A meeting that was interrupted while recording has no duration
            // written down — the stopwatch died with the process that held
            // it. The file still knows how long it is, and without this the
            // header of transcript.md would claim 00:00:00.
            var duration = meeting.duration
            if duration <= 0 {
                duration = (try? await MeetingAudio.duration(of: meeting.folder.videoURL)) ?? 0
            }
            let recording = MeetingRecording(
                duration: duration,
                hasMicrophoneLane: FileManager.default.fileExists(
                    atPath: meeting.folder.microphoneURL.path),
                microphoneOffset: meeting.microphoneOffset
            )
            do {
                try await processor.process(
                    meeting.folder,
                    recording: recording,
                    ownerName: Self.ownerName,
                    progress: { [weak self] step in
                        Task { @MainActor in self?.reportProgress(step) }
                    }
                )
            } catch {
                NSLog("Cyclop: meeting processing failed (%@)", error.localizedDescription)
                processor.markFailed(
                    meeting.folder, recording: recording, reason: Self.failure(for: error))
            }
            endProcessing(meeting.folder)
            refresh()
        }
    }

    func reveal(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([meeting.folder.url])
    }

    func openTranscript(_ meeting: Meeting) {
        NSWorkspace.shared.open(meeting.folder.transcriptURL)
    }

    /// The list is a directory listing: no index to keep in sync, and a folder
    /// moved in by hand shows up on its own.
    func refresh() {
        let root = Self.rootFolder
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        meetings = contents
            // MeetingFolder(existing:) only parses the name — it does not
            // check the filesystem — so a stray file dropped into the root
            // that happens to match "<date> Встреча" would otherwise show up
            // in the list as a meeting.
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { MeetingFolder(existing: $0) }
            .map { folder in
                let file = (try? Data(contentsOf: folder.stateURL))
                    .flatMap { try? MeetingStateFile.decode($0) }
                guard let file else {
                    // No readable state file at all — whatever created this
                    // folder never finished writing one down, whether that
                    // was a clean quit finalizeBeforeTermination() marked
                    // (which does leave one) or something rougher that never
                    // got the chance to (a crash, kill -9, power loss). This
                    // must never read as .ready: there is no evidence a
                    // finished recording or a transcript actually exists.
                    return Meeting(
                        id: folder.url, folder: folder, state: .failed, duration: 0,
                        microphoneOffset: 0, failure: .missingStateFile)
                }
                // "recording" and "processing" are claims by a process that
                // was running when the file was written, not statuses that
                // survive it. Nothing in this app is working on this folder
                // now — no live recording, no task in processingFolders — so
                // the claim is stale: the app was closed or crashed partway.
                // Left as it stands the row would show "Обработка" forever
                // and never offer a retry, which is gated on .failed; the
                // spec asks for exactly the opposite, that an interrupted
                // meeting be offered for finishing on the next launch.
                let live = processingFolders.contains(folder.url) || current?.url == folder.url
                if !live, file.state == .recording || file.state == .processing {
                    return Meeting(
                        id: folder.url, folder: folder, state: .failed,
                        duration: file.duration,
                        microphoneOffset: file.microphoneOffset ?? 0,
                        failure: .interrupted)
                }
                return Meeting(
                    id: folder.url,
                    folder: folder,
                    state: file.state,
                    duration: file.duration,
                    microphoneOffset: file.microphoneOffset ?? 0,
                    failure: file.failure.map(MeetingFailure.init(stored:))
                )
            }
            .sorted { $0.folder.startedAt > $1.folder.startedAt }
    }

    // MARK: - State bookkeeping

    /// Errors on their way into `.state.json`. Processing's own failures carry
    /// a code the pane can put into the reader's language; anything from the
    /// proxy or the file system is already a sentence in no particular
    /// language, and travels as one.
    private static func failure(for error: Error) -> MeetingFailure {
        if let failure = error as? MeetingProcessor.Failure { return failure.reason }
        return .message(error.localizedDescription)
    }

    /// Errors on their way to the screen. Only the recorder's own two have
    /// translations; a system error is shown as the system phrased it.
    private func reason(for error: Error) -> String {
        switch error as? MeetingRecorder.Failure {
        case .permissionDenied: return localized("Screen recording is not allowed")
        case .noDisplay: return localized("No display to record")
        case nil: return error.localizedDescription
        }
    }

    // MARK: - A capture that died on its own

    /// Disk full, the display unplugged, the permission revoked mid-meeting.
    /// The stream stops, the file stops growing, and nothing else in this app
    /// would notice: the timer would keep counting and the button would keep
    /// offering to stop a recording that already ended. Stop for real, keep
    /// what was captured — it goes through the ordinary processing path — and
    /// say why.
    private func observeCaptureFailures() {
        recorder.onCaptureFailure = { [weak self] error in
            guard let self, self.isRecording else { return }
            self.failureMessage = "\(localized("Recording stopped")): \(self.reason(for: error))"
            self.stopRecording()
        }
    }

    private func beginProcessing(_ folder: MeetingFolder) {
        processingFolders.insert(folder.url)
        processingStep = .preparing
    }

    private func endProcessing(_ folder: MeetingFolder) {
        processingFolders.remove(folder.url)
        recompute()
    }

    private func reportProgress(_ step: MeetingProgress) {
        processingStep = step
        recompute()
    }

    /// The single published `state` is rebuilt from the two facts above on
    /// every change rather than assigned piecemeal: a live recording always
    /// wins the display, background processing shows only while nothing is
    /// currently recording, and both empty means idle. Without this, a
    /// progress tick from a meeting still uploading in the background could
    /// land after a fresh recording started and stomp .recording back to
    /// .processing on screen.
    private func recompute() {
        if let since = recordingSince {
            state = .recording(since: since)
        } else if !processingFolders.isEmpty {
            state = .processing(processingStep)
        } else {
            state = .idle
        }
    }

    // MARK: - Call detection

    /// Guarded exactly like observeTermination() below: start() has no
    /// guarantee it is only ever called once — that depends on how the tab
    /// hosting this controller gets wired up, which is not this file's
    /// concern — and without this a second call would overwrite `detector`,
    /// orphaning the old CallDetector's Timer. The instance deallocates, but
    /// the run loop still retains the Timer, which keeps firing every 5
    /// seconds forever into a `self` that no longer exists to invalidate it.
    private func observeDetector() {
        guard detector == nil else { return }
        detector = CallDetector { [weak self] in self?.showOffer() }
        detector?.start()
    }

    // MARK: - Termination

    private func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main puts this closure on the main thread at runtime,
            // but NotificationCenter's callback type isn't MainActor-isolated
            // by declaration. assumeIsolated (rather than a `Task { @MainActor
            // in }` hop) is what keeps finalizeBeforeTermination's write
            // synchronous within this callback — see why that matters there.
            MainActor.assumeIsolated {
                self?.finalizeBeforeTermination()
            }
        }
    }

    /// Best effort only. NSApp calls exit() right after delegates observe
    /// this notification, with no further run-loop turn left for the async
    /// recorder.stop() below to actually land — closing that gap for real
    /// needs applicationShouldTerminate(_:) to return .terminateLater, which
    /// lives on the app delegate and is out of scope for this file. What is
    /// guaranteed is the synchronous write below: it marks the cut-off
    /// meeting failed so a relaunch offers a retry instead of showing
    /// "recording" forever for a process that no longer exists.
    private func finalizeBeforeTermination() {
        guard let folder = current, let since = recordingSince else { return }
        current = nil
        recordingSince = nil
        processor.markFailed(
            folder,
            recording: MeetingRecording(
                duration: Date().timeIntervalSince(since),
                hasMicrophoneLane: false,
                microphoneOffset: 0
            ),
            reason: .closedWhileRecording)
        Task { _ = await recorder.stop() }
    }
}
