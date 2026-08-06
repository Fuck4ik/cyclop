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
        hotkey.onRelease = { [weak self] held in self?.endRecording(held: held) }

        // Never prompts on its own: without the permission the tab explains
        // itself and offers the button, exactly like the calendar does.
        state = HotkeyMonitor.hasAccessibilityPermission ? .idle : .needsPermission
        if state == .idle { _ = hotkey.start() }
    }

    func stop() {
        hotkey.stop()
        bridge.stop()
    }

    /// The user pressed the button on the explaining screen.
    func enable() {
        HotkeyMonitor.requestAccessibilityPermission()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // The permission lands asynchronously and macOS does not notify us, so
        // the state is re-checked when the tab is next shown.
        refreshPermission()
    }

    func refreshPermission() {
        guard state == .needsPermission || state == .idle else { return }
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

    private func endRecording(held: TimeInterval) {
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
            guard !text.isEmpty else { return }
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
        }
        pendingAudio = nil
        startedAt = nil
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
