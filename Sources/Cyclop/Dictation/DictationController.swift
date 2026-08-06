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
        case recording
        case transcribing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var query = ""
    @Published private(set) var lastText: String?

    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let bridge = TranscriberBridge()
    private let store = DictationHistoryStore()
    private var pendingAudio: URL?
    private var startedAt: Date?

    var history: [DictationRecord] { store.filtered(query) }
    /// Total record count, unaffected by the search filter — the same reason
    /// `SnippetsPane`'s header counter reads `items.count` rather than the
    /// filtered list: a number that shrinks while someone types a query would
    /// read as records disappearing, not as a search narrowing.
    var count: Int { store.items.count }
    var isBusy: Bool { state == .recording || state == .transcribing }

    private static let model = "mlx-community/whisper-large-v3-turbo"

    func start() {
        // The history file already holds whatever the previous app recognised;
        // the tab must open onto that, not onto an empty list.
        store.reload()
        bridge.onResult = { [weak self] result in self?.handle(result) }

        // A device change mid-recording ends the take inside AudioRecorder
        // itself, on whatever it managed to capture before the switch — that
        // is not silence, it is a cut-off sentence, so it still goes to the
        // transcriber instead of being thrown away. Weak self: the recorder
        // is owned by this controller, so a strong capture here would be a
        // retain cycle (controller -> recorder -> closure -> controller).
        recorder.onInterrupted = { [weak self] url in self?.handleInterrupted(url) }

        hotkey.onPress = { [weak self] in self?.beginRecording() }
        // The hold duration is not needed here: HoldGesture already swallows
        // a tap shorter than its minimum, and AudioRecorder separately drops
        // a take too short to contain speech (see its own minimum below the
        // sample-rate check) — nothing downstream of onRelease firing at all
        // cares how long the key was down.
        hotkey.onRelease = { [weak self] _ in self?.endRecording() }

        // Never prompts on its own: without the permission the tab explains
        // itself and offers the button, exactly like the calendar does.
        state = HotkeyMonitor.hasAccessibilityPermission ? .idle : .needsPermission
        if state == .idle { _ = hotkey.start() }
    }

    func stop() {
        hotkey.stop()
        bridge.stop()
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
        if HotkeyMonitor.hasAccessibilityPermission {
            state = .idle
            _ = hotkey.start()
        } else {
            state = .needsPermission
        }
    }

    // MARK: - Pipeline

    private func beginRecording() {
        guard !isBusy else { return }
        do {
            try recorder.start()
            state = .recording
            startedAt = Date()
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
        state = .transcribing
        bridge.transcribe(path: url)
    }

    private func handleInterrupted(_ url: URL?) {
        guard state == .recording else { return }
        finishRecording(url)
    }

    private func handle(_ result: Result<String, Error>) {
        switch result {
        case .success(let text):
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
                model: Self.model
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
        NSSound(contentsOf: url, byReference: true)?.play()
    }

    func reload() {
        store.reload()
        objectWillChange.send()
    }
}
