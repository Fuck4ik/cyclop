# Запись и расшифровка встреч — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cyclop записывает встречу или звонок и кладёт рядом с записью `transcript.md` с итогами и лентой реплик по говорящим.

**Architecture:** Логика, которую стоит проверять, живёт в новом таргете библиотеки `CyclopMeetings` — SwiftPM не даёт тестам импортировать executable. Работа с системой (ScreenCaptureKit, AVFoundation, сеть, UI) остаётся в `Sources/Cyclop/Meetings/` и проверяется вручную. Задачи 1–6 не требуют ни микрофона, ни сети; задачи 7–12 собирают из них рабочую фичу.

**Tech Stack:** Swift 6 в языковом режиме v5, SwiftUI + AppKit, ScreenCaptureKit, AVFoundation, XCTest. Никаких внешних зависимостей.

**Spec:** [`docs/superpowers/specs/2026-08-28-meetings-core-design.md`](../specs/2026-08-28-meetings-core-design.md)

## Global Constraints

- **Комментарии в коде — по-английски.** Объясняют причину решения, а не пересказывают код.
- **Сообщения коммитов — по-русски.**
- **Никаких внешних зависимостей.** SwiftPM-манифест не пополняется сторонними пакетами.
- **Языковой режим v5** у каждого нового таргета: `swiftSettings: [.swiftLanguageMode(.v5)]`.
- **Платформа macOS 15+** (`platforms: [.macOS(.v15)]` уже стоит).
- **Тестируемая логика — только в `Sources/CyclopMeetings/`.** В `Sources/Cyclop/` тестов нет и быть не может.
- **Каждая видимая строка — в обе локализации,** `Resources/ru.lproj/Localizable.strings` и `Resources/en.lproj/Localizable.strings`, ключ дословно совпадает с литералом в коде.
- **Разрешения запрашиваются по факту использования,** не при запуске.
- **Модель расшифровки:** `gemini-3.7-flash-high` через CLIProxyAPI, `POST <host>/v1beta/models/<model>:generateContent`.
- **Порог нарезки — 55 минут** (3300 секунд).
- **Сжатие для отправки:** 32 kbps, mono, Opus.
- **Видео:** 1080p, фрагментированный mp4, HEVC.
- **Reduce Motion уважается** в каждой анимации.

## File Structure

**Создаётся — `Sources/CyclopMeetings/` (библиотека, под тестами):**

| Файл | Отвечает за |
|---|---|
| `TranscriptSegment.swift` | одна реплика: таймкод, говорящий, текст; форматирование строки ленты |
| `TranscriptParser.swift` | разбор ответа модели в сегменты |
| `ChunkPlan.swift` | границы нарезки длинной записи и сдвиг таймкодов |
| `TranscriptMerger.swift` | слияние ленты микрофона и ленты системного звука |
| `MeetingPrompts.swift` | промпты расшифровки и summary |
| `TranscriptDocument.swift` | сборка `transcript.md` |
| `MeetingFolder.swift` | имя папки встречи, пути к файлам, разбор существующих папок |
| `MeetingState.swift` | статус встречи и его запись в `.state.json` |

**Создаётся — `Sources/Cyclop/Meetings/` (система, вручную):**

| Файл | Отвечает за |
|---|---|
| `MeetingRecorder.swift` | ScreenCaptureKit: старт, стоп, два файла |
| `MeetingAudio.swift` | извлечение дорожки из mp4, сжатие, нарезка |
| `MeetingProcessor.swift` | пайплайн обработки от файлов до готового md |
| `CallDetector.swift` | подписка на занятость микрофона |
| `MeetingsController.swift` | состояние вкладки и очередь обработки |

**Создаётся — UI и тесты:**

| Файл | Отвечает за |
|---|---|
| `Sources/Cyclop/UI/MeetingsPane.swift` | вкладка «Встречи» |
| `Sources/Cyclop/UI/RecordingOffer.swift` | карточка предложения под вырезом |
| `Tests/CyclopMeetingsTests/*.swift` | тесты библиотеки |

**Изменяется:**

| Файл | Что меняется |
|---|---|
| `Package.swift` | таргеты `CyclopMeetings` и `CyclopMeetingsTests` |
| `Sources/Cyclop/Dictation/CloudTranscriber.swift` | транспорт выносится в общий тип |
| `Sources/Cyclop/Model/NotchViewModel.swift` | вкладка `.meetings`, контроллер встреч |
| `Sources/Cyclop/UI/NotchContentView.swift` | индикатор записи, карточка предложения |
| `Sources/Cyclop/UI/SettingsPane.swift` | папка встреч и имя владельца |
| `Resources/*.lproj/Localizable.strings` | новые строки |
| `AGENTS.md` | грабли этапа |

---

## Task 1: Таргет библиотеки и модель реплики

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CyclopMeetings/TranscriptSegment.swift`
- Test: `Tests/CyclopMeetingsTests/TranscriptSegmentTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces: `public struct TranscriptSegment: Equatable, Sendable` с полями `public let start: TimeInterval`, `public let speaker: String`, `public let text: String`; `public init(start:speaker:text:)`; `public var timecode: String` (формат `00:01:05`); `public var line: String` (формат `**[00:01:05] Роман:** текст`); `public func shifted(by: TimeInterval) -> TranscriptSegment`

- [ ] **Step 1: Прописать таргеты в Package.swift**

В массив `targets` после блока `CyclopFinderPath` добавить:

```swift
        // Meeting logic lives apart from the executable for the same reason
        // dictation does: a test target cannot import an executable one.
        .target(
            name: "CyclopMeetings",
            path: "Sources/CyclopMeetings",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

В зависимости исполняемого таргета `Cyclop` добавить новый модуль:

```swift
            dependencies: ["CyclopDictation", "CyclopMeetings"],
