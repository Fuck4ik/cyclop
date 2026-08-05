# Диктовка в Cyclop — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** перенести голосовую диктовку из WhisperDictation внутрь Cyclop, добавить вкладку истории расшифровок и сократить расход памяти с 3.3 ГБ до ~50 МБ в покое.

**Architecture:** Swift владеет всем, кроме инференса: хоткей, запись, вставка, индикатор, история. Python остаётся транскрайбером и общается построчным JSON через stdin/stdout — тем же приёмом, каким `NowPlayingFeed` уже управляет perl-хелпером. Новая логика живёт в отдельном библиотечном таргете `CyclopDictation`, поэтому её можно покрыть тестами, не трогая исполняемый таргет.

**Tech Stack:** Swift 6 (языковой режим v5), SwiftUI/AppKit, AVFoundation, XCTest, Python 3.11 + mlx-whisper 0.4.3.

## Global Constraints

- Модель не меняется: `mlx-community/whisper-large-v3-turbo`.
- `initial_prompt`, `temperature = 0.0`, `condition_on_previous_text = false`, авто-определение языка — переносятся из `whisper_dictation.config` без правок.
- Нормализация: пик → −3.0 dBFS, но только если исходный пик выше −50.0 dBFS.
- Хоткей: правый Option, порог удержания 0.25 с.
- Платформа: macOS 15+, Apple Silicon.
- Ключи локализации — английский текст; каждая новая строка добавляется в `Resources/en.lproj` и `Resources/ru.lproj`.
- Комментарии в коде — по-английски, как во всём репозитории.
- Файл истории: `~/Library/Application Support/Cyclop/dictation-history.jsonl` (уже содержит 155 записей архива).

## Структура файлов

```
Sources/CyclopDictation/          новый библиотечный таргет — тестируемая логика
├── DictationRecord.swift         запись истории, кодирование JSONL
├── DictationHistoryStore.swift   чтение, дозапись, ретенция, поиск
├── WorkerProtocol.swift          запросы и ответы воркера
├── AudioNormalizer.swift         пиковая нормализация
└── HoldGesture.swift             состояние push-to-talk

Sources/Cyclop/Dictation/         интеграция с системой
├── TranscriberBridge.swift       запуск Python-воркера
├── AudioRecorder.swift           AVAudioEngine
├── HotkeyMonitor.swift           CGEventTap на правый Option
├── TextInserter.swift            буфер обмена + ⌘V
└── DictationController.swift     склейка всего

Sources/Cyclop/UI/DictationPane.swift    седьмая вкладка
Resources/worker/cyclop_worker.py        Python-воркер
Tests/CyclopDictationTests/              XCTest
```

---

### Task 1: Библиотечный таргет и запись истории

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CyclopDictation/DictationRecord.swift`
- Test: `Tests/CyclopDictationTests/DictationRecordTests.swift`

**Interfaces:**
- Produces: `struct DictationRecord: Codable, Identifiable, Equatable` с полями `at: Date`, `text: String`, `chars: Int`, `audio: String?`, `took: Double`, `model: String`; `init(text:audio:took:model:at:)`; `static func decode(line: String) -> DictationRecord?`; `func encodedLine() throws -> String`.

- [ ] **Step 1: Написать падающий тест**

```swift
import XCTest
@testable import CyclopDictation

final class DictationRecordTests: XCTestCase {
    func testDecodesArchiveLine() {
        let line = #"{"at":"2026-08-05T17:34:04Z","text":"Привет","chars":6,"audio":"dictation-20260805-173404.wav","took":11.05,"model":"mlx-community/whisper-large-v3-turbo"}"#
        let record = DictationRecord.decode(line: line)
        XCTAssertEqual(record?.text, "Привет")
        XCTAssertEqual(record?.chars, 6)
        XCTAssertEqual(record?.audio, "dictation-20260805-173404.wav")
    }

    func testRejectsGarbageLine() {
        XCTAssertNil(DictationRecord.decode(line: "не json"))
        XCTAssertNil(DictationRecord.decode(line: ""))
    }

    func testRoundTripsThroughOneLine() throws {
        let record = DictationRecord(text: "Тест", audio: nil, took: 1.5, model: "m")
        let line = try record.encodedLine()
        XCTAssertFalse(line.contains("\n"), "запись должна занимать ровно одну строку")
        XCTAssertEqual(DictationRecord.decode(line: line)?.text, "Тест")
    }

    func testCharsCountUnicodeNotBytes() {
        let record = DictationRecord(text: "Привет", audio: nil, took: 0, model: "m")
        XCTAssertEqual(record.chars, 6)
    }
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter DictationRecordTests`
Expected: FAIL — таргет `CyclopDictation` не существует.

- [ ] **Step 3: Добавить таргеты в Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cyclop",
    // macOS 15 for Translation.framework, which the translate tab runs on.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Cyclop", targets: ["Cyclop"])
    ],
    targets: [
        // Dictation logic lives apart from the executable so it can be tested:
        // an executable target cannot be imported by a test target.
        .target(
            name: "CyclopDictation",
            path: "Sources/CyclopDictation",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Cyclop",
            dependencies: ["CyclopDictation"],
            path: "Sources/Cyclop",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CyclopDictationTests",
            dependencies: ["CyclopDictation"],
            path: "Tests/CyclopDictationTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 4: Написать модель записи**

```swift
import Foundation

/// One dictation, as it is stored in the history file.
///
/// The file is JSONL — one record per line — so a record must never encode
/// a newline of its own, and a corrupt line must cost only itself.
public struct DictationRecord: Codable, Identifiable, Equatable {
    public let at: Date
    public let text: String
    public let chars: Int
    /// File name inside the recordings folder, when the audio was kept.
    public let audio: String?
    public let took: Double
    public let model: String

    public var id: String { "\(at.timeIntervalSince1970)-\(chars)" }

