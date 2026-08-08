import AppKit
import AVFoundation
import CyclopDictation

/// Dictation, end to end: hold the key, speak, let go, get text.
///
/// Everything the panel needs to show is here as published state, so the pane
/// and the notch indicator both read the same source rather than guessing.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case idle
        /// Accessibility has not been granted, so the hotkey cannot be seen.
        case needsPermission
        /// Permissions are in place, but there are no weights to recognise
        /// with — the tab shows the catalog instead of the history.
        case needsModel
        case recording
        case transcribing
        /// Weights on their way. Reached either from the catalog button or
        /// from dictating on a machine that has none yet.
        case downloading(DownloadProgress)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var models: [DictationModel] = []
    /// The catalog opened by hand from the history, as opposed to the one
    /// `.needsModel` puts there because nothing can be recognised yet. Kept
    /// apart from `state` because it is not a state of dictation at all — the
    /// hotkey works exactly the same while this is showing.
    @Published private(set) var showsCatalog = false
    /// Which row in the catalog is the one being fetched, so the bar can be
    /// drawn under it rather than on a screen of its own.
    @Published private(set) var downloadingID: String?
    @Published var query = ""
    @Published private(set) var lastText: String?

    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let bridge = TranscriberBridge()
    private let store = DictationHistoryStore()
    private let player = RecordingPlayer()
    private var pendingAudio: URL?
    private var startedAt: Date?
    private var transcribeTimeoutWork: DispatchWorkItem?
    /// Set while weights are actually being fetched, so a take that ends
    /// mid-download shows the bar rather than claiming to be transcribing.
    private var downloadProgress: DownloadProgress?
    private var isLoadingModels = false

    /// Measures silence from the worker, not the length of an operation: a
    /// download re-arms it on every progress line (see `handleDownload`), so
    /// three gigabytes over a slow connection is fine and three minutes of
    /// nothing at all is not. Nothing else ends `.transcribing`: `setOpen`
    /// and `refreshPermission` both defer to `isBusy`, and the failure
    /// screen with its "Retry" button only ever renders for `.failed`. A
    /// worker that dies without sending a line, or one still pulling down
    /// weights on a slow connection, would otherwise strand the panel open
    /// over the menu bar until the app is quit.
    private static let transcribeTimeout: TimeInterval = 180

    var history: [DictationRecord] { store.filtered(query) }
    /// Total record count, unaffected by the search filter — the same reason
    /// `SnippetsPane`'s header counter reads `items.count` rather than the
    /// filtered list: a number that shrinks while someone types a query would
    /// read as records disappearing, not as a search narrowing.
    var count: Int { store.items.count }
    var isBusy: Bool {
        switch state {
        case .recording, .transcribing, .downloading: return true
        default: return false
        }
    }

    /// A take already recorded and waiting its turn — the download screen says
    /// so, because the whole point of recording during a download is that the
    /// first phrase on a new machine is not thrown away.
    var isWaitingToTranscribe: Bool { pendingAudio != nil }

    /// Whether the model dictation would actually use is on disk. Not "any
    /// model is": with the selected one missing and another one cached, going
    /// straight to dictation would quietly download the missing one instead
    /// of offering the one already here. An empty catalog means the question
    /// has not been answered yet — assume yes, so the tab opens onto the
    /// history rather than flashing the catalog on every launch.
    private var hasModel: Bool { models.isEmpty || models.contains { $0.selected && $0.ready } }

    /// What the microphone is hearing right now, 0…1, for the waveform under
    /// the notch. Read when a frame is drawn rather than published: the view
    /// redraws on its own display-linked timer, and pushing a value per audio
    /// buffer would only queue work between frames.
    var micLevel: Float { recorder.level.current }

    /// Used only when the worker's response carries no model — an older
    /// worker build, or a malformed line that still somehow decoded a `text`.
    /// The normal case reports the model that actually ran, straight from
    /// `TranscriberBridge.Transcription.model`; this is a fallback, not the
    /// source of truth, so it does not need to track the standalone
    /// WhisperDictation app's own model switcher.
    private static let fallbackModel = "mlx-community/whisper-large-v3-turbo"

    func start() {
        // The history file already holds whatever the previous app recognised;
        // the tab must open onto that, not onto an empty list.
        store.reload()
        bridge.onResult = { [weak self] result in self?.handle(result) }
        bridge.onDownload = { [weak self] progress in self?.handleDownload(progress) }
        bridge.onModelReady = { [weak self] in self?.handleModelReady() }
        bridge.onModelDeleted = { [weak self] freed in self?.handleModelDeleted(freed) }
        // `playing` is not @Published — it lives in the player — so the panel
        // has to be told, including when a recording simply reaches its end.
        player.onChange = { [weak self] in self?.objectWillChange.send() }
        // The catalog is deliberately not read here: launching the app should
        // not start a process to answer a question nobody asked yet. It is
        // read when the tab is first shown (`refreshPermission`), and a hotkey
        // pressed before that still works — `beginRecording` asks the worker
        // to fetch the weights itself.

        // A device change mid-recording ends the take inside AudioRecorder
        // itself, on whatever it managed to capture before the switch — that
        // is not silence, it is a cut-off sentence, so it still goes to the
        // transcriber instead of being thrown away. Weak self: the recorder
        // is owned by this controller, so a strong capture here would be a
        // retain cycle (controller -> recorder -> closure -> controller).
        recorder.onInterrupted = { [weak self] url in self?.handleInterrupted(url) }

        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onDoubleTap = { [weak self] in self?.insertShortcut() }
        // The hold duration is not needed here: HoldGesture already swallows
        // a tap shorter than its minimum, and AudioRecorder separately drops
        // a take too short to contain speech (see its own minimum below the
        // sample-rate check) — nothing downstream of onRelease firing at all
        // cares how long the key was down.
        hotkey.onRelease = { [weak self] _ in self?.endRecording() }

        // Never prompts on its own: without the permission the tab explains
        // itself and offers the button, exactly like the calendar does.
        state = isAuthorized ? .idle : .needsPermission
        if state == .idle { _ = hotkey.start() }
    }

    func stop() {
        hotkey.stop()
        bridge.stop()
        transcribeTimeoutWork?.cancel()
        transcribeTimeoutWork = nil
        // A download dies with the worker it was running in; leaving this set
        // would make the next take think weights are still on their way.
        downloadProgress = nil
        // Nothing is left to press stop with once this controller is gone.
        player.stop()
        // NotchController.rebuild() calls this on a screen configuration
        // change and then drops the whole NotchViewModel, controller
        // included — with no reload() left to receive a transcript, there is
        // nothing useful to do with a take in progress but end it. Without
        // this, AudioRecorder's engine keeps running after its last strong
        // reference is gone: the tap is never removed, so it keeps writing
        // samples into an accumulator nobody will ever drain, and the
        // microphone stays open until the app is relaunched.
        //
        // recorder.stop() has already written a wav by this point if more
        // than a quarter second was captured — same as a normal release —
        // but there is no bridge left running to transcribe it and no
        // history entry to keep it for, so it is discarded exactly like a
        // failed or empty transcription rather than left to rot in the
        // recordings folder.
        if let leftover = recorder.stop() { discard(leftover) }
    }

    /// Both permissions dictation actually needs: Accessibility to see the
    /// key anywhere in the system, the microphone to hear anything once it
    /// does. Checked together everywhere `state` is derived from permission,
    /// so a machine with only one of the two granted — Universal Access
    /// handed out by hand, or left over from an old build, with the
    /// microphone never asked — still lands on the explaining screen instead
    /// of quietly recording nothing or popping the system's own microphone
    /// dialog cold in the middle of a take.
    private var isAuthorized: Bool {
        HotkeyMonitor.hasAccessibilityPermission && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// The user pressed the button on the explaining screen.
    func enable() {
        HotkeyMonitor.requestAccessibilityPermission()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // The permission lands asynchronously and macOS does not notify us, so
        // the state is re-checked when the tab is next shown.
        refreshPermission()
    }

    /// Recomputes from the real permission every time, the same way
    /// `CalendarStore.refreshAccess()` always recomputes on every visit rather
    /// than trusting whatever was last on screen — including a `.failed` left
    /// over from a transcription that never got another look. Skipped while
    /// actually recording or transcribing: those are not stale state to
    /// replace, they are happening right now, and this runs on every visit to
    /// the tab, which a global hotkey can make happen mid-take.
    func refreshPermission() {
        guard !isBusy else { return }
        if isAuthorized {
            state = hasModel ? .idle : .needsModel
            _ = hotkey.start()
            // The catalog can change without this app doing anything — a
            // model deleted from the Hugging Face cache by hand, or fetched
            // by something else entirely — so it is re-read on every visit
            // rather than trusted from startup, the same way the permission
            // above is.
            refreshModels()
        } else {
            // Covers a permission that was granted and has since been
            // revoked, not just one never granted: without this, a hotkey
            // already armed from an earlier, fully-authorized visit would
            // keep firing after the mic (or Accessibility) was pulled back,
            // recording into a permission that no longer holds.
            //
            // This branch is also reachable reentrantly, from inside
            // `beginRecording()`'s own `state = .recording` assignment —
            // `NotchController` forces `viewModel.tab = .dictation` on
            // every entry into `.recording`, and that tab's `didSet` calls
            // back into `refreshPermission()` before `state`'s new value
            // has actually landed in storage (`@Published` notifies
            // subscribers from `willSet`, so `isBusy` above still reads the
            // *previous* state — `.idle` — for the entire reentrant call).
            // That used to make `hotkey.stop()` reachable here at exactly
            // the moment recording is beginning, only to find nothing left
            // to answer the key release with, wedging the panel in
            // `.recording` for good. It no longer is: `beginRecording()`
            // now checks `isAuthorized` itself, synchronously, before ever
            // assigning `.recording` — the same query this branch runs, on
            // the same thread, nanoseconds apart, so it cannot have flipped
            // to false in between. By the time this reentrant call can run
            // at all, authorization was just confirmed true, which routes
            // it into the *other* branch instead.
            hotkey.stop()
            state = .needsPermission
        }
    }

    // MARK: - Double-tap shortcut

    private static let shortcutKey = "dictation.doubleTapText"

    /// What two quick taps of the hotkey type. Some phrases are asked for so
    /// often — "continue" into a coding agent, most of all — that dictating
    /// them costs more than they are worth.
    var shortcutText: String {
        get { UserDefaults.standard.string(forKey: Self.shortcutKey) ?? localized("Continue") }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.shortcutKey)
            objectWillChange.send()
        }
    }

    private func insertShortcut() {
        // Never over a take: the hotkey is the same key, and a tap that lands
        // while something is being recorded or recognised belongs to that,
        // not here.
        guard !isBusy else { return }
        let text = shortcutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        TextInserter.insert(text)
    }

    // MARK: - Models

    /// Re-reads which models are on disk. Cheap: a process that prints the
    /// catalog and exits, with no mlx in it (see `TranscriberBridge.loadModels`).
    func refreshModels() {
        // One at a time. `refreshPermission()` runs on every visit to the tab
        // *and* reentrantly from inside `beginRecording()`'s own state
        // assignment (see the long comment there), so without this a single
        // key press would spawn a second catalog process nobody is waiting
        // for — and its answer, arriving later, would be the one that stuck.
        guard !isLoadingModels else { return }
        isLoadingModels = true
        bridge.loadModels { [weak self] models in
            guard let self else { return }
            isLoadingModels = false
            self.models = models
            guard !isBusy else { return }
            // Only ever moves between these two: a `.failed` on screen is
            // something the user has not read yet, and `.needsPermission`
            // outranks having no model — there is nothing to dictate with
            // either way, and the permission is the first thing to fix.
            if !hasModel, state == .idle { state = .needsModel }
            if hasModel, state == .needsModel { state = .idle }
        }
    }

    func toggleCatalog() {
        showsCatalog.toggle()
        if showsCatalog { refreshModels() }
    }

    /// The user picked a model in the catalog.
    func download(_ id: String) {
        let blank = DownloadProgress(fraction: 0, downloadedMB: 0, totalMB: 0)
        downloadProgress = blank
        downloadingID = id
        state = .downloading(blank)
        armTranscribeTimeout()
        bridge.download(id: id)
    }

    /// Throw a model's weights away. The one in use can go too — the tab then
    /// asks which model to use, same as on a machine that never had one.
    func delete(_ id: String) {
        guard downloadingID != id else { return }
        bridge.delete(id: id)
    }

    private func handleModelDeleted(_ freedMB: Double) {
        NSLog("Cyclop: model deleted, freed %.0f MB", freedMB)
        refreshModels()
    }

    private func handleDownload(_ progress: DownloadProgress) {
        downloadProgress = progress
        // A download nobody started from the catalog: the hotkey was held on a
        // machine with no weights, and `ensureModel()` is fetching whichever
        // model is selected. The bar still belongs under a row.
        if downloadingID == nil {
            downloadingID = models.first { $0.selected }?.id
        }
        // Every line is proof the download is alive; the watchdog measures
        // silence, not total time, or fetching three gigabytes on a slow
        // connection would look like a hang.
        armTranscribeTimeout()
        // Recording outranks the bar: swapping the state here would strand
        // `endRecording()`, which only ends a take while `state == .recording`,
        // and the key release would never finish the recording at all.
        guard state != .recording else { return }
        state = .downloading(progress)
    }

    private func handleModelReady() {
        downloadProgress = nil
        downloadingID = nil
        // The catalog has done its job — whichever model was picked is now the
        // one dictation uses. Leaving it up would mean answering "which model"
        // twice for one decision.
        showsCatalog = false
        refreshModels()
        guard case .downloading = state else { return }
        // A take that was waiting on these weights is next in the worker's
        // queue; anything else just goes back to the history.
        state = pendingAudio == nil ? .idle : .transcribing
        if pendingAudio == nil {
            transcribeTimeoutWork?.cancel()
            transcribeTimeoutWork = nil
        }
    }

    // MARK: - Pipeline

    private func beginRecording() {
        guard !isBusy else { return }
        // Re-checked here rather than trusted from whenever the hotkey tap
        // was last armed: nothing un-arms it the instant the microphone (or
        // Accessibility) is pulled, so a keypress can still land here after
        // that happens. Catching it before `state` becomes `.recording`
        // matters beyond just the obvious "do not record with no
        // permission" — assigning `.recording` here is exactly what makes
        // `refreshPermission()`'s own `hotkey.stop()` reachable reentrantly
        // (see the comment there), so resolving the authorization question
        // *before* that assignment, not after, is what keeps that reentrant
        // call from ever seeing "unauthorized" at the one moment it would
        // wedge the panel instead of just closing the tap a beat sooner.
        guard isAuthorized else {
            hotkey.stop()
            state = .needsPermission
            return
        }
        do {
            try recorder.start()
            state = .recording
            startedAt = Date()
            // Fetch the weights now, not when the key comes back up: on a
            // machine that has none, the download runs while the sentence is
            // still being spoken instead of after it. Costs nothing when they
            // are already here — the worker answers `ready` immediately — and
            // has the interpreter warm by the time there is audio to hand it.
            bridge.ensureModel()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        finishRecording(recorder.stop())
    }

    /// Shares the "send whatever was captured to the transcriber" step with
    /// the interruption path: a device switch ends the take the same way a
    /// key release does, and both hand back an optional URL.
    private func finishRecording(_ url: URL?) {
        guard let url else {
            state = .idle
            return
        }
        pendingAudio = url
        // Weights still arriving: the worker will not get to this take until
        // they do, so say so instead of showing "transcribing" for the length
        // of a download.
        state = downloadProgress.map { State.downloading($0) } ?? .transcribing
        armTranscribeTimeout()
        bridge.transcribe(path: url)
    }

    private func handleInterrupted(_ url: URL?) {
        guard state == .recording else { return }
        finishRecording(url)
    }

    /// Watchdog for `.transcribing`: see the comment on `transcribeTimeout`
    /// for why nothing else ends that state on its own.
    private func armTranscribeTimeout() {
        transcribeTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.handleTranscribeTimeout() }
        transcribeTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.transcribeTimeout, execute: work)
    }

    private func handleTranscribeTimeout() {
        // Already resolved by the time this fires — a normal response or
        // stop() already moved the state on and cancelled this work item;
        // the guard is only a defence against the cancellation racing the
        // dispatch queue rather than something expected to trip in practice.
        switch state {
        case .transcribing:
            NSLog("Cyclop: transcription timed out after %.0fs", Self.transcribeTimeout)
            state = .failed(localized("Transcription timed out"))
        case .downloading:
            // Three minutes without a single progress line, not three minutes
            // of downloading: `handleDownload` re-arms this on every one.
            NSLog("Cyclop: model download stalled for %.0fs", Self.transcribeTimeout)
            // The worker is stuck inside the download and reads no commands
            // until it returns — which, with the sockets open and nothing
            // coming through them, can be never. Ending it is what frees
            // dictation as well; the partial weights stay in the cache and a
            // retry picks them up from there.
            bridge.restart()
            state = .failed(localized("Model download stopped"))
            downloadProgress = nil
            downloadingID = nil
        default:
            return
        }
        discardPendingAudio()
        pendingAudio = nil
        startedAt = nil
    }

    private func handle(_ result: Result<TranscriberBridge.Transcription, Error>) {
        // A failure can also land while the bar is up: a download that cannot
        // reach the network fails as a worker error, and only this path has
        // anything to say about it. Without it the panel would sit on a
        // frozen progress bar until the watchdog fired three minutes later.
        if case .failure(let error) = result, case .downloading = state {
            transcribeTimeoutWork?.cancel()
            transcribeTimeoutWork = nil
            downloadProgress = nil
            state = .failed(error.localizedDescription)
            discardPendingAudio()
            pendingAudio = nil
            startedAt = nil
            return
        }
        // A response for a request this controller already gave up on: the
        // watchdog above already moved the state to `.failed` and discarded
        // the pending audio, so there is nothing left here to attach a late
        // result to. Without this guard, a transcript that finally arrives
        // after the timeout would silently flip `.failed` back to `.idle`
        // and try to save a history record with no audio file behind it —
        // `pendingAudio` was already cleared by the timeout.
        guard state == .transcribing else { return }
        transcribeTimeoutWork?.cancel()
        transcribeTimeoutWork = nil
        switch result {
        case .success(let transcription):
            let text = transcription.text
            let took = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            state = .idle
            guard !text.isEmpty else {
                // Silence, or a stray brush of the key that still cleared
                // AudioRecorder's own minimum: nothing goes into history, so
                // nothing keeps this wav alive — clean it up now, or it sits
                // in the recordings folder forever.
                discardPendingAudio()
                return
            }
            lastText = text
            TextInserter.insert(text)
            store.append(DictationRecord(
                text: text,
                audio: pendingAudio?.lastPathComponent,
                took: took,
                model: transcription.model ?? Self.fallbackModel
            ))
            objectWillChange.send()
        case .failure(let error):
            state = .failed(error.localizedDescription)
            // Same reasoning as the empty-text case: a failed transcription
            // leaves no history record pointing at the file.
            discardPendingAudio()
        }
        pendingAudio = nil
        startedAt = nil
    }

    /// Deletes the wav for a take that will never be attached to a history
    /// record. Records that do make it into history are never touched here —
    /// their audio is kept so `play(_:)` can replay them.
    private func discardPendingAudio() {
        guard let pendingAudio else { return }
        discard(pendingAudio)
    }

    private func discard(_ audio: URL) {
        try? FileManager.default.removeItem(at: audio)
    }

    // MARK: - History actions

    func copy(_ record: DictationRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(record.text, forType: .string)
    }

    /// Starts a recording, or stops it if it is already playing. One at a
    /// time: the button offers to stop what it started, and clicking twice
    /// used to leave the same voice playing over itself.
    func play(_ record: DictationRecord) {
        guard let audio = record.audio else { return }
        // Recordings made by Cyclop live in its own folder; older ones came
        // from the standalone app and are still where it left them.
        let candidates = [
            AudioRecorder.folder.appendingPathComponent(audio),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/WhisperDictation/recordings")
                .appendingPathComponent(audio),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        player.toggle(url: url, id: audio)
    }

    /// Which recording is playing, for the button that has to say "stop".
    var playingAudio: String? { player.playing }

    func reload() {
        store.reload()
        objectWillChange.send()
    }
}