```

В конец массива `targets` добавить тестовый таргет:

```swift
        .testTarget(
            name: "CyclopMeetingsTests",
            dependencies: ["CyclopMeetings"],
            path: "Tests/CyclopMeetingsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

- [ ] **Step 2: Написать падающий тест**

Создать `Tests/CyclopMeetingsTests/TranscriptSegmentTests.swift`:

```swift
import XCTest
@testable import CyclopMeetings

final class TranscriptSegmentTests: XCTestCase {
    func testTimecodeIsPaddedToHours() {
        XCTAssertEqual(TranscriptSegment(start: 0, speaker: "Роман", text: "да").timecode, "00:00:00")
        XCTAssertEqual(TranscriptSegment(start: 65, speaker: "Роман", text: "да").timecode, "00:01:05")
        XCTAssertEqual(TranscriptSegment(start: 3725, speaker: "Роман", text: "да").timecode, "01:02:05")
    }

    func testLineMatchesTranscriptFormat() {
        let segment = TranscriptSegment(start: 5, speaker: "Участник 2", text: "Логи в Grafana")
        XCTAssertEqual(segment.line, "**[00:00:05] Участник 2:** Логи в Grafana")
    }

    /// Chunks are transcribed independently, so every segment of the second
    /// chunk arrives with a timecode counted from that chunk's own start.
    func testShiftMovesTheTimecode() {
        let segment = TranscriptSegment(start: 10, speaker: "Роман", text: "да")
        XCTAssertEqual(segment.shifted(by: 3300).start, 3310)
        XCTAssertEqual(segment.shifted(by: 3300).timecode, "00:55:10")
    }
}
```

- [ ] **Step 3: Убедиться, что тест падает**

Run: `swift test --filter TranscriptSegmentTests`
Expected: FAIL — `no such module 'CyclopMeetings'` либо `cannot find 'TranscriptSegment' in scope`

- [ ] **Step 4: Написать реализацию**

Создать `Sources/CyclopMeetings/TranscriptSegment.swift`:

```swift
import Foundation

/// One line of a transcript: who spoke, when, and what was said.
///
/// The timecode is stored as seconds from the start of the recording rather
/// than as text, because chunks of a long meeting are transcribed separately
/// and every one of them counts from its own zero — arithmetic has to work.
public struct TranscriptSegment: Equatable, Sendable {
    public let start: TimeInterval
    public let speaker: String
    public let text: String

    public init(start: TimeInterval, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }

    public var timecode: String {
        let total = Int(start.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// The exact shape the transcript file uses, and the one the model is asked
    /// to produce — parser and writer stay in sync through this one property.
    public var line: String {
        "**[\(timecode)] \(speaker):** \(text)"
    }

    public func shifted(by offset: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(start: start + offset, speaker: speaker, text: text)
    }
}
```

- [ ] **Step 5: Убедиться, что тесты проходят**

Run: `swift test --filter TranscriptSegmentTests`
Expected: PASS, 3 теста

- [ ] **Step 6: Убедиться, что весь проект собирается и старые тесты живы**

Run: `swift build && swift test 2>&1 | grep -E "Executed .* tests"`
Expected: сборка без ошибок, 85 прежних тестов проходят

- [ ] **Step 7: Коммит**

```bash
git add Package.swift Sources/CyclopMeetings Tests/CyclopMeetingsTests
git commit -m "Таргет CyclopMeetings и модель реплики

Логика встреч живёт отдельным таргетом по той же причине, что и логика
диктовки: тестовый таргет не может импортировать исполняемый.

Таймкод хранится секундами, а не текстом: куски длинной встречи
расшифровываются порознь и каждый считает время от собственного нуля."
```

---

## Task 2: Разбор ответа модели

**Files:**
- Create: `Sources/CyclopMeetings/TranscriptParser.swift`
- Test: `Tests/CyclopMeetingsTests/TranscriptParserTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment` из Task 1
- Produces: `public enum TranscriptParser` с `public static func segments(from text: String) -> [TranscriptSegment]`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/CyclopMeetingsTests/TranscriptParserTests.swift`:

```swift
import XCTest
@testable import CyclopMeetings

final class TranscriptParserTests: XCTestCase {
    func testParsesTheFormatTheModelIsAskedFor() {
        let answer = """
            **[00:00:00] Участник 1:** Так, коллеги, давайте начнём.
            **[00:00:05] Участник 2:** Я посмотрел логи в Grafana.
            """
        let segments = TranscriptParser.segments(from: answer)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0], TranscriptSegment(
            start: 0, speaker: "Участник 1", text: "Так, коллеги, давайте начнём."))
        XCTAssertEqual(segments[1].start, 5)
        XCTAssertEqual(segments[1].speaker, "Участник 2")
    }

    /// Models drift: sometimes the asterisks are gone, sometimes an hour-less
    /// timecode arrives. Both still carry a usable transcript.
    func testAcceptsPlainAndShortTimecodes() {
        let answer = """
            [00:00:07] Участник 1: без звёздочек
            **[01:05] Участник 2:** без часов
            """
        let segments = TranscriptParser.segments(from: answer)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "без звёздочек")
        XCTAssertEqual(segments[1].start, 65)
    }

    /// A preamble like "Вот расшифровка:" must not become a segment, and an
    /// empty answer must not become an empty speaker.
    func testSkipsEverythingWithoutATimecode() {
        XCTAssertTrue(TranscriptParser.segments(from: "Вот расшифровка записи:").isEmpty)
        XCTAssertTrue(TranscriptParser.segments(from: "").isEmpty)
    }

    /// A speech that runs past the line break belongs to the segment above it,
    /// not to nobody.
    func testContinuationLinesJoinThePreviousSegment() {
        let answer = """
            **[00:00:00] Участник 1:** Первая строка
            и её продолжение.
            **[00:00:09] Участник 2:** Вторая.
            """
        let segments = TranscriptParser.segments(from: answer)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Первая строка и её продолжение.")
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter TranscriptParserTests`
Expected: FAIL — `cannot find 'TranscriptParser' in scope`

- [ ] **Step 3: Написать реализацию**

Создать `Sources/CyclopMeetings/TranscriptParser.swift`:

```swift
import Foundation

/// Turns the model's answer into segments.
///
/// Deliberately forgiving. The model is asked for one exact shape, but it
/// drifts: asterisks disappear, an hour-less timecode shows up, an
/// introductory sentence gets added on top. A transcript is worth keeping
/// even when its formatting slipped, so anything with a timecode is taken and
/// everything else is skipped.
public enum TranscriptParser {
    /// `**[01:02:03] Speaker:** text`, with the asterisks and the hours
    /// optional.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\**\[(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\]\s*([^:*]+?)\**\s*:\**\s*(.*)$"#
    )

    public static func segments(from text: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = pattern.firstMatch(in: line, range: range) else {
                // A line without a timecode is either a preamble before the
                // first segment (dropped) or a speech that wrapped (kept).
                if let last = segments.popLast() {
                    segments.append(TranscriptSegment(
                        start: last.start,
                        speaker: last.speaker,
                        text: "\(last.text) \(line)"
                    ))
                }
                continue
            }

            let hours = number(match, 1, in: line) ?? 0
            let minutes = number(match, 2, in: line) ?? 0
            let seconds = number(match, 3, in: line) ?? 0
            let speaker = string(match, 4, in: line).trimmingCharacters(in: .whitespaces)
            let body = string(match, 5, in: line).trimmingCharacters(in: .whitespaces)
            guard !speaker.isEmpty else { continue }

            segments.append(TranscriptSegment(
                start: TimeInterval(hours * 3600 + minutes * 60 + seconds),
                speaker: speaker,
                text: body
            ))
        }
        return segments
    }

    private static func string(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String {
        guard let range = Range(match.range(at: index), in: line) else { return "" }
        return String(line[range])
    }

    private static func number(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> Int? {
        Int(string(match, index, in: line))
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --filter TranscriptParserTests`
Expected: PASS, 4 теста

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopMeetings/TranscriptParser.swift Tests/CyclopMeetingsTests/TranscriptParserTests.swift
git commit -m "Разбор ответа модели в реплики

Разбор нарочно снисходительный: модель просят об одной форме, но она
плывёт — то звёздочки пропадут, то часы, то сверху появится вводная
фраза. Расшифровка ценна и с поехавшим форматированием, поэтому берётся
всё, где есть таймкод, а строка без него прирастает к предыдущей реплике."
```

---

## Task 3: Нарезка длинной записи

**Files:**
- Create: `Sources/CyclopMeetings/ChunkPlan.swift`
- Test: `Tests/CyclopMeetingsTests/ChunkPlanTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces: `public struct ChunkPlan` с `public struct Chunk: Equatable, Sendable { public let start: TimeInterval; public let duration: TimeInterval }`; `public static let limit: TimeInterval` (3300); `public static func chunks(forDuration: TimeInterval) -> [Chunk]`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/CyclopMeetingsTests/ChunkPlanTests.swift`:

```swift
import XCTest
@testable import CyclopMeetings

final class ChunkPlanTests: XCTestCase {
    /// An hour of audio is 18 MB in base64 against a 20 MB request ceiling,
    /// so the threshold sits at 55 minutes rather than at a round hour.
    func testLimitIs55Minutes() {
        XCTAssertEqual(ChunkPlan.limit, 3300)
    }

    func testShortMeetingStaysWhole() {
        let chunks = ChunkPlan.chunks(forDuration: 1800)
        XCTAssertEqual(chunks, [ChunkPlan.Chunk(start: 0, duration: 1800)])
    }

    func testMeetingExactlyAtTheLimitStaysWhole() {
        XCTAssertEqual(ChunkPlan.chunks(forDuration: 3300).count, 1)
    }

    func testLongMeetingIsCutIntoWholeChunks() {
        let chunks = ChunkPlan.chunks(forDuration: 7200)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], ChunkPlan.Chunk(start: 0, duration: 3300))
        XCTAssertEqual(chunks[1], ChunkPlan.Chunk(start: 3300, duration: 3300))
        XCTAssertEqual(chunks[2], ChunkPlan.Chunk(start: 6600, duration: 600))
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.duration }, 7200)
    }

    /// A recording that stopped a second after the limit would otherwise
    /// produce a one-second chunk, which costs a whole request for nothing.
    func testTinyTailIsFoldedIntoThePreviousChunk() {
        let chunks = ChunkPlan.chunks(forDuration: 3310)

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].duration, 3310)
    }

    func testEmptyRecordingGivesNoChunks() {
        XCTAssertTrue(ChunkPlan.chunks(forDuration: 0).isEmpty)
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter ChunkPlanTests`
Expected: FAIL — `cannot find 'ChunkPlan' in scope`

- [ ] **Step 3: Написать реализацию**

Создать `Sources/CyclopMeetings/ChunkPlan.swift`:

```swift
import Foundation

/// How a long recording is split for transcription.
///
/// An hour of 32 kbps audio is 13 MB, which is 18 MB once base64-encoded,
/// against a request ceiling of about 20 MB. The threshold is therefore 55
/// minutes: the remaining slack is not enough to gamble a whole meeting on.
public struct ChunkPlan {
    public struct Chunk: Equatable, Sendable {
        public let start: TimeInterval
        public let duration: TimeInterval

        public init(start: TimeInterval, duration: TimeInterval) {
            self.start = start
            self.duration = duration
        }
    }

    public static let limit: TimeInterval = 3300

    /// A tail shorter than this is folded into the chunk before it: a
    /// one-second chunk costs a full request and returns nothing worth having.
    private static let minimumTail: TimeInterval = 60

    public static func chunks(forDuration duration: TimeInterval) -> [Chunk] {
        guard duration > 0 else { return [] }
        guard duration > limit else { return [Chunk(start: 0, duration: duration)] }

        var chunks: [Chunk] = []
        var start: TimeInterval = 0
        while start < duration {
            let remaining = duration - start
            if remaining <= limit + minimumTail {
                chunks.append(Chunk(start: start, duration: remaining))
                break
            }
            chunks.append(Chunk(start: start, duration: limit))
            start += limit
        }
        return chunks
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --filter ChunkPlanTests`
Expected: PASS, 6 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopMeetings/ChunkPlan.swift Tests/CyclopMeetingsTests/ChunkPlanTests.swift
git commit -m "Нарезка длинной записи на куски

Час аудио в 32 kbps весит 13 МБ, в base64 — 18 МБ при потолке запроса
около 20 МБ. Поэтому порог 55 минут, а не круглый час: оставшегося запаса
мало, чтобы рисковать целой встречей. Хвост короче минуты прирастает к
предыдущему куску — отдельный запрос ради секунды не окупается."
```

---

## Task 4: Слияние двух лент

**Files:**
- Create: `Sources/CyclopMeetings/TranscriptMerger.swift`
- Test: `Tests/CyclopMeetingsTests/TranscriptMergerTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment` из Task 1
- Produces: `public enum TranscriptMerger` с `public static func merge(microphone: [TranscriptSegment], system: [TranscriptSegment], ownerName: String) -> [TranscriptSegment]`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/CyclopMeetingsTests/TranscriptMergerTests.swift`:

```swift
import XCTest
@testable import CyclopMeetings

final class TranscriptMergerTests: XCTestCase {
    func testOwnerSpeechIsNamed() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 0, speaker: "Участник 1", text: "моя реплика")],
            system: [],
            ownerName: "Роман"
        )
        XCTAssertEqual(merged.map(\.speaker), ["Роман"])
    }

    func testBothLanesAreOrderedByTime() {
        let merged = TranscriptMerger.merge(
            microphone: [
                TranscriptSegment(start: 0, speaker: "Участник 1", text: "начнём"),
                TranscriptSegment(start: 20, speaker: "Участник 1", text: "согласен"),
            ],
            system: [
                TranscriptSegment(start: 10, speaker: "Участник 1", text: "смотрел логи"),
                TranscriptSegment(start: 30, speaker: "Участник 2", text: "я за откат"),
            ],
            ownerName: "Роман"
        )

        XCTAssertEqual(merged.map(\.start), [0, 10, 20, 30])
        XCTAssertEqual(merged.map(\.speaker), ["Роман", "Участник 1", "Роман", "Участник 2"])
    }

    /// Numbering comes from the model and only covers the system lane; the
    /// owner is not one of those numbers and must not shift them.
    func testSystemNumberingIsLeftAlone() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 5, speaker: "Участник 1", text: "моя")],
            system: [TranscriptSegment(start: 0, speaker: "Участник 3", text: "чужая")],
            ownerName: "Роман"
        )
        XCTAssertEqual(merged.map(\.speaker), ["Участник 3", "Роман"])
    }

    /// Two people talking over each other land on the same second. Order then
    /// has to be stable, and the owner goes first — it is his machine.
    func testSimultaneousSpeechPutsTheOwnerFirst() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 7, speaker: "Участник 1", text: "моя")],
            system: [TranscriptSegment(start: 7, speaker: "Участник 2", text: "чужая")],
            ownerName: "Роман"
        )
        XCTAssertEqual(merged.map(\.speaker), ["Роман", "Участник 2"])
    }

    func testMissingMicrophoneLaneStillGivesATranscript() {
        let merged = TranscriptMerger.merge(
            microphone: [],
            system: [TranscriptSegment(start: 0, speaker: "Участник 1", text: "одни они")],
            ownerName: "Роман"
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].speaker, "Участник 1")
    }

    /// An empty owner name in settings must not produce "**[00:00:00] :** …".
    func testEmptyOwnerNameFallsBackToALabel() {
        let merged = TranscriptMerger.merge(
            microphone: [TranscriptSegment(start: 0, speaker: "Участник 1", text: "моя")],
            system: [],
            ownerName: "   "
        )
        XCTAssertEqual(merged[0].speaker, "Я")
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter TranscriptMergerTests`
Expected: FAIL — `cannot find 'TranscriptMerger' in scope`

- [ ] **Step 3: Написать реализацию**

Создать `Sources/CyclopMeetings/TranscriptMerger.swift`:

```swift
import Foundation

/// Weaves the two lanes of a meeting into one transcript.
///
/// The microphone lane is the owner of the Mac and nobody else, so its label
/// is a fact rather than the model's guess. The system lane holds everyone
/// else, and its numbering is left exactly as the model produced it: renaming
/// "Участник 2" into "Участник 1" because the owner took the first slot would
/// break the correspondence between the numbers and the voices.
public enum TranscriptMerger {
    /// Used when the owner has not filled his name in settings. Better than an
    /// empty label, which would render as "**[00:00:00] :** …".
    private static let fallbackOwnerName = "Я"

    public static func merge(
        microphone: [TranscriptSegment],
        system: [TranscriptSegment],
        ownerName: String
    ) -> [TranscriptSegment] {
        let trimmed = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = trimmed.isEmpty ? fallbackOwnerName : trimmed

        let mine = microphone.map {
            TranscriptSegment(start: $0.start, speaker: owner, text: $0.text)
        }
        // Stable by construction: on an equal timecode the owner's line comes
        // first, because `mine` is enumerated before `system` and the sort
        // below only compares start times.
        return (mine + system).enumerated()
            .sorted { left, right in
                if left.element.start == right.element.start {
                    return left.offset < right.offset
                }
                return left.element.start < right.element.start
            }
            .map(\.element)
    }
}
```

- [ ] **Step 4: Убедиться, что тесты проходят**

Run: `swift test --filter TranscriptMergerTests`
Expected: PASS, 6 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopMeetings/TranscriptMerger.swift Tests/CyclopMeetingsTests/TranscriptMergerTests.swift
git commit -m "Слияние микрофонной и системной лент

Микрофонная дорожка — это владелец Mac и никто другой, поэтому её метка
факт, а не догадка модели. Нумерация системной ленты остаётся как есть:
переименовать «Участника 2» в «Участника 1» из-за того, что владелец занял
первое место, значило бы порвать связь номеров с голосами.

При совпадении таймкода владелец идёт первым, порядок устойчив."
```

---

## Task 5: Промпты и сборка документа

**Files:**
- Create: `Sources/CyclopMeetings/MeetingPrompts.swift`
- Create: `Sources/CyclopMeetings/TranscriptDocument.swift`
- Test: `Tests/CyclopMeetingsTests/TranscriptDocumentTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment` из Task 1
- Produces:
  - `public enum MeetingPrompts` с `public static let transcription: String`, `public static func summary(for transcript: String) -> String`
  - `public struct TranscriptDocument` с `public init(date: Date, duration: TimeInterval, videoFileName: String, summary: String, segments: [TranscriptSegment], hasMicrophoneLane: Bool)` и `public func render() -> String`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/CyclopMeetingsTests/TranscriptDocumentTests.swift`:

```swift
import XCTest
@testable import CyclopMeetings

final class TranscriptDocumentTests: XCTestCase {
    private func document(
        summary: String = "Обсудили релиз.",
        segments: [TranscriptSegment] = [
            TranscriptSegment(start: 0, speaker: "Роман", text: "Начнём."),
            TranscriptSegment(start: 5, speaker: "Участник 2", text: "Логи в Grafana."),
        ],
        hasMicrophoneLane: Bool = true
    ) -> TranscriptDocument {
        TranscriptDocument(
            date: Date(timeIntervalSince1970: 1_787_000_000),
            duration: 4623,
            videoFileName: "meeting.mp4",
            summary: summary,
            segments: segments,
            hasMicrophoneLane: hasMicrophoneLane
        )
    }

    func testHeaderCarriesDurationAndVideoName() {
        let text = document().render()
        XCTAssertTrue(text.contains("**Длительность:** 01:17:03"), text)
        XCTAssertTrue(text.contains("`meeting.mp4`"), text)
    }

    func testSummaryAndTranscriptSectionsArePresent() {
        let text = document().render()
        XCTAssertTrue(text.contains("## Итоги"), text)
        XCTAssertTrue(text.contains("Обсудили релиз."), text)
        XCTAssertTrue(text.contains("## Расшифровка"), text)
    }

    func testEverySegmentIsRenderedAsALine() {
        let text = document().render()
        XCTAssertTrue(text.contains("**[00:00:00] Роман:** Начнём."), text)
        XCTAssertTrue(text.contains("**[00:00:05] Участник 2:** Логи в Grafana."), text)
    }

    /// Without a microphone lane every label is the model's guess, and the
    /// reader has to know that before trusting the names.
    func testMissingMicrophoneLaneIsStated() {
        let text = document(hasMicrophoneLane: false).render()
        XCTAssertTrue(text.contains("своя дорожка не записалась"), text)
    }

    func testWorkingMicrophoneAddsNoWarning() {
        XCTAssertFalse(document().render().contains("своя дорожка не записалась"))
    }

    /// A failed summary request must not cost the transcript itself.
    func testEmptySummaryLeavesTheSectionOut() {
        let text = document(summary: "  ").render()
        XCTAssertFalse(text.contains("## Итоги"), text)
        XCTAssertTrue(text.contains("## Расшифровка"), text)
    }

    func testTranscriptionPromptAsksForTheParsedFormat() {
        XCTAssertTrue(MeetingPrompts.transcription.contains("**[ЧЧ:ММ:СС]"))
        XCTAssertTrue(MeetingPrompts.transcription.contains("Участник"))
    }

    func testSummaryPromptCarriesTheTranscript() {
        XCTAssertTrue(MeetingPrompts.summary(for: "лента встречи").contains("лента встречи"))
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter TranscriptDocumentTests`
Expected: FAIL — `cannot find 'TranscriptDocument' in scope`

- [ ] **Step 3: Написать промпты**

Создать `Sources/CyclopMeetings/MeetingPrompts.swift`:

```swift
import Foundation

/// What the model is asked for.
///
/// The vocabulary is the same one the local Whisper prompt carries, and for
/// the same reason: without it English technical terms come back
/// transliterated into Cyrillic. The filler rule spells the fillers out
/// instead of saying "remove filler words" — the general wording makes the
/// model rewrite whole sentences rather than clean them.
public enum MeetingPrompts {
    private static let vocabulary = """
        Английские термины, бренды и названия пиши на английском, без \
        транслита. Vocabulary: API, SDK, CLI, Claude, ChatGPT, Gemini, OpenAI, \
        Anthropic, Google, Telegram, Cyclop, GitHub, GitLab, pull request, \
        merge, commit, branch, rebase, deploy, staging, production, rollback, \
        hotfix, OAuth, JWT, JSON, YAML, REST, gRPC, GraphQL, Kubernetes, \
        Docker, Terraform, Grafana, Sentry, Postgres, Redis, Kafka, frontend, \
        backend, latency, throughput, Python, JavaScript, TypeScript, React.
        """

    public static let transcription = """
        Это запись рабочей встречи на русском языке. \(vocabulary)

        Расшифруй запись. Каждую реплику с новой строки в формате: \
        **[ЧЧ:ММ:СС] Участник N:** текст. Таймкод — время начала реплики от \
        начала записи. Разные голоса помечай разными номерами и держи \
        нумерацию одинаковой до конца записи.

        Убирай заполнители речи (э, э-э, м-м, ну, вот, короче, как бы, типа) \
        и оборванные самоповторы. Слова говорящего, порядок мыслей и \
        формулировки сохраняй как есть — это расшифровка, а не пересказ. \
        Верни только реплики, без вводных фраз.
        """

    public static func summary(for transcript: String) -> String {
        """
        Ниже расшифровка рабочей встречи. Составь короткие итоги: о чём \
        говорили и к чему пришли — несколько предложений, без воды.

        Затем раздел «### Решения» со списком принятых решений и \
        договорённостей: кто что делает и к какому сроку, если это \
        прозвучало. Если решений не было, раздел не добавляй.

        Пиши по-русски, английские термины оставляй на английском. Верни \
        только текст итогов, без заголовка «Итоги».

        Расшифровка:

        \(transcript)
        """
    }
}
```

- [ ] **Step 4: Написать сборку документа**

Создать `Sources/CyclopMeetings/TranscriptDocument.swift`:

```swift
import Foundation

/// The `transcript.md` that ends up next to the recording.
///
/// Assembled here rather than while writing to disk so the shape can be
/// checked without a file system, and so a failed summary costs only its own
/// section: the transcript is the part that cannot be produced again, and it
/// is written no matter what else went wrong.
public struct TranscriptDocument {
    private let date: Date
    private let duration: TimeInterval
    private let videoFileName: String
    private let summary: String
    private let segments: [TranscriptSegment]
    private let hasMicrophoneLane: Bool

    public init(
        date: Date,
        duration: TimeInterval,
        videoFileName: String,
        summary: String,
        segments: [TranscriptSegment],
        hasMicrophoneLane: Bool
    ) {
        self.date = date
        self.duration = duration
        self.videoFileName = videoFileName
        self.summary = summary
        self.segments = segments
        self.hasMicrophoneLane = hasMicrophoneLane
    }

    public func render() -> String {
        var lines: [String] = []

        lines.append("# Встреча \(Self.headerFormatter.string(from: date))")
        lines.append("")
        lines.append("**Длительность:** \(Self.clock(duration))  ")
        lines.append("**Запись:** `\(videoFileName)`")

        if !hasMicrophoneLane {
            lines.append("")
            lines.append(
                "> У этой встречи своя дорожка не записалась, поэтому всех "
                + "говорящих разделила модель — имена в ленте не проверены."
            )
        }

        let summaryText = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryText.isEmpty {
            lines.append("")
            lines.append("## Итоги")
            lines.append("")
            lines.append(summaryText)
        }

        lines.append("")
        lines.append("## Расшифровка")
        lines.append("")
        lines.append(contentsOf: segments.map(\.line))
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private static let headerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    private static func clock(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
```

- [ ] **Step 5: Убедиться, что тесты проходят**

Run: `swift test --filter TranscriptDocumentTests`
Expected: PASS, 8 тестов

- [ ] **Step 6: Коммит**

```bash
git add Sources/CyclopMeetings/MeetingPrompts.swift Sources/CyclopMeetings/TranscriptDocument.swift Tests/CyclopMeetingsTests/TranscriptDocumentTests.swift
git commit -m "Промпты и сборка transcript.md

Словарь тот же, что у локального whisper, и по той же причине: без него
английские термины возвращаются кириллицей. Заполнители перечислены
поимённо — общая формулировка «убирай слова-паразиты» заставляет модель
переписывать фразы вместо чистки.

Документ собирается в памяти, а не по дороге на диск: форму можно
проверить без файловой системы, а неудавшиеся итоги стоят только своего
раздела — лента пишется в любом случае, её заново не получить."
```

---

## Task 6: Папка встречи и её статус

**Files:**
- Create: `Sources/CyclopMeetings/MeetingFolder.swift`
- Create: `Sources/CyclopMeetings/MeetingState.swift`
- Test: `Tests/CyclopMeetingsTests/MeetingFolderTests.swift`

**Interfaces:**
- Consumes: ничего
- Produces:
  - `public struct MeetingFolder: Equatable, Sendable` с `public let url: URL`, `public let startedAt: Date`; `public init(root: URL, startedAt: Date)`; `public init?(existing: URL)`; свойства `public var videoURL: URL`, `public var microphoneURL: URL`, `public var transcriptURL: URL`, `public var stateURL: URL`; `public static let videoFileName = "meeting.mp4"`
  - `public enum MeetingState: String, Codable, Sendable { case recording, processing, ready, failed }`
  - `public struct MeetingStateFile: Codable, Sendable` с `public let state: MeetingState`, `public let duration: TimeInterval`, `public let failure: String?`; `public init(state:duration:failure:)`; `public func encoded() throws -> Data`; `public static func decode(_ data: Data) throws -> MeetingStateFile`

- [ ] **Step 1: Написать падающий тест**

Создать `Tests/CyclopMeetingsTests/MeetingFolderTests.swift`:

```swift
import XCTest
@testable import CyclopMeetings

final class MeetingFolderTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/Users/test/Meetings", isDirectory: true)
    private let startedAt = Date(timeIntervalSince1970: 1_787_000_000)

    func testFolderIsNamedByDateAndTime() {
        let folder = MeetingFolder(root: root, startedAt: startedAt)
        XCTAssertEqual(folder.url.lastPathComponent, "2026-08-28 07-33 Встреча")
    }

    func testFilesSitInsideTheFolder() {
        let folder = MeetingFolder(root: root, startedAt: startedAt)
        XCTAssertEqual(folder.videoURL.lastPathComponent, "meeting.mp4")
        XCTAssertEqual(folder.microphoneURL.lastPathComponent, "mic.m4a")
        XCTAssertEqual(folder.transcriptURL.lastPathComponent, "transcript.md")
        XCTAssertEqual(folder.stateURL.lastPathComponent, ".state.json")
        XCTAssertEqual(folder.videoURL.deletingLastPathComponent(), folder.url)
    }

    /// The list of past meetings is built by reading the folder names back.
    func testExistingFolderIsRecognisedByItsName() {
        let url = root.appendingPathComponent("2026-08-28 07-33 Встреча", isDirectory: true)
        let folder = MeetingFolder(existing: url)

        XCTAssertNotNil(folder)
        XCTAssertEqual(folder?.startedAt, startedAt)
        XCTAssertEqual(folder?.url, url)
    }

    func testUnrelatedFolderIsIgnored() {
        XCTAssertNil(MeetingFolder(existing: root.appendingPathComponent("Документы")))
        XCTAssertNil(MeetingFolder(existing: root.appendingPathComponent("2026-13-45 99-99 Встреча")))
    }

    func testStateSurvivesEncoding() throws {
        let file = MeetingStateFile(state: .processing, duration: 4623, failure: nil)
        let restored = try MeetingStateFile.decode(file.encoded())

        XCTAssertEqual(restored.state, .processing)
        XCTAssertEqual(restored.duration, 4623)
        XCTAssertNil(restored.failure)
    }

    func testFailureReasonSurvivesEncoding() throws {
        let file = MeetingStateFile(state: .failed, duration: 60, failure: "HTTP 502")
        XCTAssertEqual(try MeetingStateFile.decode(file.encoded()).failure, "HTTP 502")
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `swift test --filter MeetingFolderTests`
Expected: FAIL — `cannot find 'MeetingFolder' in scope`

- [ ] **Step 3: Написать реализацию папки**

Создать `Sources/CyclopMeetings/MeetingFolder.swift`:

```swift
import Foundation

/// Where one meeting lives on disk.
///
/// The date is carried by the folder name rather than by an index file: the
/// list of past meetings is then just a directory listing, and a folder moved
/// into Google Drive by hand stays readable. The name is also why the format
/// is fixed and parsed back — it is the only source of the start time.
public struct MeetingFolder: Equatable, Sendable {
    public static let videoFileName = "meeting.mp4"

    public let url: URL
    public let startedAt: Date

    public init(root: URL, startedAt: Date) {
        self.startedAt = startedAt
        self.url = root.appendingPathComponent(
            "\(Self.formatter.string(from: startedAt)) Встреча",
            isDirectory: true
        )
    }

    public init?(existing url: URL) {
        let name = url.lastPathComponent
        guard name.hasSuffix(" Встреча") else { return nil }
        let stamp = String(name.dropLast(" Встреча".count))
        guard let date = Self.formatter.date(from: stamp) else { return nil }
        self.url = url
        self.startedAt = date
    }

    public var videoURL: URL { url.appendingPathComponent(Self.videoFileName) }
    public var microphoneURL: URL { url.appendingPathComponent("mic.m4a") }
    public var transcriptURL: URL { url.appendingPathComponent("transcript.md") }
    public var stateURL: URL { url.appendingPathComponent(".state.json") }

    /// Fixed locale and time zone: the folder name is parsed back, so it must
    /// not depend on where the Mac happens to be set.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
```

- [ ] **Step 4: Написать реализацию статуса**

Создать `Sources/CyclopMeetings/MeetingState.swift`:

```swift
import Foundation

/// Where a meeting is in its life.
public enum MeetingState: String, Codable, Sendable {
    case recording
    case processing
    case ready
    case failed
}

/// The status file inside a meeting folder.
///
/// Kept on disk rather than in memory so that an app closed mid-processing can
/// pick the meeting back up on the next launch: the recording is already made
/// and losing it to a restart is not acceptable.
public struct MeetingStateFile: Codable, Sendable {
    public let state: MeetingState
    public let duration: TimeInterval
    public let failure: String?

    public init(state: MeetingState, duration: TimeInterval, failure: String? = nil) {
        self.state = state
        self.duration = duration
        self.failure = failure
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MeetingStateFile {
        try JSONDecoder().decode(MeetingStateFile.self, from: data)
    }
}
```

- [ ] **Step 5: Убедиться, что тесты проходят**

Run: `swift test --filter MeetingFolderTests`
Expected: PASS, 6 тестов

- [ ] **Step 6: Прогнать всю библиотеку**

Run: `swift test 2>&1 | grep -E "Executed .* tests"`
Expected: 85 прежних тестов плюс 33 новых, падений нет

- [ ] **Step 7: Коммит**

```bash
git add Sources/CyclopMeetings/MeetingFolder.swift Sources/CyclopMeetings/MeetingState.swift Tests/CyclopMeetingsTests/MeetingFolderTests.swift
git commit -m "Папка встречи и её статус

Дата живёт в имени папки, а не в индексном файле: список прошлых встреч
тогда просто листинг каталога, а папка, перенесённая в Google Drive
руками, остаётся читаемой. Формат имени фиксирован и разбирается обратно —
это единственный источник времени начала.

Статус лежит файлом внутри папки, чтобы приложение, закрытое посреди
обработки, подобрало встречу на следующем запуске: запись уже сделана, и
терять её из-за перезапуска нельзя."
```

---

## Task 7: Общий транспорт для распознавания

Диктовка и встречи шлют одно и то же — аудио с промптом в одну модель. Сейчас
это зашито внутрь `CloudTranscriber`; вторая копия разъедется при первой правке.

**Files:**
- Create: `Sources/Cyclop/Dictation/AudioTranscriptionClient.swift`
- Modify: `Sources/Cyclop/Dictation/CloudTranscriber.swift`
- Test: ручная проверка, шаг 4

**Interfaces:**
- Consumes: `CloudTranscription` из `CyclopDictation` (уже есть: `endpoint(host:model:)`, `requestBody(wav:prompt:)`, `transcript(from:)`, `failure(from:status:)`)
- Produces: `final class AudioTranscriptionClient` с `init()`, `func transcribe(audio: Data, prompt: String, model: String) async throws -> String`, `func complete(prompt: String, model: String) async throws -> String`; `static var host: String`, `static var isConfigured: Bool`; ошибки `enum Failure: LocalizedError { case notConfigured, upstream(String) }`
- Produces в `CyclopDictation`: `CloudTranscription.requestBody(prompt: String) throws -> Data` — то же тело, но без звука

- [ ] **Step 1: Научить библиотеку собирать запрос без звука**

Итоги — текстовый запрос: аудио уже расшифровано, модели отдаётся лента. Отправка
пустого `Data` вместо звука дала бы запрос с пустым `inline_data`, который модель
отвергает.

Добавить в `Sources/CyclopDictation/CloudTranscription.swift`:

```swift
    /// The same request without audio: the summary step sends a finished
    /// transcript as text, and an empty `inline_data` would be rejected.
    public static func requestBody(prompt: String) throws -> Data {
        let payload = Request(
            contents: [
                Request.Content(
                    role: "user",
                    parts: [.init(text: prompt, inlineData: nil)]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
```

Добавить в `Tests/CyclopDictationTests/CloudTranscriptionTests.swift`:

```swift
    func testTextOnlyRequestCarriesNoAudioPart() throws {
        let body = try CloudTranscription.requestBody(prompt: "составь итоги")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0]["text"] as? String, "составь итоги")
        XCTAssertNil(parts[0]["inline_data"])
    }
```

Run: `swift test --filter CloudTranscriptionTests`
Expected: PASS, 16 тестов

- [ ] **Step 2: Вынести транспорт в отдельный тип**

Создать `Sources/Cyclop/Dictation/AudioTranscriptionClient.swift`, перенеся в него
сетевую часть нынешнего `CloudTranscriber`:

```swift
import CyclopDictation
import Foundation

/// Sends audio to a Gemini-compatible endpoint and brings back text.
///
/// Shared by dictation and by meetings: both do the same thing — audio plus a
/// prompt into one model — and differ only in which prompt they send. Two
/// copies of this would drift apart at the first fix.
final class AudioTranscriptionClient {
    enum Failure: LocalizedError {
        case notConfigured
        case upstream(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "cloud recognition is not configured"
            case .upstream(let message): return message
            }
        }
    }

    /// Where the host lives. The token does not: `UserDefaults` writes a plist
    /// in the clear, and an API key has no business being there.
    static let hostKey = "cyclop.dictation.cloudHost"

    static var host: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }

    static var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !CloudCredentials.token.isEmpty
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // Only the handshake is bounded. An hour of audio takes minutes to
        // come back, and cutting that off mid-flight throws away work already
        // paid for.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 1800
        session = URLSession(configuration: configuration)
    }

    func transcribe(audio: Data, prompt: String, model: String) async throws -> String {
        guard let endpoint = CloudTranscription.endpoint(host: Self.host, model: model) else {
            throw Failure.notConfigured
        }
        return try await send(CloudTranscription.requestBody(wav: audio, prompt: prompt), to: endpoint)
    }

    /// A text-only round trip, used for the summary of an already finished
    /// transcript.
    func complete(prompt: String, model: String) async throws -> String {
        guard let endpoint = CloudTranscription.endpoint(host: Self.host, model: model) else {
            throw Failure.notConfigured
        }
        return try await send(CloudTranscription.requestBody(prompt: prompt), to: endpoint)
    }

    private func send(_ body: Data, to endpoint: URL) async throws -> String {
        let token = CloudCredentials.token
        guard !token.isEmpty else { throw Failure.notConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.upstream(CloudTranscription.failure(from: data, status: status))
        }
        return try CloudTranscription.transcript(from: data)
    }
}
```

- [ ] **Step 3: Свести CloudTranscriber к диктовке**

Заменить содержимое `Sources/Cyclop/Dictation/CloudTranscriber.swift` на обёртку
над общим клиентом, оставив в файле `CloudCredentials` без изменений:

```swift
import CyclopDictation
import Foundation

/// Dictation's use of the shared transcription client: one prompt, one model,
/// a wav file on disk.
final class CloudTranscriber {
    typealias Failure = AudioTranscriptionClient.Failure

    static var host: String {
        get { AudioTranscriptionClient.host }
        set { AudioTranscriptionClient.host = newValue }
    }

    static var isConfigured: Bool { AudioTranscriptionClient.isConfigured }

    private let client = AudioTranscriptionClient()

    func transcribe(wav url: URL) async throws -> String {
        try await client.transcribe(
            audio: Data(contentsOf: url),
            prompt: CloudTranscription.prompt,
            model: CloudTranscription.defaultModel
        )
    }
}
```

- [ ] **Step 4: Собрать и прогнать тесты**

Run: `swift build && swift test 2>&1 | grep -E "Executed .* tests"`
Expected: сборка без ошибок и предупреждений, все тесты проходят

- [ ] **Step 5: Проверить, что диктовка в облаке не сломалась**

Запустить `/build-install`, затем во вкладке диктовки выбрать Gemini и
продиктовать фразу с английским термином.
Expected: текст вставился, термин остался на английском, питон-воркер не
поднялся (`ps -Ao comm | grep python3.11` пусто)

- [ ] **Step 6: Коммит**

```bash
git add Sources/CyclopDictation/CloudTranscription.swift Tests/CyclopDictationTests/CloudTranscriptionTests.swift Sources/Cyclop/Dictation/AudioTranscriptionClient.swift Sources/Cyclop/Dictation/CloudTranscriber.swift
git commit -m "Транспорт распознавания вынесен в общий клиент

Диктовка и встречи делают одно и то же — шлют аудио с промптом в одну
модель — и различаются только промптом. Две копии сетевого кода разъехались
бы на первой же правке, поэтому он один, а CloudTranscriber остаётся
тонкой обёрткой для диктовки."
```

---

## Task 8: Запись экрана и звука

**Files:**
- Create: `Sources/Cyclop/Meetings/MeetingRecorder.swift`
- Modify: `Scripts/bundle.sh` (описание использования записи экрана)
- Test: ручная проверка, шаг 4

**Interfaces:**
- Consumes: `MeetingFolder` из Task 6
- Produces: `@MainActor final class MeetingRecorder` с `func start(into folder: MeetingFolder) async throws`, `func stop() async -> RecordingResult`; `struct RecordingResult { let duration: TimeInterval; let hasMicrophoneLane: Bool }`; `var isRecording: Bool`; `enum Failure: LocalizedError { case noDisplay, permissionDenied }`

- [ ] **Step 1: Добавить описание разрешения в Info.plist**

В `Scripts/bundle.sh`, в блок Info.plist приложения рядом с прочими
`NSUsageDescription`, добавить:

```
    <key>NSScreenCaptureUsageDescription</key>
    <string>Cyclop записывает экран и звук встречи, чтобы расшифровать её.</string>
```

- [ ] **Step 2: Написать рекордер**

Создать `Sources/Cyclop/Meetings/MeetingRecorder.swift`:

```swift
import AVFoundation
import CyclopMeetings
import ScreenCaptureKit

/// Captures the meeting: screen and system audio into one mp4, the microphone
/// into a file of its own.
///
/// Two files rather than one mixed track, because the microphone lane is the
/// owner of this Mac and nobody else — recorded apart, that label becomes a
/// fact instead of the model's guess.
@MainActor
final class MeetingRecorder: NSObject {
    struct RecordingResult {
        let duration: TimeInterval
        let hasMicrophoneLane: Bool
    }

    enum Failure: LocalizedError {
        case noDisplay
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "no display to record"
            case .permissionDenied: return "screen recording is not allowed"
            }
        }
    }

    private(set) var isRecording = false

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var microphoneWriter: AVAssetWriter?
    private var microphoneInput: AVAssetWriterInput?
    private var startedAt: Date?
    private var microphoneWroteSamples = false

    func start(into folder: MeetingFolder) async throws {
        guard !isRecording else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            // The permission dialog is the usual reason this throws: the
            // request is refused before it reaches us.
            throw Failure.permissionDenied
        }
        guard let display = content.displays.first else { throw Failure.noDisplay }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        // The microphone arrives as its own stream so it can be written apart.
        configuration.width = min(display.width, 1920)
        configuration.height = min(display.height, 1080)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = folder.videoURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .hevc
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: nil)
        try stream.addRecordingOutput(output)

        try prepareMicrophoneWriter(at: folder.microphoneURL)
        try stream.addStreamOutput(
            self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "cyclop.meeting.mic"))

        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = output
        self.startedAt = Date()
        self.isRecording = true
    }

    func stop() async -> RecordingResult {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        isRecording = false

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        recordingOutput = nil

        microphoneInput?.markAsFinished()
        if let writer = microphoneWriter {
            await writer.finishWriting()
        }
        let hadMicrophone = microphoneWroteSamples
        microphoneWriter = nil
        microphoneInput = nil
        microphoneWroteSamples = false
        startedAt = nil

        return RecordingResult(duration: duration, hasMicrophoneLane: hadMicrophone)
    }

    private func prepareMicrophoneWriter(at url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000,
            ]
        )
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        microphoneWriter = writer
        microphoneInput = input
    }
}