    public init(text: String, audio: String?, took: Double, model: String, at: Date = Date()) {
        self.at = at
        self.text = text
        // Characters as a person counts them, not UTF-8 bytes: the number is
        // shown in the panel next to Russian text, where the two differ by two.
        self.chars = text.count
        self.audio = audio
        self.took = took
        self.model = model
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    /// Returns nil rather than throwing: one unreadable line is not a reason
    /// to lose the rest of the history.
    public static func decode(line: String) -> DictationRecord? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        return try? decoder.decode(DictationRecord.self, from: data)
    }

    public func encodedLine() throws -> String {
        let data = try Self.encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 5: Прогнать тесты**

Run: `swift test --filter DictationRecordTests`
Expected: PASS, 4 теста.

- [ ] **Step 6: Коммит**

```bash
git add Package.swift Sources/CyclopDictation/DictationRecord.swift Tests/CyclopDictationTests/DictationRecordTests.swift
git commit -m "Запись истории диктовок и таргет под неё"
```

---

### Task 2: Хранилище истории — чтение, дозапись, ретенция, поиск

**Files:**
- Create: `Sources/CyclopDictation/DictationHistoryStore.swift`
- Test: `Tests/CyclopDictationTests/DictationHistoryStoreTests.swift`

**Interfaces:**
- Consumes: `DictationRecord` из Task 1.
- Produces: `final class DictationHistoryStore` с `init(file: URL, limit: Int = 500)`, `var items: [DictationRecord]` (свежие первыми), `func reload()`, `func append(_ record: DictationRecord)`, `func filtered(_ query: String) -> [DictationRecord]`, `static var defaultFile: URL`.

- [ ] **Step 1: Написать падающий тест**

```swift
import XCTest
@testable import CyclopDictation

final class DictationHistoryStoreTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    private func write(_ lines: [String]) {
        try! lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func line(_ text: String, at iso: String) -> String {
        #"{"at":"\#(iso)","text":"\#(text)","chars":\#(text.count),"audio":null,"took":1,"model":"m"}"#
    }

    func testNewestFirst() {
        write([
            line("старое", at: "2026-08-01T10:00:00Z"),
            line("новое", at: "2026-08-05T10:00:00Z"),
        ])
        let store = DictationHistoryStore(file: file)
        store.reload()
        XCTAssertEqual(store.items.map(\.text), ["новое", "старое"])
    }

    func testSkipsCorruptLineAndKeepsRest() {
        write([line("первая", at: "2026-08-01T10:00:00Z"), "{битая", line("вторая", at: "2026-08-02T10:00:00Z")])
        let store = DictationHistoryStore(file: file)
        store.reload()
        XCTAssertEqual(store.items.count, 2)
    }

    func testMissingFileGivesEmptyHistory() {
        let store = DictationHistoryStore(file: file)
        store.reload()
        XCTAssertTrue(store.items.isEmpty)
    }

    func testAppendPersistsAndShowsUpFirst() {
        write([line("старое", at: "2026-08-01T10:00:00Z")])
        let store = DictationHistoryStore(file: file)
        store.reload()
        store.append(DictationRecord(text: "свежее", audio: nil, took: 1, model: "m"))

        let reopened = DictationHistoryStore(file: file)
        reopened.reload()
        XCTAssertEqual(reopened.items.first?.text, "свежее")
        XCTAssertEqual(reopened.items.count, 2)
    }

    func testRetentionDropsOldestBeyondLimit() {
        let store = DictationHistoryStore(file: file, limit: 3)
        for index in 1...5 {
            store.append(DictationRecord(
                text: "запись \(index)", audio: nil, took: 1, model: "m",
                at: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        let reopened = DictationHistoryStore(file: file, limit: 3)
        reopened.reload()
        XCTAssertEqual(reopened.items.map(\.text), ["запись 5", "запись 4", "запись 3"])
    }

    func testSearchIgnoresCaseAndDiacritics() {
        write([
            line("Про GitHub и деплой", at: "2026-08-01T10:00:00Z"),
            line("Про ёжика", at: "2026-08-02T10:00:00Z"),
        ])
        let store = DictationHistoryStore(file: file)
        store.reload()
        XCTAssertEqual(store.filtered("github").count, 1)
        XCTAssertEqual(store.filtered("ежик").count, 1)
        XCTAssertEqual(store.filtered("  ").count, 2, "пустой запрос не фильтрует")
    }
}
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `swift test --filter DictationHistoryStoreTests`
Expected: FAIL — `DictationHistoryStore` не найден.

- [ ] **Step 3: Написать хранилище**

```swift
import Foundation

/// The dictation history, kept as JSONL next to the app's other data.
///
/// JSONL rather than one JSON array: a new dictation is a single append, the
/// file survives a crash mid-write, and it stays readable in an editor — the
/// same reasoning that shaped `snippets.json`.
public final class DictationHistoryStore {
    public private(set) var items: [DictationRecord] = []

    private let file: URL
    private let limit: Int

    public init(file: URL = DictationHistoryStore.defaultFile, limit: Int = 500) {
        self.file = file
        self.limit = limit
    }

    public static var defaultFile: URL {
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cyclop", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("dictation-history.jsonl")
    }

    /// Newest first — the panel shows the last dictation at the top, and the
    /// file is written oldest-first because appending is what keeps it cheap.
    public func reload() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            items = []
            return
        }
        items = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { DictationRecord.decode(line: String($0)) }
            .sorted { $0.at > $1.at }
    }

