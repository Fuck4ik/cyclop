import AppKit
import CyclopDictation

/// Runs the Python transcription worker and turns its stdout into results.
///
/// Built on the same shape as `NowPlayingFeed`: a child process, one JSON
/// object per line, a restart on unexpected death, and stdin closed on stop so
/// the worker cannot outlive the app.
///
/// Deliberately has no `start()`: the worker is launched lazily, from
/// `transcribe(path:)`, the first time there is actually something to
/// transcribe — measured to sit around 171 MB once mlx-whisper's own
/// idle-watch thread lets go of the model after 629s of silence, so there is
/// nothing an eager `start()` would still be buying by keeping it resident
/// from launch. Also has no `unload()`: that idle-watch thread inside the
/// worker already unloads on its own after `IDLE_SECONDS` — a
/// Swift-initiated unload would only be racing a decision the worker already
/// makes for itself.
@MainActor
final class TranscriberBridge {
    enum BridgeError: LocalizedError {
        case noPython
        case worker(String)

        var errorDescription: String? {
            switch self {
            case .noPython:
                return localized("Transcription runtime not found")
            case .worker(let message):
                return message
            }
        }
    }

    /// A completed transcription and the model that produced it — reported by
    /// the worker itself (`WorkerResponse.model`) rather than assumed by the
    /// caller, since the standalone WhisperDictation app can switch models
    /// from its own menu underneath this one.
    struct Transcription {
        let text: String
        let model: String?
    }

    var onResult: ((Result<Transcription, Error>) -> Void)?
    /// A model being fetched, reported often enough to draw a moving bar.
    var onDownload: ((DownloadProgress) -> Void)?
    /// The weights are on disk. Follows every `ensureModel()` and every
    /// `download(id:)`, whether or not anything had to be downloaded.
    var onModelReady: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var failures = 0
    private var stopped = false
    private var generation = 0

    var isRunning: Bool { process?.isRunning == true }

    /// The interpreter that already has mlx-whisper in it: the one inside the
    /// bundle, built by `Scripts/runtime.sh`. Overridable through defaults,
    /// which is what a `swift run` build without a bundle around it needs —
    /// `defaults write com.cyclop.app dictation.python <path>`.
    private var pythonPath: String {
        if let custom = UserDefaults.standard.string(forKey: "dictation.python"), !custom.isEmpty {
            return custom
        }
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/runtime/bin/python3.11")
            .path
    }