extension MeetingRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .microphone, sampleBuffer.isValid else { return }
        Task { @MainActor in
            self.appendMicrophone(sampleBuffer)
        }
    }
}

private extension MeetingRecorder {
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard let writer = microphoneWriter, let input = microphoneInput else { return }

        if writer.status == .unknown {
            writer.startWriting()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            microphoneWroteSamples = true
        }
    }
}
```

- [ ] **Step 3: Собрать**

Run: `swift build`
Expected: сборка без ошибок и предупреждений

- [ ] **Step 4: Проверить запись живьём**

Временно вызвать `start`/`stop` из вкладки диктовки или из `applicationDidFinishLaunching`,
собрать через `/build-install`, записать 30 секунд с играющей музыкой и словами в
микрофон, затем проверить результат:

```bash
ls -la "<корень>"/*/
ffprobe -hide_banner "<корень>/<папка>/meeting.mp4" 2>&1 | grep Stream
ffprobe -hide_banner "<корень>/<папка>/mic.m4a" 2>&1 | grep Stream
```

Expected: `meeting.mp4` содержит видео hevc и аудио, `mic.m4a` содержит аудио,
оба открываются в QuickTime, размер mp4 порядка 10–20 МБ за 30 секунд

- [ ] **Step 5: Коммит**

```bash
git add Sources/Cyclop/Meetings/MeetingRecorder.swift Scripts/bundle.sh
git commit -m "Запись экрана и звука встречи

Пишутся два файла, а не один смикшированный: микрофонная дорожка — это
владелец Mac и никто другой, и записанная отдельно она превращает метку
«я» в факт вместо догадки модели.

Микрофон приезжает отдельным потоком ScreenCaptureKit и уходит в свой
AVAssetWriter. Флаг microphoneWroteSamples отвечает на вопрос, была ли
дорожка вообще: без него встреча с занятым микрофоном молча получила бы
пустой файл."
```

---

## Task 9: Подготовка аудио к отправке

**Files:**
- Create: `Sources/Cyclop/Meetings/MeetingAudio.swift`
- Test: ручная проверка, шаг 3

**Interfaces:**
- Consumes: `ChunkPlan` из Task 3
- Produces: `enum MeetingAudio` с `static func duration(of url: URL) async throws -> TimeInterval`, `static func compressed(from url: URL, chunk: ChunkPlan.Chunk, to destination: URL) async throws`, `static func hasAudioTrack(_ url: URL) async -> Bool`

- [ ] **Step 1: Написать подготовку аудио**

Создать `Sources/Cyclop/Meetings/MeetingAudio.swift`:

```swift
import AVFoundation
import CyclopMeetings

/// Turns a recording into something small enough to send.
///
/// 32 kbps mono: an hour of it is 13 MB, 18 MB once base64-encoded, which fits
/// under the request ceiling with the margin `ChunkPlan` counts on. Quality
/// beyond that buys nothing — the model reads speech, not music.
enum MeetingAudio {
    private static let bitRate = 32_000
    private static let sampleRate = 16_000

    static func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.duration).seconds
    }

    static func hasAudioTrack(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = try? await asset.loadTracks(withMediaType: .audio)
        return !(tracks ?? []).isEmpty
    }

    /// Reads one chunk out of the source and writes it compressed.
    ///
    /// Export rather than a raw copy: the source is HEVC video with AAC audio
    /// at full rate, and sending that whole would blow the request ceiling on
    /// anything longer than a few minutes.
    static func compressed(
        from url: URL,
        chunk: ChunkPlan.Chunk,
        to destination: URL
    ) async throws {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }

        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: chunk.start, preferredTimescale: 600),
            duration: CMTime(seconds: chunk.duration, preferredTimescale: 600)
        )
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ]
        )
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "cyclop.meeting.audio")
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard let buffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                    writerInput.append(buffer)
                }
            }
        }
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
```

- [ ] **Step 2: Собрать**

Run: `swift build`
Expected: сборка без ошибок

- [ ] **Step 3: Проверить сжатие на настоящей записи**

Взять `meeting.mp4` из проверки Task 8 и прогнать через временный вызов
`MeetingAudio.compressed(from:chunk:to:)` с `ChunkPlan.Chunk(start: 0, duration: 30)`.

```bash
ls -la /tmp/chunk.m4a
ffprobe -hide_banner /tmp/chunk.m4a 2>&1 | grep -E "Stream|Duration"
```

Expected: файл около 120 КБ за 30 секунд (32 kbps), одна дорожка aac 16000 Hz mono,
длительность 30 секунд, файл слушается

- [ ] **Step 4: Коммит**

```bash
git add Sources/Cyclop/Meetings/MeetingAudio.swift
git commit -m "Подготовка аудио встречи к отправке

32 kbps mono: час такого весит 13 МБ, в base64 — 18 МБ, что укладывается
под потолок запроса с запасом, на который рассчитывает ChunkPlan. Качество
сверх этого не покупает ничего: модель читает речь, а не музыку.

Не сырое копирование, а пережатие с вырезкой куска — исходник это HEVC с
AAC на полном битрейте, и целиком он пролезал бы только на коротких
встречах."
```

---

## Task 10: Пайплайн обработки

**Files:**
- Create: `Sources/Cyclop/Meetings/MeetingProcessor.swift`
- Test: ручная проверка, шаг 3

**Interfaces:**
- Consumes: `MeetingFolder`, `MeetingStateFile`, `ChunkPlan`, `TranscriptParser`, `TranscriptMerger`, `TranscriptDocument`, `MeetingPrompts` (Tasks 1–6); `AudioTranscriptionClient` (Task 7); `MeetingAudio` (Task 9)
- Produces: `final class MeetingProcessor` с `init(client: AudioTranscriptionClient = .init())`, `func process(_ folder: MeetingFolder, duration: TimeInterval, hasMicrophoneLane: Bool, ownerName: String, progress: @escaping @Sendable (String) -> Void) async throws`; `static let model = "gemini-3.7-flash-high"`

- [ ] **Step 1: Написать пайплайн**

Создать `Sources/Cyclop/Meetings/MeetingProcessor.swift`:

```swift
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

        let chunks = ChunkPlan.chunks(forDuration: duration)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyclop-meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let system = try await transcribe(
            source: folder.videoURL, chunks: chunks, scratch: scratch,
            label: "system", progress: progress)

        var microphone: [TranscriptSegment] = []
        if hasMicrophoneLane, await MeetingAudio.hasAudioTrack(folder.microphoneURL) {
            microphone = try await transcribe(
                source: folder.microphoneURL, chunks: chunks, scratch: scratch,
                label: "mic", progress: progress)
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
        chunks: [ChunkPlan.Chunk],
        scratch: URL,
        label: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> [TranscriptSegment] {
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
```

- [ ] **Step 2: Собрать**

Run: `swift build`
Expected: сборка без ошибок

- [ ] **Step 3: Проверить пайплайн на короткой записи**

Через временный вызов из вкладки диктовки прогнать 30-секундную запись из Task 8.

```bash
cat "<корень>/<папка>/transcript.md"
cat "<корень>/<папка>/.state.json"
```

Expected: в md есть шапка с длительностью, раздел «Итоги», раздел «Расшифровка»
с репликами и таймкодами; в `.state.json` статус `ready`

- [ ] **Step 4: Коммит**

```bash
git add Sources/Cyclop/Meetings/MeetingProcessor.swift
git commit -m "Пайплайн обработки встречи

Порядок такой, чтобы незаменимое пережило заменимое: расшифровка пишется
даже если запрос итогов упал. Запись заново не сделать, встреча без итогов
всё ещё полезна, а итоги без расшифровки — нет.

Сдвиг таймкодов ставится здесь, а не выпрашивается у модели: каждый кусок
считает время от собственного нуля."
```

---

## Task 11: Состояние вкладки и детект звонка

**Files:**
- Create: `Sources/Cyclop/Meetings/CallDetector.swift`
- Create: `Sources/Cyclop/Meetings/MeetingsController.swift`
- Test: ручная проверка, шаг 4

**Interfaces:**
- Consumes: `MeetingRecorder` (Task 8), `MeetingProcessor` (Task 10), `MeetingFolder`, `MeetingStateFile` (Task 6)
- Produces:
  - `final class CallDetector` с `init(onCallStarted: @escaping @MainActor () -> Void)`, `func start()`, `func stop()`
  - `@MainActor final class MeetingsController: ObservableObject` с `@Published private(set) var state: State`, `@Published private(set) var meetings: [Meeting]`, `@Published private(set) var offer: Bool`, `func toggleRecording()`, `func acceptOffer()`, `func dismissOffer()`, `func retry(_ meeting: Meeting)`, `func reveal(_ meeting: Meeting)`, `func openTranscript(_ meeting: Meeting)`, `func refresh()`; `enum State: Equatable { case idle, recording(since: Date), processing(String) }`; `struct Meeting: Identifiable, Equatable { let id: URL; let folder: MeetingFolder; let state: MeetingState; let duration: TimeInterval; let failure: String? }`; статические настройки `static var rootFolder: URL`, `static var ownerName: String`

- [ ] **Step 1: Написать детект звонка**

Создать `Sources/Cyclop/Meetings/CallDetector.swift`:

```swift
import CoreAudio
import Foundation

/// Notices that some app started listening to the microphone.
///
/// Watches the device rather than a process list, so Telegram, Zoom and a call
/// in the browser all look the same. Deliberately dumb in this stage: the
/// smart part — not offering twice, telling a call from a voice message —
/// belongs to the stage that adds automatic recording.
final class CallDetector {
    /// A call is a conversation, not a two-second voice message; half a minute
    /// of a busy microphone is the cheapest way to tell them apart.
    private static let threshold: TimeInterval = 30

    private let onCallStarted: @MainActor () -> Void
    private var timer: Timer?
    private var busySince: Date?
    private var alreadyOffered = false

    init(onCallStarted: @escaping @MainActor () -> Void) {
        self.onCallStarted = onCallStarted
    }

    func start() {
        guard timer == nil else { return }
        // Polling rather than a property listener: the callback arrives on a
        // CoreAudio thread and the state here is read from the main one, so a
        // five-second tick is both simpler and enough for a 30-second rule.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        busySince = nil
        alreadyOffered = false
    }

    private func tick() {
        guard Self.isMicrophoneBusy() else {
            busySince = nil
            alreadyOffered = false
            return
        }
        guard !alreadyOffered else { return }

        guard let since = busySince else {
            busySince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= Self.threshold else { return }

        alreadyOffered = true
        Task { @MainActor in self.onCallStarted() }
    }

    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` answers for the device as
    /// a whole — which is exactly the question here.
    private static func isMicrophoneBusy() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return false }

        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &runningAddress, 0, nil, &runningSize, &running
        ) == noErr else { return false }

        return running == 1
    }
}
```

- [ ] **Step 2: Написать контроллер**

Создать `Sources/Cyclop/Meetings/MeetingsController.swift`:

```swift
import AppKit
import CyclopMeetings
import Foundation

/// What the meetings tab shows and what the notch indicator reads.
@MainActor
final class MeetingsController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case processing(String)
    }

    struct Meeting: Identifiable, Equatable {
        let id: URL
        let folder: MeetingFolder
        let state: MeetingState
        let duration: TimeInterval
        let failure: String?
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

    private let recorder = MeetingRecorder()
    private let processor = MeetingProcessor()
    private var detector: CallDetector?
    private var current: MeetingFolder?
    private var offerTimer: Timer?

    var isRecording: Bool { if case .recording = state { return true }; return false }

    func start() {
        refresh()
        detector = CallDetector { [weak self] in self?.showOffer() }
        detector?.start()
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
        let folder = MeetingFolder(root: Self.rootFolder, startedAt: Date())
        Task {
            do {
                try FileManager.default.createDirectory(
                    at: folder.url, withIntermediateDirectories: true)
                try await recorder.start(into: folder)
                current = folder
                state = .recording(since: Date())
                try? MeetingStateFile(state: .recording, duration: 0)
                    .encoded().write(to: folder.stateURL, options: .atomic)
                refresh()
            } catch {
                NSLog("Cyclop: meeting recording failed to start (%@)", error.localizedDescription)
                try? FileManager.default.removeItem(at: folder.url)
                state = .idle
            }
        }
    }

    private func stopRecording() {
        guard let folder = current else { return }
        current = nil
        Task {
            let result = await recorder.stop()
            state = .processing("подготовка")
            refresh()
            do {
                try await processor.process(
                    folder,
                    duration: result.duration,
                    hasMicrophoneLane: result.hasMicrophoneLane,
                    ownerName: Self.ownerName,
                    progress: { [weak self] step in
                        Task { @MainActor in self?.state = .processing(step) }
                    }
                )
            } catch {
                NSLog("Cyclop: meeting processing failed (%@)", error.localizedDescription)
                processor.markFailed(
                    folder, duration: result.duration, reason: error.localizedDescription)
            }
            state = .idle
            refresh()
        }
    }

    func retry(_ meeting: Meeting) {
        Task {
            state = .processing("подготовка")
            do {
                try await processor.process(
                    meeting.folder,
                    duration: meeting.duration,
                    hasMicrophoneLane: FileManager.default.fileExists(
                        atPath: meeting.folder.microphoneURL.path),
                    ownerName: Self.ownerName,
                    progress: { [weak self] step in
                        Task { @MainActor in self?.state = .processing(step) }
                    }
                )
            } catch {
                processor.markFailed(
                    meeting.folder, duration: meeting.duration,
                    reason: error.localizedDescription)
            }
            state = .idle
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
            at: root, includingPropertiesForKeys: nil)) ?? []

        meetings = contents
            .compactMap { MeetingFolder(existing: $0) }
            .map { folder in
                let file = (try? Data(contentsOf: folder.stateURL))
                    .flatMap { try? MeetingStateFile.decode($0) }
                return Meeting(
                    id: folder.url,
                    folder: folder,
                    state: file?.state ?? .ready,
                    duration: file?.duration ?? 0,
                    failure: file?.failure
                )
            }
            .sorted { $0.folder.startedAt > $1.folder.startedAt }
    }
}
```

- [ ] **Step 3: Собрать**

Run: `swift build`
Expected: сборка без ошибок и предупреждений

- [ ] **Step 4: Проверить детект**

Собрать через `/build-install`, начать звонок в Telegram или включить запись
голосового на полминуты.
Expected: через 30 секунд занятого микрофона в логе появляется вызов
`showOffer` (проверяется на этом шаге через `NSLog`, карточка рисуется в Task 12)

- [ ] **Step 5: Коммит**

```bash
git add Sources/Cyclop/Meetings/CallDetector.swift Sources/Cyclop/Meetings/MeetingsController.swift
git commit -m "Состояние вкладки встреч и детект звонка

Детект смотрит на устройство, а не на список процессов, поэтому Telegram,
Zoom и звонок в браузере выглядят одинаково. Порог в полминуты отделяет
разговор от голосового сообщения. Умная часть — не предлагать дважды,
различать приложения — остаётся этапу автозапуска.

Список встреч это листинг каталога: индекс нечего синхронизировать, а
папка, перенесённая руками, появляется сама."
```

---

## Task 12: Вкладка, индикатор и карточка предложения

**Files:**
- Create: `Sources/Cyclop/UI/MeetingsPane.swift`
- Create: `Sources/Cyclop/UI/RecordingOffer.swift`
- Modify: `Sources/Cyclop/Model/NotchViewModel.swift`
- Modify: `Sources/Cyclop/UI/NotchContentView.swift`
- Modify: `Sources/Cyclop/UI/SettingsPane.swift`
- Modify: `Resources/ru.lproj/Localizable.strings`, `Resources/en.lproj/Localizable.strings`
- Modify: `AGENTS.md`
- Test: ручная проверка, шаг 7

**Interfaces:**
- Consumes: `MeetingsController` из Task 11
- Produces: вкладка `.meetings` в `NotchViewModel.Tab`, `vm.meetings: MeetingsController`

- [ ] **Step 1: Завести вкладку в модели панели**

В `Sources/Cyclop/Model/NotchViewModel.swift`:

- в `enum Tab` добавить `meetings` перед `settings`;
- в `symbol` добавить `case .meetings: return "record.circle"`;
- в `title` добавить `case .meetings: return localized("Meetings")`;
- рядом с `let dictation` объявить `let meetings = MeetingsController()`;
- там же, где стартует диктовка, вызвать `meetings.start()`.

- [ ] **Step 2: Написать карточку предложения**

Создать `Sources/Cyclop/UI/RecordingOffer.swift`:

```swift
import SwiftUI

/// The "record this call?" card that drops out of the notch.
///
/// Drawn inside the panel rather than as a notification so it reads as Cyclop
/// itself: a system banner would be one more thing to dismiss, and it would
/// appear away from the indicator that follows it.
struct RecordingOffer: View {
    let accept: () -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.9))
            Text("Идёт звонок. Записать?")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Button(action: accept) {
                Text("Записать")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Button(action: dismiss) {
                Text("Не сейчас")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .top).combined(with: .opacity)
        )
        .onAppear {
            // The only tactile channel a Mac has: on a MacBook this lands in
            // the trackpad, which is exactly where the hand already is.
            NSHapticFeedbackManager.defaultPerformer.perform(
                .levelChange, performanceTime: .now)
        }
    }
}
```

- [ ] **Step 3: Написать вкладку**

Создать `Sources/Cyclop/UI/MeetingsPane.swift`:

```swift
import CyclopMeetings
import SwiftUI

/// Recording controls above the list of past meetings.
struct MeetingsPane: View {
    @ObservedObject var meetings: MeetingsController

    var body: some View {
        VStack(spacing: 6) {
            control
            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(meetings.meetings) { meeting in
                        row(meeting)
                    }
                }
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { meetings.refresh() }
    }

    @ViewBuilder
    private var control: some View {
        switch meetings.state {
        case .idle:
            button(title: localized("Record meeting"), symbol: "record.circle", tint: .red) {
                meetings.toggleRecording()
            }
        case .recording(let since):
            button(title: localized("Stop"), symbol: "stop.circle", tint: .red) {
                meetings.toggleRecording()
            }
            .overlay(alignment: .trailing) {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.clock(context.date.timeIntervalSince(since)))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                        .padding(.trailing, 10)
                }
            }
        case .processing(let step):
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("\(localized("Processing")) — \(step)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .frame(height: 30)
        }
    }

    private func button(
        title: String, symbol: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ meeting: MeetingsController.Meeting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: meeting.state))
                .font(.system(size: 11))
                .foregroundStyle(meeting.state == .failed ? Color.orange : Theme.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.dateFormatter.string(from: meeting.folder.startedAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                Text(detail(for: meeting))
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if meeting.state == .failed {
                Button(action: { meetings.retry(meeting) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Try again"))
            }
            Button(action: { meetings.reveal(meeting) }) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(localized("Show in Finder"))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
        .contentShape(Rectangle())
        .onTapGesture {
            if meeting.state == .ready { meetings.openTranscript(meeting) }
        }
    }

    private func symbol(for state: MeetingState) -> String {
        switch state {
        case .recording: return "record.circle"
        case .processing: return "clock"
        case .ready: return "doc.text"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func detail(for meeting: MeetingsController.Meeting) -> String {
        if let failure = meeting.failure { return failure }
        switch meeting.state {
        case .ready: return Self.clock(meeting.duration)
        case .processing: return localized("Processing")
        case .recording: return localized("Recording")
        case .failed: return localized("Did not work out")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.dateFormat = "d MMMM, HH:mm"
        return formatter
    }()

    private static func clock(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
```

- [ ] **Step 4: Вставить вкладку, индикатор и карточку в панель**

В `Sources/Cyclop/UI/NotchContentView.swift`:

- в `switch vm.tab` содержимого добавить `case .meetings: MeetingsPane(meetings: vm.meetings)`;
- в `trailing` добавить индикатор записи:

```swift
        case .meetings:
            recordingIndicator
```

- добавить сам индикатор рядом с прочими вспомогательными свойствами:

```swift
    /// Recording shows in the collapsed panel regardless of the open tab: it
    /// is the one state worth interrupting anything else for, and stopping it
    /// must not require opening the panel first.
    @ViewBuilder
    private var recordingIndicator: some View {
        if case .recording(let since) = vm.meetings.state {
            HStack(spacing: 5) {
                Button { vm.meetings.toggleRecording() } label: {
                    Image(systemName: hoveringIndicator ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .symbolEffect(.breathe, isActive: !hoveringIndicator && !reduceMotion)
                }
                .buttonStyle(.plain)
                .onHover { hoveringIndicator = $0 }
                .help(localized("Stop"))
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.clock(context.date.timeIntervalSince(since)))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private static func clock(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
```

- объявить рядом с прочими состояниями вида:

```swift
    @State private var hoveringIndicator = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
```

- под `header`, до `content`, вставить карточку:

```swift
                if vm.meetings.offer {
                    RecordingOffer(
                        accept: { vm.meetings.acceptOffer() },
                        dismiss: { vm.meetings.dismissOffer() }
                    )
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : .bouncy, value: vm.meetings.offer)
                }
```

- [ ] **Step 5: Добавить настройки**

В `Sources/Cyclop/UI/SettingsPane.swift` рядом с разделом «Диктовка в облаке»
добавить раздел встреч, используя уже имеющийся `fieldRow`:

```swift
                section(localized("Meetings")) {
                    actionRow(
                        symbol: "folder",
                        title: localized("Meetings folder"),
                        detail: MeetingsController.rootFolder.lastPathComponent
                    ) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = MeetingsController.rootFolder
                        if panel.runModal() == .OK, let url = panel.url {
                            MeetingsController.rootFolder = url
                        }
                    }
                    fieldRow(
                        symbol: "person",
                        title: localized("My name"),
                        placeholder: localized("signs your lines"),
                        text: $ownerName,
                        secure: false
                    ) {
                        MeetingsController.ownerName = ownerName
                    }
                }
```

Рядом с прочими `@State` объявить `@State private var ownerName = MeetingsController.ownerName`,
а в `onAppear` добавить `ownerName = MeetingsController.ownerName`.

- [ ] **Step 6: Добавить строки локализации**

В `Resources/ru.lproj/Localizable.strings`:

```
"Meetings" = "Встречи";
"Record meeting" = "Записать встречу";
"Stop" = "Остановить";
"Processing" = "Обработка";
"Recording" = "Идёт запись";
"Did not work out" = "Не получилось";
"Try again" = "Повторить";
"Show in Finder" = "Показать в Finder";
"Meetings folder" = "Папка встреч";
"My name" = "Моё имя";
"signs your lines" = "подписывает твои реплики";
"Идёт звонок. Записать?" = "Идёт звонок. Записать?";
"Записать" = "Записать";
"Не сейчас" = "Не сейчас";
```

В `Resources/en.lproj/Localizable.strings`:

```
"Meetings" = "Meetings";
"Record meeting" = "Record meeting";
"Stop" = "Stop";
"Processing" = "Processing";
"Recording" = "Recording";
"Did not work out" = "Did not work out";
"Try again" = "Try again";
"Show in Finder" = "Show in Finder";
"Meetings folder" = "Meetings folder";
"My name" = "My name";
"signs your lines" = "signs your lines";
"Идёт звонок. Записать?" = "A call is going on. Record it?";
"Записать" = "Record";
"Не сейчас" = "Not now";
```

Заменить в `RecordingOffer.swift` литералы на `localized(...)` с этими ключами.

- [ ] **Step 7: Проверить сборку, тесты и локализацию**

```bash
swift build
swift test 2>&1 | grep -E "Executed .* tests"
```
Expected: сборка без предупреждений, все тесты проходят

Прогнать `/localization-check`.
Expected: ключей в ru и en поровну, расхождений нет

- [ ] **Step 8: Проверить фичу целиком**

Собрать через `/build-install`, затем:

1. Настройки → выбрать папку встреч и вписать имя
2. Вкладка «Встречи» → «Записать встречу», разрешить запись экрана
3. Поговорить полминуты, включив на Mac любой звук с речью
4. Свернуть панель — убедиться, что точка дышит и таймер идёт
5. Навести на точку — она превращается в «стоп», нажать
6. Дождаться обработки, открыть `transcript.md`

Expected: в папке лежат `meeting.mp4`, `mic.m4a`, `transcript.md`, `.state.json`;
в md шапка, итоги и лента с таймкодами; твои реплики подписаны именем из настроек

- [ ] **Step 9: Записать грабли в AGENTS.md**

В раздел «Грабли этого проекта» добавить то, что выяснилось при реализации:
поведение `SCRecordingOutput`, работу с микрофонным потоком, всё, что стоило
отдельного круга отладки. В раздел «Структура» добавить `Sources/CyclopMeetings/`
и `Sources/Cyclop/Meetings/`.

- [ ] **Step 10: Коммит**

```bash
git add Sources/Cyclop/UI Sources/Cyclop/Model/NotchViewModel.swift Resources AGENTS.md
git commit -m "Вкладка встреч, индикатор записи и карточка предложения

Карточка рисуется внутри панели, а не системным уведомлением: так она
читается как сам Cyclop, её не надо отдельно закрывать, и она появляется
там же, где потом живёт индикатор.

Индикатор виден в свёрнутой панели независимо от открытой вкладки — это
единственное состояние, ради которого стоит перебивать всё остальное, и
останавливать запись, раскрывая панель, было бы лишним шагом. Точка дышит,
а не мигает: мигание в углу экрана через десять минут невыносимо."
```

---

## Self-Review

**Покрытие спека.** Каждое решение спека закрыто задачей: формат mp4/HEVC и
1080p — Task 8; две дорожки раздельно — Tasks 8 и 4; модель и промпты — Tasks 5
и 10; таймкоды и их сдвиг — Tasks 1, 2, 10; порог 55 минут — Task 3; папка на
встречу и корень в настройках — Tasks 6 и 12; вкладка — Task 12; статус в
`.state.json` и продолжение после перезапуска — Tasks 6 и 11; карточка,
индикатор, Reduce Motion — Task 12; детект микрофона — Task 11; разрешение на
запись экрана — Task 8; общий транспорт — Task 7; тестирование библиотеки —
Tasks 1–6.

**Не закрыто намеренно:** фрагментированный mp4 из раздела ошибок спека.
`SCRecordingOutput` пишет фрагментированный файл сам, и отдельного шага это не
требует — но если проверка Task 8 покажет, что оборванный файл не открывается,
в Task 8 добавляется свой `AVAssetWriter` с
`shouldOptimizeForNetworkUse = true`.

**Имена сверены между задачами:** `TranscriptSegment.shifted(by:)` (Task 1)
используется в Task 10; `ChunkPlan.Chunk` (Task 3) — в Tasks 9 и 10;
`TranscriptMerger.merge(microphone:system:ownerName:)` (Task 4) — в Task 10;
`MeetingFolder.videoFileName` (Task 6) — в Task 10;
`AudioTranscriptionClient.transcribe(audio:prompt:model:)` (Task 7) — в Task 10;
`MeetingAudio.compressed(from:chunk:to:)` (Task 9) — в Task 10;
`MeetingsController.rootFolder` и `.ownerName` (Task 11) — в Task 12.

**Правка по итогам самопроверки:** итоги сначала запрашивались через
`transcribe(audio: Data(), …)` — то есть запросом с пустым `inline_data`, который
модель отвергает. Task 7 получил отдельный метод `complete(prompt:model:)` и
сборку тела без звука в библиотеке, Task 10 зовёт его.

**Заглушек нет:** каждый шаг несёт код или точную команду с ожидаемым
результатом.