    public func append(_ record: DictationRecord) {
        items.insert(record, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
        persist()
    }

    /// Rewrites the file when retention trimmed it, appends a line otherwise.
    private func persist() {
        let lines = items
            .sorted { $0.at < $1.at }
            .compactMap { try? $0.encodedLine() }
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Case- and accent-blind, matching how the snippets tab searches.
    public func filtered(_ query: String) -> [DictationRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter {
            $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter DictationHistoryStoreTests`
Expected: PASS, 6 тестов.

- [ ] **Step 5: Проверить на настоящем файле истории**

Run: `swift test --filter DictationHistoryStoreTests && wc -l ~/Library/Application\ Support/Cyclop/dictation-history.jsonl`
Expected: тесты зелёные, в файле 155 строк — формат плана совпадает с уже заполненным архивом.

- [ ] **Step 6: Коммит**

```bash
git add Sources/CyclopDictation/DictationHistoryStore.swift Tests/CyclopDictationTests/DictationHistoryStoreTests.swift
git commit -m "Хранилище истории: чтение, дозапись, ретенция, поиск"
```

---

### Task 3: Протокол воркера и нормализация звука

**Files:**
- Create: `Sources/CyclopDictation/WorkerProtocol.swift`
- Create: `Sources/CyclopDictation/AudioNormalizer.swift`
- Test: `Tests/CyclopDictationTests/WorkerProtocolTests.swift`
- Test: `Tests/CyclopDictationTests/AudioNormalizerTests.swift`

**Interfaces:**
- Produces: `enum WorkerRequest` с `case transcribe(path: String)`, `case unload`, `case ping`, метод `func encodedLine() throws -> String`; `struct WorkerResponse: Decodable` с `text: String?`, `took: Double?`, `language: String?`, `error: String?`, `unloaded: Bool?`, `freedMB: Double?`, `static func decode(line: String) -> WorkerResponse?`.
- Produces: `enum AudioNormalizer` с `static func gain(peak: Float, target: Float = -3.0, floor: Float = -50.0) -> Float` и `static func normalize(_ samples: inout [Float], target: Float = -3.0, floor: Float = -50.0) -> Float` (возвращает применённое усиление в dB).

- [ ] **Step 1: Написать падающие тесты**

```swift
// Tests/CyclopDictationTests/WorkerProtocolTests.swift
import XCTest
@testable import CyclopDictation

final class WorkerProtocolTests: XCTestCase {
    func testTranscribeRequestIsOneLine() throws {
        let line = try WorkerRequest.transcribe(path: "/tmp/a b.wav").encodedLine()
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains("\"cmd\":\"transcribe\""))
        XCTAssertTrue(line.contains("/tmp/a b.wav"))
    }

    func testUnloadRequest() throws {
        XCTAssertTrue(try WorkerRequest.unload.encodedLine().contains("\"cmd\":\"unload\""))
    }

    func testDecodesTranscription() {
        let response = WorkerResponse.decode(line: #"{"text":"Привет","took":1.2,"language":"ru"}"#)
        XCTAssertEqual(response?.text, "Привет")
        XCTAssertEqual(response?.language, "ru")
        XCTAssertNil(response?.error)
    }

    func testDecodesError() {
        let response = WorkerResponse.decode(line: #"{"error":"model missing"}"#)
        XCTAssertEqual(response?.error, "model missing")
        XCTAssertNil(response?.text)
    }

    func testDecodesUnloadReport() {
        let response = WorkerResponse.decode(line: #"{"unloaded":true,"freed_mb":3529.5}"#)
        XCTAssertEqual(response?.unloaded, true)
        XCTAssertEqual(response?.freedMB ?? 0, 3529.5, accuracy: 0.01)
    }

    func testGarbageDecodesToNil() {
        XCTAssertNil(WorkerResponse.decode(line: "Traceback (most recent call last):"))
    }
}
```

```swift
// Tests/CyclopDictationTests/AudioNormalizerTests.swift
import XCTest
@testable import CyclopDictation

final class AudioNormalizerTests: XCTestCase {
    func testQuietAudioIsBoostedToTarget() {
        // −20 dBFS peak should gain +17 dB to reach −3 dBFS.
        XCTAssertEqual(AudioNormalizer.gain(peak: -20), 17, accuracy: 0.01)
    }

    func testLoudAudioIsNeverMadeQuieter() {
        XCTAssertEqual(AudioNormalizer.gain(peak: -1), 0, accuracy: 0.01)
    }

    func testSilenceIsLeftAlone() {
        // Below the floor there is nothing but noise to amplify.
        XCTAssertEqual(AudioNormalizer.gain(peak: -60), 0, accuracy: 0.01)
    }

    func testNormalizeScalesSamplesAndNeverClips() {
        var samples: [Float] = [0.1, -0.05, 0.1]
        let applied = AudioNormalizer.normalize(&samples)
        XCTAssertGreaterThan(applied, 0)
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 0, 1.0)
        XCTAssertEqual(samples.map(abs).max() ?? 0, 0.7079, accuracy: 0.001)
    }

    func testEmptyBufferIsSafe() {
        var samples: [Float] = []
        XCTAssertEqual(AudioNormalizer.normalize(&samples), 0)
    }
}
```

- [ ] **Step 2: Прогнать и убедиться, что падают**

Run: `swift test --filter "WorkerProtocolTests|AudioNormalizerTests"`
Expected: FAIL — типы не найдены.

- [ ] **Step 3: Написать протокол**

```swift
import Foundation

/// What Cyclop asks the Python worker to do. One request per line.
public enum WorkerRequest {
    case transcribe(path: String)
    case unload
    case ping

    private struct Payload: Encodable {
        let cmd: String
        let path: String?
    }

    public func encodedLine() throws -> String {
        let payload: Payload
        switch self {
        case .transcribe(let path): payload = Payload(cmd: "transcribe", path: path)
        case .unload: payload = Payload(cmd: "unload", path: nil)
        case .ping: payload = Payload(cmd: "ping", path: nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}

/// One line of the worker's stdout. Every field is optional because the same
/// shape carries a transcription, an unload report and a failure.
public struct WorkerResponse: Decodable {
    public let text: String?
    public let took: Double?
    public let language: String?
    public let error: String?
    public let unloaded: Bool?
    public let freedMB: Double?

    private enum CodingKeys: String, CodingKey {
        case text, took, language, error, unloaded
        case freedMB = "freed_mb"
    }

    /// Python may also print warnings; anything unparseable is not a response.
    public static func decode(line: String) -> WorkerResponse? {
        guard let data = line.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(WorkerResponse.self, from: data)
    }
}
```

- [ ] **Step 4: Написать нормализацию**

```swift
import Foundation

/// Peak normalisation, ported from the Python app's `audio_processor`.
///
/// Whisper handles quiet input badly — it skips words or invents them — so the
/// peak is lifted to a target with headroom. Loud input is never made quieter,
/// and near-silence is left alone rather than amplified into noise.
public enum AudioNormalizer {
    public static func gain(peak dbfs: Float, target: Float = -3.0, floor: Float = -50.0) -> Float {
        guard dbfs > floor, dbfs < target else { return 0 }
        return target - dbfs
    }

    /// Scales the buffer in place, returning the gain applied in dB.
    @discardableResult
    public static func normalize(_ samples: inout [Float], target: Float = -3.0, floor: Float = -50.0) -> Float {
        guard let peak = samples.map(abs).max(), peak > 0 else { return 0 }
        let peakDBFS = 20 * log10(peak)
        let applied = gain(peak: peakDBFS, target: target, floor: floor)
        guard applied > 0 else { return 0 }
        let factor = pow(10, applied / 20)
        for index in samples.indices {
            samples[index] = max(-1, min(1, samples[index] * factor))
        }
        return applied
    }
}
```

- [ ] **Step 5: Прогнать тесты**

Run: `swift test --filter "WorkerProtocolTests|AudioNormalizerTests"`
Expected: PASS, 10 тестов.

- [ ] **Step 6: Коммит**

```bash
git add Sources/CyclopDictation/WorkerProtocol.swift Sources/CyclopDictation/AudioNormalizer.swift Tests/CyclopDictationTests/
git commit -m "Протокол воркера и пиковая нормализация звука"
```

---

### Task 4: Python-воркер

**Files:**
- Create: `Resources/worker/cyclop_worker.py`
- Test: `Resources/worker/test_cyclop_worker.py`
- Modify: `Scripts/bundle.sh:52` (копирование воркера в бандл)

**Interfaces:**
- Consumes: протокол из Task 3.
- Produces: исполняемый скрипт, принимающий JSON-строки на stdin и отвечающий JSON-строками на stdout. Внутренний класс `Engine` с `transcribe(path) -> dict`, `unload() -> dict`, `maybe_unload_idle(now) -> dict | None`.

- [ ] **Step 1: Написать падающий тест**

```python
"""Worker tests. The engine is stubbed: this checks the protocol and the
idle-unload policy, not mlx-whisper, which has its own."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cyclop_worker import Engine, handle_line


class FakeTranscriber:
    def __init__(self):
        self.loaded = False
        self.calls = 0

    def transcribe(self, path):
        self.loaded = True
        self.calls += 1
        return "  распознанный текст  "


class WorkerProtocolTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeTranscriber()
        self.engine = Engine(transcriber=self.fake, idle_seconds=600, clock=lambda: self.now)
        self.now = 1000.0

    def test_transcribe_returns_cleaned_text(self):
        out = handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), self.engine)
        self.assertEqual(out["text"], "распознанный текст")
        self.assertIn("took", out)

    def test_unknown_command_is_an_error_not_a_crash(self):
        out = handle_line(json.dumps({"cmd": "рисовать"}), self.engine)
        self.assertIn("error", out)

    def test_garbage_line_is_an_error_not_a_crash(self):
        out = handle_line("не json", self.engine)
        self.assertIn("error", out)

    def test_unload_reports_and_forgets_the_model(self):
        handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), self.engine)
        out = handle_line(json.dumps({"cmd": "unload"}), self.engine)
        self.assertTrue(out["unloaded"])

    def test_idle_unload_only_after_the_deadline(self):
        handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), self.engine)
        self.now += 599
        self.assertIsNone(self.engine.maybe_unload_idle())
        self.now += 2
        self.assertIsNotNone(self.engine.maybe_unload_idle())

    def test_idle_unload_does_not_repeat_while_still_idle(self):
        handle_line(json.dumps({"cmd": "transcribe", "path": "/tmp/a.wav"}), self.engine)
        self.now += 601
        self.assertIsNotNone(self.engine.maybe_unload_idle())
        self.now += 601
        self.assertIsNone(self.engine.maybe_unload_idle(), "выгружать нечего — модель уже выгружена")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `python3 Resources/worker/test_cyclop_worker.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'cyclop_worker'`.

- [ ] **Step 3: Написать воркер**

```python
"""Transcription worker for Cyclop.

Reads one JSON request per line on stdin, answers with one JSON response per
line on stdout. Exits when stdin closes, so it cannot outlive the app.

The whole point of this process is the tuned mlx-whisper setup: the model, the
initial prompt and the decoding parameters come from `whisper_dictation.config`
untouched. Everything else — hotkey, recording, insertion — lives in Swift.
"""

from __future__ import annotations

import json
import sys
import threading
import time

IDLE_SECONDS = 600


def _log(message: str) -> None:
    # stderr, so it never lands in the response stream.
    print(f"cyclop-worker: {message}", file=sys.stderr, flush=True)


class Engine:
    """Owns the model and decides when to let go of it."""

    def __init__(self, transcriber=None, idle_seconds: float = IDLE_SECONDS, clock=time.monotonic):
        self._transcriber = transcriber
        self._config = None
        self._cleaner_config = None
        self._idle_seconds = idle_seconds
        self._clock = clock
        self._last_used = None
        self._loaded = transcriber is not None

    def _ensure(self):
        if self._transcriber is None:
            from whisper_dictation.config import load_config
            from whisper_dictation.transcriber import WhisperTranscriber

            config = load_config()
            self._config = config
            self._cleaner_config = config.cleaner
            self._transcriber = WhisperTranscriber(config.whisper)
            _log(f"model {config.whisper.model}")
        return self._transcriber

    def transcribe(self, path: str) -> dict:
        started = time.monotonic()
        transcriber = self._ensure()
        raw = transcriber.transcribe(path if isinstance(path, str) else str(path))
        text = raw.strip()
        if self._cleaner_config is not None:
            from whisper_dictation.text_cleaner import clean_text

            text = clean_text(raw, self._cleaner_config).strip()
        self._loaded = True
        self._last_used = self._clock()
        # Hand the allocator's cache back straight away: it is the larger half
        # of this process's footprint and nothing needs it between dictations.
        freed = self._clear_cache()
        return {"text": text, "took": round(time.monotonic() - started, 3), "freed_mb": freed}

    def _clear_cache(self) -> float:
        try:
            import mlx.core as mx
        except ImportError:
            return 0.0
        before = mx.get_cache_memory() / 2**20
        mx.clear_cache()
        return round(before - mx.get_cache_memory() / 2**20, 1)

    def unload(self) -> dict:
        freed = 0.0
        try:
            import mlx.core as mx
            from mlx_whisper.transcribe import ModelHolder

            before = (mx.get_active_memory() + mx.get_cache_memory()) / 2**20
            # The weights are held by a class attribute; dropping it is what
            # actually releases them.
            ModelHolder.model = None
            ModelHolder.model_path = None
            mx.clear_cache()
            freed = round(before - (mx.get_active_memory() + mx.get_cache_memory()) / 2**20, 1)
        except ImportError:
            pass
        self._transcriber = None
        self._loaded = False
        self._last_used = None
        _log(f"unloaded, freed {freed} MB")
        return {"unloaded": True, "freed_mb": freed}

    def maybe_unload_idle(self) -> dict | None:
        if not self._loaded or self._last_used is None:
            return None
        if self._clock() - self._last_used <= self._idle_seconds:
            return None
        return self.unload()


def handle_line(line: str, engine: Engine) -> dict:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        return {"error": "malformed request"}

    command = request.get("cmd")
    try:
        if command == "transcribe":
            return engine.transcribe(request.get("path", ""))
        if command == "unload":
            return engine.unload()
        if command == "ping":
            return {"ok": True}
        return {"error": f"unknown command: {command}"}
    except Exception as exc:  # never let one bad request kill the worker
        return {"error": f"{type(exc).__name__}: {exc}"}


def _idle_watch(engine: Engine, emit) -> None:
    while True:
        time.sleep(30)
        report = engine.maybe_unload_idle()
        if report is not None:
            emit(report)


def main() -> int:
    engine = Engine()
    lock = threading.Lock()

    def emit(payload: dict) -> None:
        with lock:
            sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
            sys.stdout.flush()

    threading.Thread(target=_idle_watch, args=(engine, emit), daemon=True).start()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        emit(handle_line(line, engine))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Прогнать тесты**

Run: `python3 Resources/worker/test_cyclop_worker.py -v`
Expected: PASS, 6 тестов.

- [ ] **Step 5: Проверить воркер на настоящей записи**

```bash
VENV=~/Library/Application\ Support/WhisperDictation/runtime/.venv/bin/python
WAV=$(ls ~/Library/Application\ Support/WhisperDictation/recordings/*.wav | head -1)
printf '{"cmd":"transcribe","path":"%s"}\n{"cmd":"unload"}\n' "$WAV" | "$VENV" Resources/worker/cyclop_worker.py
```

Expected: две строки JSON — первая с распознанным текстом и `freed_mb`, вторая с `"unloaded": true` и `freed_mb` порядка 1500–3500.

- [ ] **Step 6: Класть воркер в бандл**

В `Scripts/bundle.sh` после блока с локализациями (строка 64) добавить:

```bash
echo "==> транскрайбер"
mkdir -p "$APP/Contents/Resources/worker"
cp "$ROOT"/Resources/worker/*.py "$APP/Contents/Resources/worker/"
```

- [ ] **Step 7: Коммит**

```bash
git add Resources/worker/ Scripts/bundle.sh
git commit -m "Python-воркер: транскрибация, чистка кэша, выгрузка по простою"
```

---

### Task 5: Мост к воркеру

**Files:**
- Create: `Sources/Cyclop/Dictation/TranscriberBridge.swift`
- Reference: `Sources/Cyclop/Services/NowPlayingFeed.swift:55-127` — образец запуска и разбора построчного вывода.

**Interfaces:**
- Consumes: `WorkerRequest`, `WorkerResponse` из Task 3.
- Produces: `@MainActor final class TranscriberBridge` с `var onResult: ((Result<String, Error>) -> Void)?`, `func start()`, `func stop()`, `func transcribe(path: URL)`, `func unload()`, `var isRunning: Bool`.

- [ ] **Step 1: Написать мост**

```swift
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

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = ["-u", workerPath]

        let output = Pipe()
        let commands = Pipe()
        task.standardOutput = output
        task.standardInput = commands
        task.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.consume(chunk) }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
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

    private func handleTermination() {
        guard !stopped else { return }
        process = nil
        input = nil
        failures += 1
        guard failures < 3 else {
            onResult?(.failure(BridgeError.worker(localized("Transcription worker keeps failing"))))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launch() }
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

    private func consume(_ chunk: Data) {
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
```

- [ ] **Step 2: Собрать**

Run: `swift build 2>&1 | grep -E "error|warning: unused" || echo OK`
Expected: OK — сборка чистая.

- [ ] **Step 3: Коммит**

```bash
git add Sources/Cyclop/Dictation/TranscriberBridge.swift
git commit -m "Мост к транскрайберу: запуск воркера и разбор ответов"
```

---

### Task 6: Хоткей push-to-talk

**Files:**
- Create: `Sources/CyclopDictation/HoldGesture.swift`
- Create: `Sources/Cyclop/Dictation/HotkeyMonitor.swift`
- Test: `Tests/CyclopDictationTests/HoldGestureTests.swift`

**Interfaces:**
- Produces: `struct HoldGesture` с `init(minimumHold: TimeInterval = 0.25)`, `mutating func press(at: TimeInterval) -> Bool`, `mutating func release(at: TimeInterval) -> HoldGesture.Outcome`, `enum Outcome { case ignoredTap, recorded(TimeInterval) }`.
- Produces: `@MainActor final class HotkeyMonitor` с `var onPress: (() -> Void)?`, `var onRelease: ((TimeInterval) -> Void)?`, `func start() -> Bool`, `func stop()`, `static var hasAccessibilityPermission: Bool`.

- [ ] **Step 1: Написать падающий тест**

```swift
import XCTest
@testable import CyclopDictation

final class HoldGestureTests: XCTestCase {
    func testShortTapIsIgnored() {
        var gesture = HoldGesture(minimumHold: 0.25)
        XCTAssertTrue(gesture.press(at: 100))
        guard case .ignoredTap = gesture.release(at: 100.1) else {
            return XCTFail("нажатие короче порога должно игнорироваться")
        }
    }

    func testHeldPressIsRecorded() {
        var gesture = HoldGesture(minimumHold: 0.25)
        _ = gesture.press(at: 100)
        guard case .recorded(let held) = gesture.release(at: 103) else {
            return XCTFail("удержание должно давать запись")
        }
        XCTAssertEqual(held, 3, accuracy: 0.001)
    }

    func testSecondPressWhileHeldIsRejected() {
        var gesture = HoldGesture(minimumHold: 0.25)
        XCTAssertTrue(gesture.press(at: 100))
        XCTAssertFalse(gesture.press(at: 100.5), "автоповтор не должен начинать вторую запись")
    }

    func testReleaseWithoutPressIsIgnored() {
        var gesture = HoldGesture(minimumHold: 0.25)
        guard case .ignoredTap = gesture.release(at: 100) else {
            return XCTFail("отпускание без нажатия ничего не значит")
        }
    }
}
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `swift test --filter HoldGestureTests`
Expected: FAIL — `HoldGesture` не найден.

- [ ] **Step 3: Написать состояние жеста**

```swift
import Foundation

/// Push-to-talk state, kept apart from the event tap so it can be tested.
///
/// The key repeat fires while a modifier is held down, so a press that arrives
/// while one is already in flight is not a new recording.
public struct HoldGesture {
    public enum Outcome: Equatable {
        /// Too short to be speech — a stray brush of the key.
        case ignoredTap
        case recorded(TimeInterval)
    }

    private let minimumHold: TimeInterval
    private var pressedAt: TimeInterval?

    public init(minimumHold: TimeInterval = 0.25) {
        self.minimumHold = minimumHold
    }

    /// Returns whether this press starts a recording.
    public mutating func press(at time: TimeInterval) -> Bool {
        guard pressedAt == nil else { return false }
        pressedAt = time
        return true
    }

    public mutating func release(at time: TimeInterval) -> Outcome {
        guard let started = pressedAt else { return .ignoredTap }
        pressedAt = nil
        let held = time - started
        return held >= minimumHold ? .recorded(held) : .ignoredTap
    }
}
```

- [ ] **Step 4: Прогнать тесты**

Run: `swift test --filter HoldGestureTests`
Expected: PASS, 4 теста.

- [ ] **Step 5: Написать монитор клавиши**

```swift
import AppKit
import CyclopDictation

/// Watches the right Option key, system-wide.
///
/// Right Option is free of macOS shortcuts (unlike F5, which is Dictation) and
/// is not the one used to type special characters, which is the left. Reading
/// it anywhere but in our own windows needs an event tap, and an event tap
/// needs Accessibility — the permission is requested when dictation is first
/// used, never at launch.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = HoldGesture(minimumHold: 0.25)

    /// Virtual keycode of the right Option key.
    private static let rightOptionKeyCode: Int64 = 61

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt. Only ever called from an explicit user action.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasAccessibilityPermission else { return false }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Listen only: the key must keep working for whoever else wants it.
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The tap is disabled by the system if it ever times out; re-arming is
        // cheaper than losing the hotkey until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOptionKeyCode
        else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let isDown = event.flags.contains(.maskAlternate)
        if isDown {
            if gesture.press(at: now) { onPress?() }
        } else {
            if case .recorded(let held) = gesture.release(at: now) { onRelease?(held) }
            else { onRelease?(0) }
        }
    }
}
```

- [ ] **Step 6: Собрать и закоммитить**

Run: `swift build 2>&1 | grep error || echo OK`

```bash
git add Sources/CyclopDictation/HoldGesture.swift Sources/Cyclop/Dictation/HotkeyMonitor.swift Tests/CyclopDictationTests/HoldGestureTests.swift
git commit -m "Хоткей: правый Option как push-to-talk"
```

---

### Task 7: Запись с микрофона и вставка текста

**Files:**
- Create: `Sources/Cyclop/Dictation/AudioRecorder.swift`
- Create: `Sources/Cyclop/Dictation/TextInserter.swift`
- Modify: `Scripts/bundle.sh:41` — добавить `NSMicrophoneUsageDescription` в Info.plist.

**Interfaces:**
- Consumes: `AudioNormalizer` из Task 3.
- Produces: `@MainActor final class AudioRecorder` с `func start() throws`, `func stop() -> URL?`, `var isRecording: Bool`, `static var folder: URL`.
- Produces: `enum TextInserter` со `static func insert(_ text: String)`.

- [ ] **Step 1: Написать запись**

```swift
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
```

- [ ] **Step 2: Написать вставку**

```swift
import AppKit

/// Puts text into the focused field of whatever app is in front.
///
/// Through the pasteboard and a synthetic ⌘V: typing the characters one by one
/// would need the same Accessibility permission and would be slower and less
/// reliable with non-Latin text. The previous pasteboard contents are restored
/// afterwards — a dictation should not cost the user what they had copied.
enum TextInserter {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postPaste()

        // Long enough for the target app to have read the pasteboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let saved else { return }
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // 9 is the "v" key.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 3: Добавить описание доступа к микрофону**

В `Scripts/bundle.sh`, в блок Info.plist после `NSAppleEventsUsageDescription` (строка 42):

```xml
    <key>NSMicrophoneUsageDescription</key>
    <string>Cyclop записывает голос локально, чтобы превратить его в текст.</string>
```

- [ ] **Step 4: Собрать и закоммитить**

Run: `swift build 2>&1 | grep error || echo OK`

```bash
git add Sources/Cyclop/Dictation/AudioRecorder.swift Sources/Cyclop/Dictation/TextInserter.swift Scripts/bundle.sh
git commit -m "Запись с микрофона и вставка распознанного текста"
```

---

### Task 8: Контроллер диктовки

**Files:**
- Create: `Sources/Cyclop/Dictation/DictationController.swift`
- Modify: `Sources/Cyclop/Model/NotchViewModel.swift:63-104` — добавить `let dictation: DictationController` и подписку на его `objectWillChange`.

**Interfaces:**
- Consumes: `HotkeyMonitor`, `AudioRecorder`, `TranscriberBridge`, `TextInserter`, `DictationHistoryStore`, `DictationRecord`.
- Produces: `@MainActor final class DictationController: ObservableObject` с `@Published private(set) var state: State`, `enum State { case idle, needsPermission, recording, transcribing, failed(String) }`, `@Published var query: String`, `var history: [DictationRecord]`, `func start()`, `func stop()`, `func enable()`, `func copy(_ record:)`, `func play(_ record:)`, `var isBusy: Bool`.

- [ ] **Step 1: Написать контроллер**

```swift
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
        store.reload()
        bridge.onResult = { [weak self] result in self?.handle(result) }

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
        guard let url = recorder.stop() else {
            state = .idle
            return
        }
        pendingAudio = url
        state = .transcribing
        bridge.transcribe(path: url)
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
```

- [ ] **Step 2: Подключить к модели панели**

В `Sources/Cyclop/Model/NotchViewModel.swift`: добавить свойство рядом с остальными службами (после `let snippets: SnippetStore`, строка 69):

```swift
    let dictation: DictationController
```

в `init` после `self.snippets = SnippetStore()`:

```swift
        self.dictation = DictationController()
```

в список подписок (строка 94, массив `for child in [...]`) добавить `dictation.objectWillChange,`; в `start()` после `snippets.reload()` добавить `dictation.start()`; в `stop()` добавить `dictation.stop()`.

- [ ] **Step 3: Собрать**

Run: `swift build 2>&1 | grep error || echo OK`
Expected: OK.

- [ ] **Step 4: Коммит**

```bash
git add Sources/Cyclop/Dictation/DictationController.swift Sources/Cyclop/Model/NotchViewModel.swift
git commit -m "Контроллер диктовки: хоткей, запись, распознавание, вставка, история"
```

---

### Task 9: Вкладка истории и индикатор в челке

**Files:**
- Create: `Sources/Cyclop/UI/DictationPane.swift`
- Modify: `Sources/Cyclop/Model/NotchViewModel.swift:6-34` — новый `case dictation` в `Tab`
- Modify: `Sources/Cyclop/UI/NotchContentView.swift:69-98` и `143-159` — шапка и переключение вкладки
- Modify: `Resources/en.lproj/Localizable.strings`, `Resources/ru.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `DictationController` из Task 8.

- [ ] **Step 1: Добавить вкладку в модель**

В `NotchViewModel.Tab`: `case media, shelf, clipboard, snippets, dictation, calendar, translate`; в `symbol` добавить `case .dictation: return "waveform"`; в `title` — `case .dictation: return localized("Dictation")`; в `needsKeyboard` — `self == .translate || self == .snippets || self == .dictation`.

В `didSet` вкладки, рядом с обработкой календаря:

```swift
            if tab == .dictation {
                dictation.refreshPermission()
                dictation.reload()
            }
```

- [ ] **Step 2: Написать панель**

```swift
import SwiftUI
import CyclopDictation

struct DictationPane: View {
    @ObservedObject var dictation: DictationController
    @Binding var wantsKeyboard: Bool

    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 6) {
            switch dictation.state {
            case .needsPermission:
                permission
            case .failed(let message):
                failure(message)
            default:
                search
                list
            }
        }
        .padding(.top, 2)
        .onChange(of: wantsKeyboard) { _, wants in searching = wants }
        .animation(Theme.contentAnimation, value: dictation.state)
    }

    // MARK: - Search

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            TextField("", text: $dictation.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .tint(Theme.secondary)
                .focused($searching)
                .onKeyPress(.escape) {
                    dictation.query = ""
                    return .handled
                }
            if !dictation.query.isEmpty {
                Button { dictation.query = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
        .contentShape(Rectangle())
        .onTapGesture { searching = true }
        .onAppear { if wantsKeyboard { searching = true } }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if dictation.history.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: dictation.query.isEmpty ? "waveform" : "magnifyingglass")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                if dictation.query.isEmpty {
                    Text("Hold right ⌥ and speak")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(dictation.history) { record in
                        DictationRow(record: record, dictation: dictation)
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - States

    private var permission: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("Dictation needs the microphone and Accessibility:\none to hear you, one to see the key and paste the text.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary)
            Button { dictation.enable() } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.surfaceHover))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text(message)
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DictationRow: View {
    let record: DictationRecord
    @ObservedObject var dictation: DictationController
    @State private var hovering = false
    @State private var justCopied = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.setLocalizedDateFormatFromTemplate("dMMM HH:mm")
        return formatter
    }()

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : "waveform")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 14)
            Text(record.text.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if hovering, record.audio != nil {
                Button { dictation.play(record) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Play the recording"))
            }
            Text(Self.time.string(from: record.at))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.surfaceHover : Theme.surface))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            dictation.copy(record)
            justCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { justCopied = false }
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }
}
```

- [ ] **Step 3: Подключить панель и индикатор**

В `NotchContentView.pane` добавить:

```swift
        case .dictation:
            DictationPane(dictation: vm.dictation, wantsKeyboard: $vm.wantsKeyboard)
```

В `NotchContentView.trailing` добавить состояние — оно видно и когда панель просто раскрыта:

```swift
        case .dictation:
            switch vm.dictation.state {
            case .recording:
                HStack(spacing: 5) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("Recording")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            case .transcribing:
                Text("Transcribing…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            default:
                counter(vm.dictation.history.count)
            }
```

- [ ] **Step 4: Добавить строки локализации**

В `Resources/ru.lproj/Localizable.strings`:

```
/* Диктовка */
"Dictation" = "Диктовка";
"Hold right ⌥ and speak" = "Удерживай правый ⌥ и говори";
"Recording" = "Запись";
"Transcribing…" = "Распознаю…";
"Play the recording" = "Прослушать запись";
"Dictation needs the microphone and Accessibility:\nto hear you and to see the key and paste the text." = "Диктовке нужны микрофон и Универсальный доступ:\nуслышать тебя, увидеть клавишу и вставить текст.";
"Transcription runtime not found" = "Не найден рантайм распознавания";
"Transcription worker keeps failing" = "Распознавание не запускается";
"No microphone available" = "Микрофон недоступен";
"Cannot convert microphone input" = "Не удалось преобразовать сигнал микрофона";
```

В `Resources/en.lproj/Localizable.strings` — те же ключи со значениями, равными ключам.

- [ ] **Step 5: Собрать и проверить глазами**

```bash
./Scripts/bundle.sh release && rm -rf /Applications/Cyclop.app && cp -R build/Cyclop.app /Applications/ && open -a /Applications/Cyclop.app
```

Expected: в рейке семь иконок, вкладка «Диктовка» показывает 155 записей архива, поиск по ним работает, клик копирует, кнопка ▶ проигрывает.

- [ ] **Step 6: Коммит**

```bash
git add Sources/Cyclop/UI/DictationPane.swift Sources/Cyclop/UI/NotchContentView.swift Sources/Cyclop/Model/NotchViewModel.swift Resources/
git commit -m "Вкладка диктовки: история, поиск, воспроизведение, индикатор записи"
```

---

### Task 10: Панель не закрывается во время диктовки

**Files:**
- Modify: `Sources/Cyclop/Notch/NotchController.swift` — удержание панели, пока идёт запись или распознавание.

- [ ] **Step 1: Держать панель открытой**

В `NotchController` после сборки модели подписаться на состояние диктовки:

```swift
        // A panel that collapses mid-sentence takes the only indication that
        // anything is being recorded with it.
        viewModel.dictation.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, let viewModel = self.viewModel else { return }
                switch state {
                case .recording, .transcribing:
                    viewModel.tab = .dictation
                    self.setOpen(true)
                default:
                    // Left open only until the pointer says otherwise.
                    self.pointer.setInside(viewModel.geometry.expandedHoverRect.contains(NSEvent.mouseLocation))
                }
            }
            .store(in: &cancellables)
```

- [ ] **Step 2: Проверить вручную**

Запустить приложение, увести курсор от челки, удержать правый ⌥ и сказать фразу.
Expected: панель раскрывается сама на вкладке диктовки, показывает красную точку и «Запись», после отпускания — «Распознаю…», затем текст вставляется в активное поле и появляется первой строкой в истории; панель сворачивается, если курсор не над ней.

- [ ] **Step 3: Коммит**

```bash
git add Sources/Cyclop/Notch/NotchController.swift
git commit -m "Панель держится открытой, пока идёт диктовка"
```

---

### Task 11: Замер памяти и отключение старого приложения

**Files:**
- Create: `docs/dictation-memory.md`
- Modify: `README.md` — раздел про диктовку.

- [ ] **Step 1: Замерить память до и после простоя**

```bash
PID=$(pgrep -f "cyclop_worker.py" | head -1)
footprint -p "$PID" 2>/dev/null | tail -3
```

Записать три числа в `docs/dictation-memory.md`: сразу после диктовки, через минуту, через 11 минут простоя.
Expected: после выгрузки по простою — меньше 100 МБ.

- [ ] **Step 2: Убрать старое приложение из автозапуска**

```bash
osascript -e 'tell application "WhisperDictation" to quit' 2>/dev/null || pkill -f WhisperDictation
```

Затем System Settings → General → Login Items — убрать WhisperDictation. Сам `.app` не удалять: он остаётся запасным путём, пока новый не отработает неделю.

- [ ] **Step 3: Дописать README**

Добавить строку в таблицу возможностей:

```markdown
| **Диктовка** | Удерживай правый ⌥, говори, отпусти — текст появляется под курсором. Распознавание локальное (Whisper large-v3-turbo через MLX), история расшифровок с поиском и прослушиванием лежит в той же вкладке |
```

И раздел про разрешения: диктовке нужны микрофон и Универсальный доступ, оба запрашиваются при первом использовании вкладки.

- [ ] **Step 4: Коммит и пуш**

```bash
git add README.md docs/dictation-memory.md
git commit -m "README и замеры памяти после переноса диктовки"
git push -u origin dictation
```

---

## Самопроверка плана

**Покрытие спеки:**

| Требование спеки | Задача |
|---|---|
| Движок и промпт без изменений | Task 4 (воркер использует `whisper_dictation.config`) |
| `clear_cache` после каждой диктовки | Task 4, `Engine.transcribe` |
| Выгрузка по простою | Task 4, `Engine.maybe_unload_idle` |
| Прогрев при первом нажатии, не при старте | Task 4 — модель грузится лениво в `_ensure`, вызываемом первой транскрибацией |
| Аудио массивом, без тройного диска | Task 7 — нормализация в памяти, файл пишется один раз |
| Протокол воркера | Task 3 (Swift), Task 4 (Python) |
| История JSONL, ретенция 500 | Task 1, Task 2 |
| Вкладка: поиск, копирование, воспроизведение | Task 9 |
| Индикатор записи в челке | Task 9 (шапка), Task 10 (удержание панели) |
| Разрешения по факту использования | Task 8 (`enable`, `refreshPermission`), Task 9 (экран с кнопкой) |
| Конфликт хоткея со старым приложением | Task 11 |
| Заполнение архивом | выполнено до плана: 155 записей уже в файле истории |

**Согласованность типов:** `DictationRecord` создаётся в Task 1 и используется в Task 2, 8, 9 с теми же полями; `WorkerResponse.freedMB` объявлен в Task 3 и читается в Task 5; `HoldGesture.Outcome` объявлен в Task 6 и там же используется; `DictationController.State` объявлен в Task 8 и читается в Task 9 и 10.

**Заглушек нет:** каждый шаг содержит код или точную команду.
