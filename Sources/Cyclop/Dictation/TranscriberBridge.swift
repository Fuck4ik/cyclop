import AppKit
import CyclopDictation

/// Runs the Python transcription worker and turns its stdout into results.
///
/// Built on the same shape as `NowPlayingFeed`: a child process, one JSON
/// object per line, a restart on unexpected death, and stdin closed on stop so
/// the worker cannot outlive the app.
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

    var onResult: ((Result<String, Error>) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var failures = 0
    private var stopped = false
    private var generation = 0

    var isRunning: Bool { process?.isRunning == true }

    /// The interpreter that already has mlx-whisper in it. Overridable through
    /// defaults so a different runtime can be pointed at without a rebuild.
    private var pythonPath: String {
        if let custom = UserDefaults.standard.string(forKey: "dictation.python"), !custom.isEmpty {
            return custom
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WhisperDictation/runtime/.venv/bin/python")
            .path
    }

    private var workerPath: String? {
        Bundle.main.path(forResource: "cyclop_worker", ofType: "py", inDirectory: "worker")
            ?? Bundle.main.path(forResource: "cyclop_worker", ofType: "py")
    }

    func start() {
        stopped = false
        failures = 0
        buffer.removeAll()
        generation += 1
        launch()
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
        task.arguments = ["-u", workerPath]

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
        // Schedule a retry, but only if this generation is still current. If the caller invoked
        // stop() and start() while we were waiting, generation will have advanced and we bail out.
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

    func unload() {
        guard isRunning else { return }
        send(.unload)
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
        guard let text = response.text else { return }
        onResult?(.success(text))
    }
}