    /// Python must not write anything into the bundle. It caches bytecode next
    /// to whatever it imports, and the worker imports from inside
    /// `Cyclop.app`: a single `__pycache__` there breaks the code signature —
    /// `spctl` starts answering "a sealed resource is missing or invalid", and
    /// on someone else's Mac that is the difference between an app that opens
    /// and one Gatekeeper turns away. `-B` covers this process, the variable
    /// covers whatever it spawns (hf_xet and numba both fork helpers). The
    /// speed lost is nothing: `bundle.sh` compiles the modules before signing,
    /// so the caches are already there, part of the signature, and read-only.
    private static let pythonEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return environment
    }()

    private var workerPath: String? {
        Bundle.main.path(forResource: "cyclop_worker", ofType: "py", inDirectory: "worker")
            ?? Bundle.main.path(forResource: "cyclop_worker", ofType: "py")
    }

    func stop() {
        stopped = true
        input = nil
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard !stopped else { return }
        guard let workerPath, FileManager.default.isExecutableFile(atPath: pythonPath) else {
            onResult?(.failure(BridgeError.noPython))
            return
        }

        buffer.removeAll()
        let currentGeneration = generation

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = ["-B", "-u", workerPath]
        task.environment = Self.pythonEnvironment

        let output = Pipe()
        let errors = Pipe()
        let commands = Pipe()
        task.standardOutput = output
        task.standardError = errors
        task.standardInput = commands

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            // Empty data means EOF — the worker closed its end of the pipe.
            // `readabilityHandler` is a level-triggered callback: GCD invokes
            // it again the instant it returns if the underlying fd is still
            // marked readable, and a closed pipe reads as "readable, zero
            // bytes" forever. Not nilling the handler here left two of these
            // spinning per dead process — see `NowPlayingFeed`'s copy of this
            // same shape for the fix's origin, and the harness in
            // `Scripts/measure-readability-cpu.swift` for the measurement.
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.consume(chunk, generation: currentGeneration) }
        }

        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let message = String(decoding: chunk, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                NSLog("Cyclop: worker stderr: %@", message)
            }
        }

        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination(generation: currentGeneration) }
        }

        do {
            try task.run()
        } catch {
            NSLog("Cyclop: transcription worker failed to launch: \(error.localizedDescription)")
            onResult?(.failure(error))
            return
        }
        process = task
        input = commands.fileHandleForWriting
    }

    private func handleTermination(generation: Int) {
        guard !stopped, generation == self.generation else { return }
        process = nil
        input = nil
        failures += 1
        guard failures < 3 else {
            onResult?(.failure(BridgeError.worker(localized("Transcription worker keeps failing"))))
            return
        }
        // Schedule a retry, guarded by `!stopped` inside launch() itself: a
        // stop() in the meantime must not resurrect a worker that was
        // deliberately shut down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard self?.generation == generation else { return }
            self?.launch()
        }
    }

    // MARK: - Commands

    func transcribe(path: URL) {
        if !isRunning { launch() }
        send(.transcribe(path: path.path))
    }

    /// Start fetching the selected model if it is missing. Safe to send when
    /// it is already there: the worker answers `ready` straight away.
    func ensureModel() {
        if !isRunning { launch() }
        send(.ensureModel)
    }

    func download(id: String) {
        if !isRunning { launch() }
        send(.download(id: id))
    }

    /// The catalog, from a process that answers and exits.
    ///
    /// Deliberately not a command to the long-running worker: the panel asks
    /// this every time the dictation tab is opened, and routing it through the
    /// worker would leave that process — and eventually a resident model —
    /// alive from the first look at the tab rather than from the first
    /// dictation. This one imports no mlx and lives about a third of a second.
    func loadModels(completion: @escaping ([DictationModel]) -> Void) {
        guard let workerPath, FileManager.default.isExecutableFile(atPath: pythonPath) else {
            completion([])
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = ["-B", workerPath, "--models"]
        task.environment = Self.pythonEnvironment
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        // Read before waiting: a catalog is small, but blocking on exit with a
        // pipe nobody is draining is how that stops being true one day.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try task.run()
            } catch {
                NSLog("Cyclop: model catalog failed to launch: \(error.localizedDescription)")
                DispatchQueue.main.async { completion([]) }
                return
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let models = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .compactMap { WorkerResponse.decode(line: String($0))?.models }
                .first ?? []
            DispatchQueue.main.async { completion(models) }
        }
    }

    private func send(_ request: WorkerRequest) {
        guard let input, let line = try? request.encodedLine(),
              let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            NSLog("Cyclop: worker write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Output

    private func consume(_ chunk: Data, generation: Int) {
        guard generation == self.generation else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = buffer[buffer.index(after: newline)...]
            guard !line.isEmpty else { continue }
            handle(line: String(decoding: line, as: UTF8.self))
        }
        if buffer.count > 4_000_000 { buffer.removeAll() }
    }

    private func handle(line: String) {
        guard let response = WorkerResponse.decode(line: line) else { return }
        failures = 0
        if let message = response.error {
            onResult?(.failure(BridgeError.worker(message)))
            return
        }
        if let freed = response.freedMB, response.unloaded == true {
            NSLog("Cyclop: transcription model unloaded, freed %.0f MB", freed)
            return
        }
        if let fraction = response.progress {
            onDownload?(DownloadProgress(
                fraction: fraction,
                downloadedMB: response.downloadedMB ?? 0,
                totalMB: response.totalMB ?? 0
            ))
            return
        }
        if response.ready == true {
            onModelReady?()
            return
        }
        guard let text = response.text else { return }
        onResult?(.success(Transcription(text: text, model: response.model)))
    }
}
