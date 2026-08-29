# Кадры из видео и участники встречи — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `transcript.md` получает блоки с содержимым экрана в местах, где сказанное неполно без картинки, и имена участников вместо «Участник N».

**Architecture:** Логика отбора, разбора и сведения живёт в `CyclopMeetings` и тестируется без сети и без видео. Работа с файлами и AVFoundation — в `Sources/Cyclop/Meetings/`. `MeetingProcessor` получает четыре новые стадии после расшифровки; UI не меняется.

**Tech Stack:** Swift 6, SwiftPM, XCTest, AVFoundation (`AVAssetImageGenerator`), CoreGraphics, Gemini-совместимый эндпоинт через `AudioTranscriptionClient`.

**Spec:** `docs/superpowers/specs/2026-08-29-meetings-frames-participants-design.md`

## Global Constraints

- **Комментарии в коде — по-английски.** Объясняют причину решения, а не пересказывают код.
- **Сообщения коммитов — по-русски.**
- **Никаких новых зависимостей.** ffmpeg отвергнут ядром (~100 МБ в бандл), кадры достаёт `AVAssetImageGenerator`.
- **Тесты — XCTest**, рядом с существующими в `Tests/CyclopMeetingsTests/`. Сейчас в проекте 128 тестов Swift, все должны продолжать проходить.
- **Проверка:** `swift build && swift test`.
- **Модель — одна для всего:** `CloudTranscription.defaultModel`, второго литерала в коде не заводить.
- **Парсеры ответов модели — forgiving**, по образцу `TranscriptParser`: модель дрейфует от заданной формы, и разбор обязан переживать пропавшие звёздочки, лишнюю вводную строку и отсутствующие поля.
- **Файлы пользователя не трогать.** Записи и история диктовок — только копии во временной папке.
- **Бюджет кадров по умолчанию** — один на 4 минуты записи, минимум 3, максимум 40.

---

### Task 1: Кандидаты на кадры

Тип момента-кандидата, промпт, который просит модель их найти, и разбор ответа.

**Files:**
- Create: `Sources/CyclopMeetings/FrameCandidate.swift`
- Modify: `Sources/CyclopMeetings/MeetingPrompts.swift`
- Test: `Tests/CyclopMeetingsTests/FrameCandidateTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment` (существует).
- Produces: `FrameCandidate(start:expectation:priority:)`, `FrameCandidateParser.candidates(from:) -> [FrameCandidate]`, `MeetingPrompts.frameCandidates(for:budget:) -> String`.

- [ ] **Step 1: Написать падающий тест**

```swift
import XCTest
@testable import CyclopMeetings

final class FrameCandidateTests: XCTestCase {
    func testParsesTimecodePriorityAndExpectation() {
        let text = "[00:30:00] 1 | консоль Yandex Cloud, список подов кластера"

        XCTAssertEqual(
            FrameCandidateParser.candidates(from: text),
            [FrameCandidate(start: 1800, expectation: "консоль Yandex Cloud, список подов кластера", priority: 1)]
        )
    }

    /// The model adds an introductory sentence about as often as it does not.
    func testSkipsLinesWithoutTimecode() {
        let text = """
            Вот моменты, где нужен кадр:
            [00:07:55] 2 | схема C4 в PlantUML
            """

        XCTAssertEqual(FrameCandidateParser.candidates(from: text).count, 1)
    }

    /// A missing priority is not worth losing the candidate over.
    func testDefaultsPriorityToLowestWhenAbsent() {
        let candidates = FrameCandidateParser.candidates(from: "[00:01:00] | что-то на экране")

        XCTAssertEqual(candidates.first?.priority, 3)
    }

    func testSkipsCandidateWithEmptyExpectation() {
        XCTAssertTrue(FrameCandidateParser.candidates(from: "[00:01:00] 1 | ").isEmpty)
    }

    func testPromptAsksForTwiceTheBudget() {
        let prompt = MeetingPrompts.frameCandidates(for: "лента", budget: 15)

        XCTAssertTrue(prompt.contains("30"))
        XCTAssertTrue(prompt.contains("лента"))
    }
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `swift test --filter FrameCandidateTests`
Expected: FAIL — `cannot find 'FrameCandidateParser' in scope`

- [ ] **Step 3: Написать минимальную реализацию**

`Sources/CyclopMeetings/FrameCandidate.swift`:

```swift
import Foundation

/// A moment where the words alone do not carry what was on the screen.
///
/// `expectation` matters more than the timecode: the next step asks a vision
/// model a concrete question instead of «describe this frame», and a concrete
/// question is what makes a small budget of frames worth spending.
public struct FrameCandidate: Equatable, Sendable {
    public let start: TimeInterval
    public let expectation: String
    /// 1 is the most valuable. Higher numbers are dropped first when the
    /// budget bites.
    public let priority: Int

    public init(start: TimeInterval, expectation: String, priority: Int) {
        self.start = start
        self.expectation = expectation
        self.priority = priority
    }
}

/// Turns the model's answer into candidates.
///
/// Forgiving for the same reason `TranscriptParser` is: the shape is asked
/// for, not guaranteed. A line without a timecode is a preamble and costs
/// nothing to skip; a missing priority costs the whole candidate if we insist
/// on it, so it degrades to the lowest instead.
public enum FrameCandidateParser {
    /// `[01:02:03] 2 | what to expect`, hours and priority optional.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\**\[?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\]?\s*(\d)?\s*\|\s*(.*)$"#
    )

    public static let lowestPriority = 3

    public static func candidates(from text: String) -> [FrameCandidate] {
        var candidates: [FrameCandidate] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = pattern.firstMatch(in: line, range: range) else { continue }

            let hours = number(match, 1, in: line) ?? 0
            let minutes = number(match, 2, in: line) ?? 0
            let seconds = number(match, 3, in: line) ?? 0
            let priority = number(match, 4, in: line) ?? lowestPriority
            let expectation = string(match, 5, in: line).trimmingCharacters(in: .whitespaces)
            guard !expectation.isEmpty else { continue }

            candidates.append(FrameCandidate(
                start: TimeInterval(hours * 3600 + minutes * 60 + seconds),
                expectation: expectation,
                priority: min(max(priority, 1), lowestPriority)
            ))
        }
        return candidates
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

В `MeetingPrompts` добавить:

```swift
    /// Asks for twice the budget on purpose: the next filter drops the
    /// candidates whose screen had not changed, and a short list would leave
    /// the budget unspent.
    public static func frameCandidates(for transcript: String, budget: Int) -> String {
        """
        Ниже расшифровка рабочей встречи с таймкодами. Найди моменты, где \
        сказанное непонятно без картинки: показывают экран, зачитывают с \
        него, переключают демонстрацию, отвечают показом на просьбу \
        показать, называют идентификатор не полностью.

        Не предлагай моменты, где идёт обычный разговор без демонстрации.

        Верни до \(budget * 2) строк строго в формате:
        [ЧЧ:ММ:СС] приоритет | что ожидается увидеть на экране

        Приоритет: 1 — без кадра теряется существенное, 2 — полезно, \
        3 — по остаточному принципу. Таймкод бери на несколько секунд позже \
        начала реплики, чтобы экран успел смениться. Верни только строки, \
        без вводных фраз.

        Расшифровка:

        \(transcript)
        """
    }
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --filter FrameCandidateTests`
Expected: PASS, 5 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopMeetings/FrameCandidate.swift Sources/CyclopMeetings/MeetingPrompts.swift Tests/CyclopMeetingsTests/FrameCandidateTests.swift
git commit -m "Модель называет моменты, где нужен кадр"
```

---

### Task 2: Отбор моментов по бюджету

Слияние близких кандидатов, расчёт бюджета от длительности, срез по приоритету.

**Files:**
- Create: `Sources/CyclopMeetings/FramePlan.swift`
- Test: `Tests/CyclopMeetingsTests/FramePlanTests.swift`

**Interfaces:**
- Consumes: `FrameCandidate` из Task 1.
- Produces: `FramePlan.budget(forDuration:) -> Int`, `FramePlan.selected(from:budget:) -> [FrameCandidate]`, `FramePlan.minimumGap`.

- [ ] **Step 1: Написать падающий тест**

```swift
import XCTest
@testable import CyclopMeetings

final class FramePlanTests: XCTestCase {
    func testBudgetIsOneFramePerFourMinutes() {
        XCTAssertEqual(FramePlan.budget(forDuration: 3600), 15)
    }

    /// A five-minute call still deserves a couple of frames, and a four-hour
    /// one must not eat the whole request quota.
    func testBudgetIsClamped() {
        XCTAssertEqual(FramePlan.budget(forDuration: 60), 3)
        XCTAssertEqual(FramePlan.budget(forDuration: 14400), 40)
    }

    func testKeepsChronologicalOrder() {
        let candidates = [
            FrameCandidate(start: 300, expectation: "б", priority: 2),
            FrameCandidate(start: 100, expectation: "а", priority: 1),
        ]

        XCTAssertEqual(FramePlan.selected(from: candidates, budget: 5).map(\.start), [100, 300])
    }

    /// Two candidates a few seconds apart are the same screen twice.
    func testMergesCandidatesCloserThanTheGap() {
        let candidates = [
            FrameCandidate(start: 100, expectation: "схема", priority: 2),
            FrameCandidate(start: 120, expectation: "та же схема", priority: 1),
        ]

        let selected = FramePlan.selected(from: candidates, budget: 5)

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.expectation, "та же схема")
    }

    func testDropsLowestPriorityWhenOverBudget() {
        let candidates = [
            FrameCandidate(start: 100, expectation: "а", priority: 3),
            FrameCandidate(start: 200, expectation: "б", priority: 1),
            FrameCandidate(start: 300, expectation: "в", priority: 2),
        ]

        XCTAssertEqual(
            FramePlan.selected(from: candidates, budget: 2).map(\.expectation), ["б", "в"])
    }

    /// The anchor of the window is where the group started, not whoever
    /// currently represents it. Otherwise 0 / 40 / 80 — each pair inside the
    /// window — collapses into a single frame spanning eighty seconds.
    func testWindowAnchorDoesNotDriftAlongTheChain() {
        let candidates = [
            FrameCandidate(start: 0, expectation: "первый", priority: 3),
            FrameCandidate(start: 40, expectation: "второй", priority: 2),
            FrameCandidate(start: 80, expectation: "третий", priority: 1),
        ]

        let selected = FramePlan.selected(from: candidates, budget: 10)

        XCTAssertEqual(selected.map(\.start), [40, 80])
        XCTAssertEqual(selected.map(\.expectation), ["второй", "третий"])
    }

    func testEmptyInputGivesEmptyPlan() {
        XCTAssertTrue(FramePlan.selected(from: [], budget: 10).isEmpty)
    }
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `swift test --filter FramePlanTests`
Expected: FAIL — `cannot find 'FramePlan' in scope`

- [ ] **Step 3: Написать минимальную реализацию**

```swift
import Foundation

/// Which of the proposed moments actually get a frame.
///
/// Two filters live here — merging near-duplicates and cutting to budget. The
/// third one, «did the screen change at all», needs the video itself and runs
/// in `MeetingFrames`: the plan is built before a single frame is decoded.
public enum FramePlan {
    /// Closer than this and it is the same screen twice. Measured against the
    /// pace of a real demo: switching a tab, letting a page load and saying a
    /// sentence about it takes longer than this.
    public static let minimumGap: TimeInterval = 45

    public static let minimumBudget = 3
    public static let maximumBudget = 40

    /// One frame per four minutes. A recorded hour holds fifteen screens worth
    /// keeping — counted by hand on a real audit call — and that is also about
    /// what the request quota tolerates in one processing run.
    public static func budget(forDuration duration: TimeInterval) -> Int {
        let raw = Int((duration / 240).rounded())
        return min(max(raw, minimumBudget), maximumBudget)
    }

    public static func selected(from candidates: [FrameCandidate], budget: Int) -> [FrameCandidate] {
        let merged = merge(candidates.sorted { $0.start < $1.start })
        guard merged.count > budget else { return merged }

        // Sorted by priority, then by time so that ties resolve the same way
        // every run: a plan that shuffles between runs is impossible to test
        // and confusing to re-read.
        let kept = merged
            .enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .prefix(budget)
            .map(\.offset)
        let keptSet = Set(kept)
        return merged.enumerated().filter { keptSet.contains($0.offset) }.map(\.element)
    }

    /// Of two candidates within `minimumGap`, the more valuable one survives —
    /// its expectation is the sharper question to ask about that screen. The
    /// window is measured from where the group started rather than from the
    /// survivor: a survivor moves forward every time a better candidate
    /// replaces it, and a moving anchor drags the window along with it, so a
    /// burst of switches collapses into one frame covering minutes.
    private static func merge(_ sorted: [FrameCandidate]) -> [FrameCandidate] {
        var merged: [FrameCandidate] = []
        var groupStart: TimeInterval?

        for candidate in sorted {
            guard let start = groupStart, candidate.start - start < minimumGap else {
                merged.append(candidate)
                groupStart = candidate.start
                continue
            }
            if candidate.priority < merged[merged.count - 1].priority {
                merged[merged.count - 1] = candidate
            }
        }
        return merged
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --filter FramePlanTests`
Expected: PASS, 7 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopMeetings/FramePlan.swift Tests/CyclopMeetingsTests/FramePlanTests.swift
git commit -m "Моменты для кадров сливаются и режутся по бюджету"
```

---

### Task 3: Разбор кадра

Тип разобранного кадра, промпт разбора и парсер ответа.

**Files:**
- Create: `Sources/CyclopMeetings/ScreenNote.swift`
- Modify: `Sources/CyclopMeetings/MeetingPrompts.swift`
- Test: `Tests/CyclopMeetingsTests/ScreenNoteTests.swift`

**Interfaces:**
- Consumes: `FrameCandidate` из Task 1.
- Produces: `ScreenNote(start:title:details:presenter:uiNames:slug:isUseful:)`, `ScreenNoteParser.notes(from:) -> [ScreenNote]`, `MeetingPrompts.screenNotes(for:) -> String`, `ScreenNote.fileName`.

- [ ] **Step 1: Написать падающий тест**

```swift
import XCTest
@testable import CyclopMeetings

final class ScreenNoteTests: XCTestCase {
    private let answer = """
        [00:30:00]
        useful: yes
        slug: yandex-cloud-k8s-рабочая-нагрузка
        title: консоль Yandex Cloud, Managed Kubernetes
        details: Кластер ycru1-mp2-prod-k8s-05sd6avu, поды argocd-application-controller-0, все Running
        presenter: Антон Копытин
        names: Alexander T., Антон Копытин, Илья Канюков

        [00:41:40]
        useful: no
        title: пустой рабочий стол
        """

    func testParsesFullBlock() {
        let notes = ScreenNoteParser.notes(from: answer)

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].start, 1800)
        XCTAssertEqual(notes[0].title, "консоль Yandex Cloud, Managed Kubernetes")
        XCTAssertTrue(notes[0].details.contains("ycru1-mp2-prod-k8s-05sd6avu"))
        XCTAssertEqual(notes[0].presenter, "Антон Копытин")
        XCTAssertEqual(notes[0].uiNames, ["Alexander T.", "Антон Копытин", "Илья Канюков"])
        XCTAssertTrue(notes[0].isUseful)
    }

    func testMarksUselessFrame() {
        XCTAssertFalse(ScreenNoteParser.notes(from: answer)[1].isUseful)
    }

    /// A frame the model said nothing about must not become an empty block in
    /// the transcript.
    func testSkipsBlockWithoutTitle() {
        let notes = ScreenNoteParser.notes(from: "[00:10:00]\nuseful: yes")

        XCTAssertTrue(notes.isEmpty)
    }

    func testFileNameCarriesTimecodeAndSlug() {
        let note = ScreenNote(
            start: 1800, title: "т", details: "д", presenter: nil,
            uiNames: [], slug: "yandex-cloud", isUseful: true)

        XCTAssertEqual(note.fileName, "30-00_yandex-cloud.jpg")
    }

    /// Without a slug the file still has to be nameable — the timecode alone
    /// is unique.
    /// A stray field line between two blocks must not attach to the block that
    /// just ended: the first value of a key wins, so the block keeps what it
    /// had already collected.
    func testStrayFieldBetweenBlocksDoesNotStealTheTimecode() {
        let text = """
            [00:05:00]
            useful: yes
            title: A

            title: B
            [00:10:00]
            useful: yes
            title: C
            """

        let notes = ScreenNoteParser.notes(from: text)

        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].start, 300)
        XCTAssertEqual(notes[0].title, "A")
        XCTAssertEqual(notes[1].start, 600)
        XCTAssertEqual(notes[1].title, "C")
    }

    /// A blank line inside a block is not a separator: the model breaks its
    /// own format this way, and everything after the gap has to survive.
    func testBlankLineInsideBlockDoesNotEndIt() {
        let text = """
            [00:05:00]
            useful: yes

            title: экран
            details: подробности
            """

        let notes = ScreenNoteParser.notes(from: text)

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].title, "экран")
        XCTAssertEqual(notes[0].details, "подробности")
    }

    func testFileNameFallsBackToTimecode() {
        let note = ScreenNote(
            start: 61, title: "т", details: "", presenter: nil,
            uiNames: [], slug: "", isUseful: true)

        XCTAssertEqual(note.fileName, "01-01.jpg")
    }
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `swift test --filter ScreenNoteTests`
Expected: FAIL — `cannot find 'ScreenNoteParser' in scope`

- [ ] **Step 3: Написать минимальную реализацию**

`Sources/CyclopMeetings/ScreenNote.swift`:

```swift
import Foundation

/// What one frame turned out to hold.
///
/// `details` carries identifiers verbatim because the file is read by a model
/// later, and a model without eyes gets nothing from the picture. `uiNames`
/// comes along for free: the call's own interface labels its tiles, and the
/// frame was going to be sent anyway.
public struct ScreenNote: Equatable, Sendable {
    public let start: TimeInterval
    public let title: String
    public let details: String
    public let presenter: String?
    public let uiNames: [String]
    public let slug: String
    /// The model's own verdict. A frame of an empty desktop costs a request
    /// either way, but it must not cost a block in the transcript.
    public let isUseful: Bool

    public init(
        start: TimeInterval,
        title: String,
        details: String,
        presenter: String?,
        uiNames: [String],
        slug: String,
        isUseful: Bool
    ) {
        self.start = start
        self.title = title
        self.details = details
        self.presenter = presenter
        self.uiNames = uiNames
        self.slug = slug
        self.isUseful = isUseful
    }

    /// `30-00_slug.jpg`. Minutes and seconds rather than the full clock: an
    /// hour-long meeting reads better as `41-40` than as `00-41-40`, and past
    /// an hour the minutes simply keep counting.
    public var fileName: String {
        let total = Int(start.rounded(.down))
        let stamp = String(format: "%02d-%02d", total / 60, total % 60)
        return slug.isEmpty ? "\(stamp).jpg" : "\(stamp)_\(slug).jpg"
    }

    public var timecode: String {
        let total = Int(start.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// Turns the model's answer into notes.
///
/// Blocks separated by a timecode line, fields as `key: value`. Chosen over
/// JSON for the same reason the transcript is lines: the model drifts, and a
/// half-broken block still yields its title and details, while a half-broken
/// JSON yields nothing.
public enum ScreenNoteParser {
    private static let timecodePattern = try! NSRegularExpression(
        pattern: #"^\**\[?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})\]?\**\s*$"#
    )

    public static func notes(from text: String) -> [ScreenNote] {
        var notes: [ScreenNote] = []
        var start: TimeInterval?
        var fields: [String: String] = [:]

        func flush() {
            // Both the fields and the timecode are cleared: a timecode that
            // outlived its block would adopt whatever line came next.
            defer { fields = [:]; start = nil }
            guard let start else { return }
            let title = fields["title"] ?? ""
            guard !title.isEmpty else { return }
            notes.append(ScreenNote(
                start: start,
                title: title,
                details: fields["details"] ?? "",
                presenter: fields["presenter"].flatMap { $0.isEmpty ? nil : $0 },
                uiNames: (fields["names"] ?? "")
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                slug: slugify(fields["slug"] ?? ""),
                isUseful: (fields["useful"] ?? "yes").lowercased().hasPrefix("y")
                    || (fields["useful"] ?? "").lowercased().hasPrefix("д")
            ))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = timecodePattern.firstMatch(in: line, range: range) {
                flush()
                let hours = number(match, 1, in: line) ?? 0
                let minutes = number(match, 2, in: line) ?? 0
                let seconds = number(match, 3, in: line) ?? 0
                start = TimeInterval(hours * 3600 + minutes * 60 + seconds)
                continue
            }

            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            // First value wins. A stray field line between two blocks would
            // otherwise overwrite what the block that just ended had already
            // collected, and the frame would end up described by the next
            // one's words.
            if fields[key] == nil { fields[key] = value }
        }
        flush()
        return notes
    }

    /// The slug becomes a file name, so anything a file name cannot hold is
    /// replaced rather than trusted: the model is asked for a clean slug and
    /// occasionally answers with a sentence.
    private static func slugify(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let collapsed = raw.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
        return String(collapsed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .prefix(60)
            .description
    }

    private static func number(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> Int? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return Int(line[range])
    }
}
```

В `MeetingPrompts` добавить:

```swift
    /// One request carries several frames, so every answer has to name the
    /// timecode it belongs to — the order of images is not a contract.
    public static func screenNotes(for frames: [(timecode: String, expectation: String, context: String)]) -> String {
        let list = frames
            .map { "[\($0.timecode)] ожидается: \($0.expectation)\nреплики рядом: \($0.context)" }
            .joined(separator: "\n\n")
        return """
            Ниже несколько кадров с рабочей встречи, по одному на каждый \
            таймкод, в том же порядке. Для каждого кадра опиши, что на экране.

            Отвечай блоками, по блоку на кадр, строго в формате:
            [ЧЧ:ММ:СС]
            useful: yes или no
            slug: короткое-имя-латиницей-или-кириллицей-через-дефис
            title: что за экран одной строкой
            details: идентификаторы дословно — URL, названия проектов, \
            кластеров, файлов, статусы, числа
            presenter: кто демонстрирует, если подписано в интерфейсе звонка
            names: имена участников, видимые в интерфейсе звонка, через запятую

            useful: no ставь, если на кадре нет ничего осмысленного — пустой \
            рабочий стол, заставка, переходное состояние. Пиши по-русски, \
            английские названия оставляй на английском. Идентификаторы \
            переписывай символ в символ, не переводи и не сокращай.

            Кадры:

            \(list)
            """
    }
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --filter ScreenNoteTests`
Expected: PASS, 7 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopMeetings/ScreenNote.swift Sources/CyclopMeetings/MeetingPrompts.swift Tests/CyclopMeetingsTests/ScreenNoteTests.swift
git commit -m "Кадр превращается в описание экрана"
```

---

### Task 4: Профили меток и участники

Статистика по меткам диаризации, тип участника и сведение имён из источников.

**Files:**
- Create: `Sources/CyclopMeetings/ParticipantRoster.swift`
- Test: `Tests/CyclopMeetingsTests/ParticipantRosterTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment` (существует), `ScreenNote` из Task 3.
- Produces: `SpeakerProfile(label:characters:lines:first:last:)`, `SpeakerProfiler.profiles(of:) -> [SpeakerProfile]`, `Participant(name:role:confidence:evidence:)`, `Participant.Confidence`, `ParticipantRoster.candidateNames(owner:calendar:notes:) -> [String]`.

- [ ] **Step 1: Написать падающий тест**

```swift
import XCTest
@testable import CyclopMeetings

final class ParticipantRosterTests: XCTestCase {
    private let segments = [
        TranscriptSegment(start: 0, speaker: "Участник 1", text: "раз"),
        TranscriptSegment(start: 10, speaker: "Участник 2", text: "два два два"),
        TranscriptSegment(start: 20, speaker: "Участник 1", text: "три"),
    ]

    func testProfileCountsSpeechAndSpan() {
        let profiles = SpeakerProfiler.profiles(of: segments)

        XCTAssertEqual(profiles.count, 2)
        let first = profiles.first { $0.label == "Участник 1" }
        XCTAssertEqual(first?.lines, 2)
        XCTAssertEqual(first?.characters, 6)
        XCTAssertEqual(first?.first, 0)
        XCTAssertEqual(first?.last, 20)
    }

    /// The order is what the model reads first, and the loudest speaker is the
    /// one whose identity matters most.
    func testProfilesAreSortedByVolume() {
        XCTAssertEqual(SpeakerProfiler.profiles(of: segments).first?.label, "Участник 2")
    }

    func testCandidateNamesMergeAllSources() {
        let note = ScreenNote(
            start: 0, title: "т", details: "", presenter: nil,
            uiNames: ["Антон Копытин", "Alexander T."], slug: "", isUseful: true)

        let names = ParticipantRoster.candidateNames(
            owner: "Роман Ястребов", calendar: ["Екатерина Яблокова"], notes: [note])

        XCTAssertEqual(
            names, ["Роман Ястребов", "Екатерина Яблокова", "Alexander T.", "Антон Копытин"])
    }

    /// One person joined from two devices shows up as two identical tiles.
    /// Counting them twice would invent a participant.
    func testCandidateNamesDropDuplicates() {
        let note = ScreenNote(
            start: 0, title: "т", details: "", presenter: nil,
            uiNames: ["Антон Копытин", "Антон Копытин"], slug: "", isUseful: true)

        XCTAssertEqual(ParticipantRoster.candidateNames(owner: nil, calendar: [], notes: [note]),
                       ["Антон Копытин"])
    }

    func testNamesFromUselessFramesStillCount() {
        let note = ScreenNote(
            start: 0, title: "пусто", details: "", presenter: nil,
            uiNames: ["Денис Терещенко"], slug: "", isUseful: false)

        XCTAssertEqual(ParticipantRoster.candidateNames(owner: nil, calendar: [], notes: [note]),
                       ["Денис Терещенко"])
    }
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `swift test --filter ParticipantRosterTests`
Expected: FAIL — `cannot find 'SpeakerProfiler' in scope`

- [ ] **Step 3: Написать минимальную реализацию**

```swift
import Foundation

/// How much one diarisation label speaks and when.
///
/// This is what makes structural mistakes visible. On a real meeting the model
/// tore one person into two labels — the first ended at 54:59 and the second
/// picked up at 55:00 — and no amount of reading the words would have shown
/// that as clearly as the two spans side by side.
public struct SpeakerProfile: Equatable, Sendable {
    public let label: String
    public let characters: Int
    public let lines: Int
    public let first: TimeInterval
    public let last: TimeInterval

    public init(label: String, characters: Int, lines: Int, first: TimeInterval, last: TimeInterval) {
        self.label = label
        self.characters = characters
        self.lines = lines
        self.first = first
        self.last = last
    }

    /// The shape the prompt carries. Compact on purpose: it rides along with
    /// the whole transcript, and every token here is one not spent on words.
    public var line: String {
        "\(label): \(lines) реплик, \(characters) символов, "
            + "с \(Self.clock(first)) по \(Self.clock(last))"
    }

    private static func clock(_ time: TimeInterval) -> String {
        let total = Int(time.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

public enum SpeakerProfiler {
    /// Sorted by how much each label speaks: the model reads the top of the
    /// list most carefully, and that is where the identities that matter are.
    public static func profiles(of segments: [TranscriptSegment]) -> [SpeakerProfile] {
        var byLabel: [String: (characters: Int, lines: Int, first: TimeInterval, last: TimeInterval)] = [:]

        for segment in segments {
            let existing = byLabel[segment.speaker]
            byLabel[segment.speaker] = (
                characters: (existing?.characters ?? 0) + segment.text.count,
                lines: (existing?.lines ?? 0) + 1,
                first: existing.map { min($0.first, segment.start) } ?? segment.start,
                last: max(existing?.last ?? 0, segment.start)
            )
        }

        return byLabel
            .map { SpeakerProfile(
                label: $0.key, characters: $0.value.characters, lines: $0.value.lines,
                first: $0.value.first, last: $0.value.last) }
            .sorted { ($0.characters, $0.label) > ($1.characters, $1.label) }
    }
}

/// One person at the meeting.
public struct Participant: Equatable, Sendable {
    /// How much the name and the role can be trusted. Written into the file
    /// because a model reads it later and must not take a guess for a fact.
    public enum Confidence: String, Sendable, Equatable {
        case fact
        case high
        case medium
        case low

        public var word: String {
            switch self {
            case .fact: return "факт"
            case .high: return "высокая"
            case .medium: return "средняя"
            case .low: return "низкая"
            }
        }
    }

    public let name: String
    public let role: String?
    public let confidence: Confidence
    public let evidence: String

    public init(name: String, role: String?, confidence: Confidence, evidence: String) {
        self.name = name
        self.role = role
        self.confidence = confidence
        self.evidence = evidence
    }
}

public enum ParticipantRoster {
    /// The closed set of names the model is allowed to choose from.
    ///
    /// Order is deliberate — owner, then the invitation, then what the call's
    /// interface showed — and it is the order of how much each source is
    /// trusted. Names seen in the interface are kept even when the frame they
    /// came from was useless: an empty desktop still had the tiles on it.
    public static func candidateNames(
        owner: String?, calendar: [String], notes: [ScreenNote]
    ) -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return }
            names.append(trimmed)
        }

        owner.map(add)
        calendar.forEach(add)
        notes.flatMap(\.uiNames).sorted().forEach(add)
        return names
    }
}
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --filter ParticipantRosterTests`
Expected: PASS, 5 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopMeetings/ParticipantRoster.swift Tests/CyclopMeetingsTests/ParticipantRosterTests.swift
git commit -m "Профиль метки и закрытый список имён"
```

---

### Task 5: Привязка меток к именам

Промпт участников, разбор ответа и переразметка ленты, включая разрез склеенной метки.

**Files:**
- Create: `Sources/CyclopMeetings/SpeakerResolution.swift`
- Modify: `Sources/CyclopMeetings/MeetingPrompts.swift`
- Test: `Tests/CyclopMeetingsTests/SpeakerResolutionTests.swift`

**Interfaces:**
- Consumes: `TranscriptSegment`, `SpeakerProfile` и `Participant.Confidence` из Task 4.
- Produces: `SpeakerResolution(label:name:confidence:evidence:splitAt:splitName:)`, `SpeakerResolutionParser.resolutions(from:) -> [SpeakerResolution]`, `SpeakerRelabeler.apply(_:to:) -> [TranscriptSegment]`, `MeetingPrompts.participants(transcript:profiles:names:) -> String`.

- [ ] **Step 1: Написать падающий тест**

```swift
import XCTest
@testable import CyclopMeetings

final class SpeakerResolutionTests: XCTestCase {
    func testParsesResolution() {
        let answer = "Участник 2 = Александр Трофимов | высокая | 01:40 «Меня зовут Александр»"

        XCTAssertEqual(
            SpeakerResolutionParser.resolutions(from: answer),
            [SpeakerResolution(
                label: "Участник 2", name: "Александр Трофимов", confidence: .high,
                evidence: "01:40 «Меня зовут Александр»", splitAt: nil, splitName: nil)]
        )
    }

    func testParsesSplitInstruction() {
        let answer = "Участник 1 = Роман Ястребов | средняя | организует запись | split 00:55:00 Антон Копытин"

        let resolution = SpeakerResolutionParser.resolutions(from: answer).first

        XCTAssertEqual(resolution?.splitAt, 3300)
        XCTAssertEqual(resolution?.splitName, "Антон Копытин")
    }

    func testRenamesSegments() {
        let segments = [
            TranscriptSegment(start: 0, speaker: "Участник 2", text: "раз"),
            TranscriptSegment(start: 10, speaker: "Участник 3", text: "два"),
        ]
        let resolutions = [SpeakerResolution(
            label: "Участник 2", name: "Александр", confidence: .high,
            evidence: "", splitAt: nil, splitName: nil)]

        let renamed = SpeakerRelabeler.apply(resolutions, to: segments)

        XCTAssertEqual(renamed.map(\.speaker), ["Александр", "Участник 3"])
    }

    /// The whole point of the split: everything before the boundary is one
    /// person, everything after is another.
    func testSplitsGluedLabelAtBoundary() {
        let segments = [
            TranscriptSegment(start: 10, speaker: "Участник 1", text: "раз"),
            TranscriptSegment(start: 3400, speaker: "Участник 1", text: "два"),
        ]
        let resolutions = [SpeakerResolution(
            label: "Участник 1", name: "Роман", confidence: .medium,
            evidence: "", splitAt: 3300, splitName: "Антон")]

        XCTAssertEqual(
            SpeakerRelabeler.apply(resolutions, to: segments).map(\.speaker), ["Роман", "Антон"])
    }

    /// Two labels resolved to one name is how a torn-apart person gets sewn
    /// back together — no special case needed, both simply get the same name.
    func testTwoLabelsCanShareOneName() {
        let segments = [
            TranscriptSegment(start: 0, speaker: "Участник 5", text: "раз"),
            TranscriptSegment(start: 10, speaker: "Участник 1", text: "два"),
        ]
        let resolutions = [
            SpeakerResolution(label: "Участник 5", name: "Антон", confidence: .high,
                              evidence: "", splitAt: nil, splitName: nil),
            SpeakerResolution(label: "Участник 1", name: "Антон", confidence: .high,
                              evidence: "", splitAt: nil, splitName: nil),
        ]

        XCTAssertEqual(SpeakerRelabeler.apply(resolutions, to: segments).map(\.speaker),
                       ["Антон", "Антон"])
    }

    func testUnresolvedLabelSurvivesUntouched() {
        let segments = [TranscriptSegment(start: 0, speaker: "Участник 9", text: "раз")]

        XCTAssertEqual(SpeakerRelabeler.apply([], to: segments), segments)
    }

    /// The reference case from the spec, with its real numbers. On the audit
    /// call of 24.08.2026 the model tore the architect in two — label 5 ended
    /// at 54:59, label 1 picked up at 55:00 — and glued the person who opened
    /// the call into that same label 1. Both fixes have to hold at once:
    /// everything before the boundary is one person, everything after is the
    /// architect, and the other label is the architect too.
    func testReferenceMeetingIsRepaired() {
        let segments = [
            TranscriptSegment(start: 37, speaker: "Участник 1", text: "Саш, транскрибатор включишь?"),
            TranscriptSegment(start: 3299, speaker: "Участник 5", text: "Вот."),
            TranscriptSegment(start: 3300, speaker: "Участник 1", text: "Итог по каждому проекту."),
            TranscriptSegment(start: 4441, speaker: "Участник 1", text: "Я вам всё показал."),
        ]
        let resolutions = [
            SpeakerResolution(label: "Участник 5", name: "Антон Копытин", confidence: .high,
                              evidence: "плитка в кадре 30:00", splitAt: nil, splitName: nil),
            SpeakerResolution(label: "Участник 1", name: "Роман Ястребов", confidence: .medium,
                              evidence: "00:37 организует запись",
                              splitAt: 3300, splitName: "Антон Копытин"),
        ]

        XCTAssertEqual(
            SpeakerRelabeler.apply(resolutions, to: segments).map(\.speaker),
            ["Роман Ястребов", "Антон Копытин", "Антон Копытин", "Антон Копытин"]
        )
    }
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `swift test --filter SpeakerResolutionTests`
Expected: FAIL — `cannot find 'SpeakerResolutionParser' in scope`

- [ ] **Step 3: Написать минимальную реализацию**

`Sources/CyclopMeetings/SpeakerResolution.swift`:

```swift
import Foundation

/// One diarisation label tied to one person.
///
/// `splitAt` exists because the model does not only mislabel, it mis-splits:
/// on a real meeting a single label held the person who opened the call and
/// the architect who spoke an hour later. Renaming such a label is worse than
/// leaving it — half the lines get the wrong name — so the boundary travels
/// with the resolution.
public struct SpeakerResolution: Equatable, Sendable {
    public let label: String
    public let name: String
    public let confidence: Participant.Confidence
    public let evidence: String
    public let splitAt: TimeInterval?
    public let splitName: String?

    public init(
        label: String,
        name: String,
        confidence: Participant.Confidence,
        evidence: String,
        splitAt: TimeInterval?,
        splitName: String?
    ) {
        self.label = label
        self.name = name
        self.confidence = confidence
        self.evidence = evidence
        self.splitAt = splitAt
        self.splitName = splitName
    }
}

public enum SpeakerResolutionParser {
    /// The split tail, cut off before the rest is read.
    ///
    /// It used to be one branch of a single pattern covering the whole line,
    /// and that made the line all-or-nothing: a stray `|` inside the evidence,
    /// or a `split` with no name after it, dropped the resolution entirely —
    /// name, confidence and all. The parser has to degrade the way
    /// `TranscriptParser` does, keeping whatever it could read.
    private static let splitTail = try! NSRegularExpression(
        pattern: #"\s*\|\s*split\s+(\d{1,2}):(\d{2}):(\d{2})(?:\s+(.+?))?\s*$"#
    )

    /// Asterisks and spaces, stripped from the ends of every field: the model
    /// writes whole lines in bold, and a trailing pair used to ride into the
    /// split name and from there into the speaker's displayed name.
    private static let decoration = CharacterSet(charactersIn: "* ")

    public static func resolutions(from text: String) -> [SpeakerResolution] {
        var resolutions: [SpeakerResolution] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: decoration)
            guard !line.isEmpty else { continue }

            var splitAt: TimeInterval?
            var splitName: String?
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = splitTail.firstMatch(in: line, range: range),
               let hours = Int(string(match, 1, in: line)),
               let minutes = Int(string(match, 2, in: line)),
               let seconds = Int(string(match, 3, in: line)) {
                let name = string(match, 4, in: line).trimmingCharacters(in: decoration)
                if !name.isEmpty {
                    splitAt = TimeInterval(hours * 3600 + minutes * 60 + seconds)
                    splitName = name
                }
                // The tail goes whether or not it named anyone: a split with no
                // name cannot be acted on, but it has no business being read as
                // part of the evidence either.
                if let cut = Range(match.range, in: line) {
                    line = String(line[line.startIndex..<cut.lowerBound])
                }
            }

            let parts = line.components(separatedBy: "|")
            guard parts.count >= 2 else { continue }
            let head = parts[0].components(separatedBy: "=")
            guard head.count >= 2 else { continue }

            let label = head[0].trimmingCharacters(in: decoration)
            // An `=` inside the name is put back rather than treated as a
            // second separator — the first one is the only one that divides.
            let name = head[1...].joined(separator: "=").trimmingCharacters(in: decoration)
            guard !label.isEmpty, !name.isEmpty else { continue }

            resolutions.append(SpeakerResolution(
                label: label,
                name: name,
                confidence: confidence(from: parts[1]),
                // Everything past the second separator is the evidence, `|`
                // included: it is a quote from the meeting, not ours to cut.
                evidence: parts.count > 2
                    ? parts[2...].joined(separator: "|").trimmingCharacters(in: .whitespaces)
                    : "",
                splitAt: splitAt,
                splitName: splitName
            ))
        }
        return resolutions
    }

    /// An unrecognised word degrades to the lowest confidence rather than
    /// dropping the line: a name with a cautious label still beats a number.
    private static func confidence(from raw: String) -> Participant.Confidence {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "факт", "fact": return .fact
        case "высокая", "high": return .high
        case "средняя", "medium": return .medium
        default: return .low
        }
    }

    private static func string(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String {
        guard let range = Range(match.range(at: index), in: line) else { return "" }
        return String(line[range])
    }
}

public enum SpeakerRelabeler {
    /// Labels the model said nothing about keep their number: an invented name
    /// is worse than an honest «Участник 3».
    public static func apply(
        _ resolutions: [SpeakerResolution], to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard !resolutions.isEmpty else { return segments }
        let byLabel = Dictionary(resolutions.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })

        return segments.map { segment in
            guard let resolution = byLabel[segment.speaker] else { return segment }
            let name: String
            if let splitAt = resolution.splitAt, let splitName = resolution.splitName,
               segment.start >= splitAt {
                name = splitName
            } else {
                name = resolution.name
            }
            return TranscriptSegment(start: segment.start, speaker: name, text: segment.text)
        }
    }
}
```

В `MeetingPrompts` добавить:

```swift
    /// The profiles ride along with the words because structural mistakes are
    /// visible in the numbers and invisible in the text: a label that stops at
    /// 54:59 next to one that starts at 55:00 is one person, and only the
    /// spans say so.
    public static func participants(
        transcript: String, profiles: [SpeakerProfile], names: [String]
    ) -> String {
        """
        Ниже расшифровка рабочей встречи, статистика по говорящим и список \
        имён участников, известных заранее.

        Сопоставь каждого говорящего с именем из списка. Не придумывай имён \
        вне списка: если имя не звучало и его нет в списке, пропусти этого \
        говорящего.

        Обрати внимание на две частые ошибки разметки. Первая: один человек \
        разделён на двух говорящих — тогда обоим ставь одно имя. Вторая: под \
        одним говорящим склеены два человека — тогда добавь в конец строки \
        `| split ЧЧ:ММ:СС Имя второго`, где таймкод это момент, с которого \
        начинается второй.

        Отвечай строками строго в формате:
        Говорящий = Имя | уверенность | доказательство

        Уверенность: высокая, средняя или низкая. Доказательство — таймкод и \
        короткая цитата или ссылка на то, что видно в интерфейсе звонка.

        Известные имена: \(names.joined(separator: ", "))

        Статистика:
        \(profiles.map(\.line).joined(separator: "\n"))

        Расшифровка:

        \(transcript)
        """
    }

    /// Roles are asked for separately from names: a tile in the call shows a
    /// name and never a role, so this half has one source only and is always
    /// marked as a guess in the file.
    public static func roles(transcript: String, names: [String]) -> String {
        """
        Ниже расшифровка рабочей встречи. Для каждого участника определи его \
        роль по репликам: должность, зона ответственности или сторона, \
        которую он представляет.

        Отвечай строками строго в формате:
        Имя | роль | доказательство

        Роль — несколько слов. Доказательство — таймкод и короткая цитата. \
        Если по репликам роль не понять, пропусти участника, не угадывай.

        Участники: \(names.joined(separator: ", "))

        Расшифровка:

        \(transcript)
        """
    }
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --filter SpeakerResolutionTests`
Expected: PASS, 10 тестов

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopMeetings/SpeakerResolution.swift Sources/CyclopMeetings/MeetingPrompts.swift Tests/CyclopMeetingsTests/SpeakerResolutionTests.swift
git commit -m "Метки получают имена, склеенные режутся по границе"
```

---

### Task 6: Шапка участников и блоки кадров в документе

**Files:**
- Modify: `Sources/CyclopMeetings/TranscriptDocument.swift`
- Modify: `Tests/CyclopMeetingsTests/TranscriptDocumentTests.swift`

**Interfaces:**
- Consumes: `Participant` из Task 4, `ScreenNote` из Task 3.
- Produces: `TranscriptDocument.init(date:duration:videoFileName:summary:segments:hasMicrophoneLane:participants:notes:skippedFrames:)` — новые параметры со значениями по умолчанию, чтобы существующие вызовы не сломались.

- [ ] **Step 1: Написать падающий тест**

Дописать в `TranscriptDocumentTests`:

```swift
    // Named apart from the existing `document(...)` helper in this file: both
    // take only defaulted parameters, and a call with no arguments would be
    // ambiguous between them.
    private func frameDocument(
        participants: [Participant] = [],
        notes: [ScreenNote] = [],
        skippedFrames: Int = 0
    ) -> TranscriptDocument {
        TranscriptDocument(
            date: Date(timeIntervalSince1970: 0),
            duration: 60,
            videoFileName: "meeting.mp4",
            summary: "итоги",
            segments: [
                TranscriptSegment(start: 0, speaker: "Антон", text: "вот здесь всё крутится"),
                TranscriptSegment(start: 90, speaker: "Роман", text: "понятно"),
            ],
            hasMicrophoneLane: true,
            participants: participants,
            notes: notes,
            skippedFrames: skippedFrames
        )
    }

    func testParticipantsTableIsRendered() {
        let rendered = frameDocument(participants: [
            Participant(name: "Антон Копытин", role: "архитектор", confidence: .high,
                        evidence: "1:14:01 «я архитектор»")
        ]).render()

        XCTAssertTrue(rendered.contains("## Участники"))
        XCTAssertTrue(rendered.contains("| Антон Копытин | архитектор | высокая |"))
        XCTAssertTrue(rendered.contains("1:14:01 «я архитектор»"))
    }

    func testNoParticipantsMeansNoSection() {
        XCTAssertFalse(frameDocument().render().contains("## Участники"))
    }

    /// The block goes after the line it belongs to, and its text goes before
    /// the picture: the file is read by models without eyes.
    func testScreenNoteIsPlacedAfterItsSegment() {
        let rendered = frameDocument(notes: [ScreenNote(
            start: 30, title: "консоль Yandex Cloud", details: "кластер ycru1-mp2",
            presenter: "Антон Копытин", uiNames: [], slug: "yc", isUseful: true)
        ]).render()

        let lines = rendered.components(separatedBy: "\n")
        let speech = lines.firstIndex { $0.contains("вот здесь всё крутится") }!
        let block = lines.firstIndex { $0.contains("консоль Yandex Cloud") }!
        let picture = lines.firstIndex { $0.contains("![") }!
        let next = lines.firstIndex { $0.contains("понятно") }!

        XCTAssertTrue(speech < block)
        XCTAssertTrue(block < picture)
        XCTAssertTrue(picture < next)
        XCTAssertTrue(rendered.contains("screens/00-30_yc.jpg"))
    }

    func testUselessNoteIsNotRendered() {
        let rendered = frameDocument(notes: [ScreenNote(
            start: 30, title: "пустой стол", details: "", presenter: nil,
            uiNames: [], slug: "x", isUseful: false)]).render()

        XCTAssertFalse(rendered.contains("пустой стол"))
    }

    /// Losing coverage silently would read as «everything was covered».
    func testSkippedFramesAreReported() {
        let rendered = frameDocument(
            notes: [ScreenNote(start: 30, title: "экран", details: "", presenter: nil,
                               uiNames: [], slug: "s", isUseful: true)],
            skippedFrames: 3
        ).render()

        XCTAssertTrue(rendered.contains("Кадров разобрано:** 1 из 4"))
    }
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `swift test --filter TranscriptDocumentTests`
Expected: FAIL — `extra arguments at positions #7, #8, #9 in call`

- [ ] **Step 3: Написать минимальную реализацию**

В `TranscriptDocument` добавить три хранимых свойства и параметры инициализатора со значениями по умолчанию:

```swift
    private let participants: [Participant]
    private let notes: [ScreenNote]
    private let skippedFrames: Int

    public init(
        date: Date,
        duration: TimeInterval,
        videoFileName: String,
        summary: String,
        segments: [TranscriptSegment],
        hasMicrophoneLane: Bool,
        participants: [Participant] = [],
        notes: [ScreenNote] = [],
        skippedFrames: Int = 0
    ) {
        self.date = date
        self.duration = duration
        self.videoFileName = videoFileName
        self.summary = summary
        self.segments = segments
        self.hasMicrophoneLane = hasMicrophoneLane
        self.participants = participants
        // Useless frames are dropped once, here, so neither the counter nor
        // the feed has to remember to filter them again.
        self.notes = notes.filter(\.isUseful).sorted { $0.start < $1.start }
        self.skippedFrames = skippedFrames
    }
```

В `render()` после строки `**Запись:**` добавить счётчик кадров:

```swift
        if !notes.isEmpty || skippedFrames > 0 {
            lines[lines.count - 1] += "  "
            lines.append(
                "**Кадров разобрано:** \(notes.count) из \(notes.count + skippedFrames)")
        }
```

После блока с предупреждением о микрофонной дорожке — таблицу участников:

```swift
        if !participants.isEmpty {
            lines.append("")
            lines.append("## Участники")
            lines.append("")
            lines.append(
                "Имена взяты из интерфейса звонка и приглашения в календаре, "
                + "роли выведены из реплик. Правьте прямо здесь — лента ниже "
                + "подписана этими же именами."
            )
            lines.append("")
            lines.append("| Имя | Роль | Уверенность | На чём основано |")
            lines.append("|---|---|---|---|")
            for participant in participants {
                lines.append(
                    "| \(Self.cell(participant.name)) | \(Self.cell(participant.role ?? "—")) "
                    + "| \(participant.confidence.word) | \(Self.cell(participant.evidence)) |"
                )
            }
        }
```

Цикл вывода реплик заменить на вариант, вставляющий блоки кадров. Кадр принадлежит той реплике, которая последней началась до него:

```swift
        var pending = notes
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            let nextStart = isLast ? TimeInterval.greatestFiniteMagnitude : segments[index + 1].start
            let attached = pending.prefix { $0.start < nextStart }
            pending.removeFirst(attached.count)

            // The hard break belongs to a line that has a next line right
            // under it. A segment followed by a screen block does not.
            lines.append(attached.isEmpty && !isLast ? segment.line + "  " : segment.line)

            for note in attached {
                lines.append("")
                lines.append("> **Экран \(note.timecode) — \(note.title)**")
                if !note.details.isEmpty {
                    lines.append("> \(note.details)")
                }
                if let presenter = note.presenter {
                    lines.append("> Демонстрирует \(presenter).")
                }
                lines.append(">")
                lines.append("> ![\(Self.alt(note.title))](screens/\(note.fileName))")
                lines.append("")
            }
        }
```

Плюс два приватных хелпера рядом с существующим `clock(_:)` — текст в этих местах приходит от
модели, а `SpeakerResolution` выше по потоку намеренно сохраняет `|` внутри цитаты:

```swift
    /// A table cell holds text that came from the model. The evidence is a
    /// verbatim quote, and the parser upstream deliberately keeps any `|` it
    /// contains — unescaped, one such quote shifts its row's columns and
    /// usually wrecks the rest of the section.
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    /// Alt text sits inside `![…]`, where a bracket ends it early and takes
    /// the image link with it.
    private static func alt(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --filter TranscriptDocumentTests`
Expected: PASS — новые семь тестов и все существующие

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopMeetings/TranscriptDocument.swift Tests/CyclopMeetingsTests/TranscriptDocumentTests.swift
git commit -m "Документ показывает участников и то, что было на экране"
```

---

### Task 7: Стадии обработки в `.state.json`

**Files:**
- Modify: `Sources/CyclopMeetings/MeetingState.swift`
- Create: `Tests/CyclopMeetingsTests/MeetingStagesTests.swift`

**Interfaces:**
- Produces: `MeetingStages` со свойствами `transcribed`, `framesPlanned`, `framesExtracted`, `framesRead`, `participantsResolved`; `MeetingStateFile.stages: MeetingStages?` и параметр `stages:` в инициализаторе.

- [ ] **Step 1: Написать падающий тест**

```swift
import XCTest
@testable import CyclopMeetings

final class MeetingStagesTests: XCTestCase {
    func testStagesSurviveTheRoundTrip() throws {
        var stages = MeetingStages()
        stages.transcribed = true
        stages.framesExtracted = true

        let file = MeetingStateFile(state: .processing, duration: 60, stages: stages)
        let decoded = try MeetingStateFile.decode(try file.encoded())

        XCTAssertEqual(decoded.stages?.transcribed, true)
        XCTAssertEqual(decoded.stages?.framesExtracted, true)
        XCTAssertEqual(decoded.stages?.framesRead, false)
    }

    /// A file written before stages existed still has to decode: losing it
    /// costs the meeting, and the recording cannot be made again.
    func testOlderFileWithoutStagesStillDecodes() throws {
        let json = #"{"state":"ready","duration":60}"#.data(using: .utf8)!

        let decoded = try MeetingStateFile.decode(json)

        XCTAssertEqual(decoded.state, .ready)
        XCTAssertNil(decoded.stages)
    }

    func testFreshStagesAreAllUnfinished() {
        let stages = MeetingStages()

        XCTAssertFalse(stages.transcribed)
        XCTAssertFalse(stages.framesPlanned)
        XCTAssertFalse(stages.framesExtracted)
        XCTAssertFalse(stages.framesRead)
        XCTAssertFalse(stages.participantsResolved)
    }
}
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `swift test --filter MeetingStagesTests`
Expected: FAIL — `cannot find 'MeetingStages' in scope`

- [ ] **Step 3: Написать минимальную реализацию**

В `MeetingState.swift` добавить:

```swift
/// How far processing got.
///
/// The frame stages are expensive — decoding a frame is cheap, sending it to a
/// vision model is not — so a run interrupted after them must not pay twice.
/// Every field defaults to false so that a file written by an older version
/// decodes into «nothing done yet» rather than failing.
public struct MeetingStages: Codable, Sendable, Equatable {
    public var transcribed: Bool
    public var framesPlanned: Bool
    public var framesExtracted: Bool
    public var framesRead: Bool
    public var participantsResolved: Bool

    public init(
        transcribed: Bool = false,
        framesPlanned: Bool = false,
        framesExtracted: Bool = false,
        framesRead: Bool = false,
        participantsResolved: Bool = false
    ) {
        self.transcribed = transcribed
        self.framesPlanned = framesPlanned
        self.framesExtracted = framesExtracted
        self.framesRead = framesRead
        self.participantsResolved = participantsResolved
    }
}
```

В `MeetingStateFile` добавить хранимое свойство `public let stages: MeetingStages?` и параметр `stages: MeetingStages? = nil` в инициализатор перед `failure`.

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --filter MeetingStagesTests`
Expected: PASS, 3 теста

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopMeetings/MeetingState.swift Tests/CyclopMeetingsTests/MeetingStagesTests.swift
git commit -m "Статус помнит, какие стадии обработки уже оплачены"
```

---

### Task 8: Транспорт для картинок

**Files:**
- Modify: `Sources/CyclopDictation/CloudTranscription.swift`
- Modify: `Sources/Cyclop/Dictation/AudioTranscriptionClient.swift:75`
- Modify: `Tests/CyclopDictationTests/CloudTranscriptionTests.swift`

**Interfaces:**
- Produces: `CloudTranscription.jpegMimeType`, `CloudTranscription.requestBody(prompt:images:mimeType:) throws -> Data`, `AudioTranscriptionClient.complete(prompt:images:model:) async throws -> String`.

- [ ] **Step 1: Написать падающий тест**

Дописать в `CloudTranscriptionTests`:

```swift
    func testImageRequestCarriesPromptFirstThenEveryImage() throws {
        let body = try CloudTranscription.requestBody(
            prompt: "что на экране",
            images: [Data([0x01]), Data([0x02])],
            mimeType: CloudTranscription.jpegMimeType
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0]["text"] as? String, "что на экране")
        let first = try XCTUnwrap(parts[1]["inline_data"] as? [String: Any])
        XCTAssertEqual(first["mime_type"] as? String, "image/jpeg")
        XCTAssertEqual(first["data"] as? String, Data([0x01]).base64EncodedString())
    }

    func testImageRequestWithoutImagesIsStillValid() throws {
        let body = try CloudTranscription.requestBody(prompt: "текст", images: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])

        XCTAssertEqual(parts.count, 1)
    }
```

- [ ] **Step 2: Запустить тест и убедиться, что он падает**

Run: `swift test --filter CloudTranscriptionTests`
Expected: FAIL — `incorrect argument label in call (have 'prompt:images:mimeType:'...)`

- [ ] **Step 3: Написать минимальную реализацию**

В `CloudTranscription` рядом с существующими `requestBody` добавить:

```swift
    public static let jpegMimeType = "image/jpeg"

    /// Several frames in one request: the prompt names each frame by its
    /// timecode, so the order of the images is a convenience and not a
    /// contract. Batching is what keeps a meeting's worth of frames inside the
    /// request quota.
    public static func requestBody(
        prompt: String, images: [Data], mimeType: String = jpegMimeType
    ) throws -> Data {
        let payload = Request(
            contents: [
                Request.Content(
                    role: "user",
                    parts: [.init(text: prompt, inlineData: nil)]
                        + images.map {
                            .init(
                                text: nil,
                                inlineData: .init(
                                    mimeType: mimeType, data: $0.base64EncodedString()))
                        }
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
```

В `AudioTranscriptionClient` после `complete(prompt:model:)` добавить:

```swift
    /// A prompt with frames attached. Same round trip as `complete`, and the
    /// same reason it lives here: one place that knows the endpoint and the
    /// token.
    func complete(prompt: String, images: [Data], model: String) async throws -> String {
        guard let endpoint = CloudTranscription.endpoint(host: Self.host, model: model) else {
            throw Failure.notConfigured
        }
        return try await send(
            CloudTranscription.requestBody(prompt: prompt, images: images), to: endpoint)
    }
```

- [ ] **Step 4: Запустить тесты и убедиться, что они проходят**

Run: `swift test --filter CloudTranscriptionTests`
Expected: PASS — два новых теста и все существующие

- [ ] **Step 5: Коммит**

```bash
git add Sources/CyclopDictation/CloudTranscription.swift Sources/Cyclop/Dictation/AudioTranscriptionClient.swift Tests/CyclopDictationTests/CloudTranscriptionTests.swift
git commit -m "Запрос умеет нести кадры вместе с промптом"
```

---

### Task 9: Извлечение кадров и сравнение экранов

**Files:**
- Create: `Sources/Cyclop/Meetings/MeetingFrames.swift`

**Interfaces:**
- Consumes: ничего из предыдущих задач — тип принимает голые таймкоды, чтобы не зависеть от формы плана.
- Produces: `MeetingFrames.jpeg(from:at:) async -> [TimeInterval: Data]`, `MeetingFrames.differs(_:from:) -> Bool`, `MeetingFrames.changeThreshold`.

Тестов XCTest здесь нет: тип целиком про AVFoundation и настоящий файл, как `MeetingAudio` рядом. Проверяется пробой (шаг 4).

- [ ] **Step 1: Написать реализацию**

```swift
import AVFoundation
import AppKit
import CoreGraphics
import Foundation

/// Frames out of the recording, and whether two of them show the same screen.
///
/// No ffmpeg: the core spec rejected bundling it (~100 MB) and nothing here
/// needs it. `AVAssetImageGenerator` decodes a frame at a time, and telling
/// «same screen» from «different screen» takes a 64-pixel thumbnail, not a
/// video filter.
enum MeetingFrames {
    /// Mean per-pixel difference above which two frames are called different.
    /// A cursor moving over a static page stays well below it; a switched tab
    /// clears it easily.
    static let changeThreshold: Double = 0.04

    /// Wide enough that console text and code survive the JPEG, small enough
    /// that a dozen frames fit in one request.
    private static let maxWidth: CGFloat = 1600
    private static let compression: CGFloat = 0.7

    /// Frames keyed by the time actually requested, so a caller can match them
    /// back to candidates without relying on order.
    static func jpeg(from video: URL, at times: [TimeInterval]) async -> [TimeInterval: Data] {
        guard !times.isEmpty else { return [:] }

        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: 0)
        // A demo is mostly static, so a frame half a second off is the same
        // screen. Zero tolerance would force decoding from the previous
        // keyframe and cost seconds per frame for nothing.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var frames: [TimeInterval: Data] = [:]
        for time in times {
            do {
                let image = try await generator.image(
                    at: CMTime(seconds: time, preferredTimescale: 600)).image
                guard let data = encode(image) else { continue }
                frames[time] = data
            } catch {
                // One unreadable frame is not worth the meeting. The plan
                // simply loses that moment and says so in the header.
                NSLog("Cyclop: meeting frame at %.0f failed (%@)", time, error.localizedDescription)
            }
        }
        return frames
    }

    /// Whether the second frame shows something other than the first.
    ///
    /// Compared as 64×64 greyscale: the question is «did the screen change»,
    /// not «how much», and at that size a moved window matters while a blinking
    /// caret does not.
    static func differs(_ frame: Data, from previous: Data) -> Bool {
        guard let a = thumbnail(frame), let b = thumbnail(previous) else { return true }
        let total = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) / 255 }
        return total / Double(a.count) > changeThreshold
    }

    private static func encode(_ image: CGImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(
            using: .jpeg, properties: [.compressionFactor: compression])
    }

    private static func thumbnail(_ data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }
}
```

- [ ] **Step 2: Собрать и убедиться, что компилируется**

Run: `swift build`
Expected: сборка без ошибок и предупреждений

- [ ] **Step 3: Прогнать весь набор тестов**

Run: `swift test`
Expected: PASS, все тесты проекта

- [ ] **Step 4: Проба на настоящей записи**

Взять любой mp4 длиннее двух минут, скопировать во временную папку (файлы пользователя не трогаем) и прогнать через `swift run` или отладочный вызов:

- достать кадры на 10, 20 и 90 секундах;
- убедиться, что все три вернулись и открываются просмотрщиком;
- проверить, что `differs` даёт `false` для двух кадров одного статичного экрана и `true` для кадров по разные стороны переключения;
- замерить время: три кадра из часового файла должны занять единицы секунд.

Записать замеры в `AGENTS.md`, раздел «Грабли этого проекта», если что-то повело себя не так, как здесь написано.

- [ ] **Step 5: Коммит**

```bash
git add Sources/Cyclop/Meetings/MeetingFrames.swift
git commit -m "Кадры достаются из записи без ffmpeg"
```

---

### Task 10: Стадии в обработчике

Сборка всего вместе: кандидаты, план, кадры, разбор, участники, документ.

**Files:**
- Modify: `Sources/Cyclop/Meetings/MeetingProcessor.swift`
- Modify: `Sources/CyclopMeetings/MeetingProgress.swift`
- Modify: `Sources/CyclopMeetings/MeetingFolder.swift`
- Modify: `Sources/Cyclop/UI/MeetingsPane.swift:174-181`
- Modify: `Resources/ru.lproj/Localizable.strings`, `Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: всё, произведённое задачами 1–9.
- Produces: `MeetingFolder.screensURL`, `MeetingProgress.frames(index:count:)` и `MeetingProgress.participants`.

- [ ] **Step 1: Добавить папку кадров и шаги прогресса**

В `MeetingFolder`:

```swift
    /// Frames live in a subfolder rather than beside the transcript: a dozen
    /// pictures in the meeting's root would bury the three files that matter.
    public var screensURL: URL { url.appendingPathComponent("screens", isDirectory: true) }
```

В `MeetingProgress` после `case summary` добавить:

```swift
    /// One batch of frames on its way to the model, counted from 1.
    case frames(index: Int, count: Int)
    /// The request that turns «Участник 2» into a name.
    case participants
```

`MeetingsPane.text(for:)` — исчерпывающий `switch` без `default`, поэтому без правки проект не соберётся. Ключ `participants` там уже занят системной дорожкой, так что новые строки получают свои имена:

```swift
    private static func text(for step: MeetingProgress) -> String {
        switch step {
        case .preparing: return localized("preparation")
        case .summary: return localized("summary")
        case .participants: return localized("naming")
        case .frames(let index, let count):
            return "\(localized("screens")) \(index)/\(count)"
        case .lane(let lane, let index, let count):
            let name = lane == .system ? localized("participants") : localized("microphone")
            return "\(name) \(index)/\(count)"
        }
    }
```

В `Resources/ru.lproj/Localizable.strings` рядом со строкой `"summary"`:

```
"screens" = "экраны";
"naming" = "имена";
```

В `Resources/en.lproj/Localizable.strings` там же:

```
"screens" = "screens";
"naming" = "names";
```

- [ ] **Step 2: Написать тест на папку кадров**

Дописать в `MeetingFolderTests`:

```swift
    func testScreensFolderSitsInsideTheMeeting() {
        let folder = MeetingFolder(
            root: URL(fileURLWithPath: "/tmp"), startedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(folder.screensURL.lastPathComponent, "screens")
        XCTAssertEqual(folder.screensURL.deletingLastPathComponent(), folder.url)
    }
```

- [ ] **Step 3: Запустить тест и убедиться, что он падает, затем добавить свойство**

Run: `swift test --filter MeetingFolderTests`
Expected: сначала FAIL — `value of type 'MeetingFolder' has no member 'screensURL'`, после правки PASS

- [ ] **Step 4: Встроить стадии в `MeetingProcessor`**

В `process(_:recording:ownerName:progress:)` после слияния лент и **до** запроса итогов вставить:

```swift
        // Frames and names are auxiliary in the same sense the summary is:
        // their failure costs a section, not the meeting. Everything here is
        // wrapped so that a transcript is written no matter what went wrong.
        var notes: [ScreenNote] = []
        var skipped = 0
        var participants: [Participant] = []
        var named = segments

        let lines = segments.map(\.line).joined(separator: "\n")

        if FileManager.default.fileExists(atPath: folder.videoURL.path) {
            do {
                (notes, skipped) = try await readScreens(
                    folder: folder, transcript: lines,
                    duration: recording.duration, progress: progress)
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
            }
        } catch {
            NSLog("Cyclop: meeting participants failed (%@)", error.localizedDescription)
        }
```

Дальше итоги считать по `named`, а не по `segments`, и передать новое в документ:

```swift
        let document = TranscriptDocument(
            date: folder.startedAt,
            duration: recording.duration,
            videoFileName: MeetingFolder.videoFileName,
            summary: summary,
            segments: named,
            hasMicrophoneLane: !microphone.isEmpty,
            participants: participants,
            notes: notes,
            skippedFrames: skipped
        )
```

Добавить приватный метод:

```swift
    /// From a transcript to described screens on disk.
    ///
    /// Returns what was kept and how many moments were dropped — the header
    /// says both, because silently losing coverage reads as full coverage.
    private func readScreens(
        folder: MeetingFolder,
        transcript: String,
        duration: TimeInterval,
        progress: @escaping @Sendable (MeetingProgress) -> Void
    ) async throws -> ([ScreenNote], Int) {
        let budget = FramePlan.budget(forDuration: duration)
        let answer = try await client.complete(
            prompt: MeetingPrompts.frameCandidates(for: transcript, budget: budget),
            model: Self.model)
        let planned = FramePlan.selected(
            from: FrameCandidateParser.candidates(from: answer), budget: budget)
        guard !planned.isEmpty else { return ([], 0) }

        let frames = await MeetingFrames.jpeg(
            from: folder.videoURL, at: planned.map(\.start))

        // The third filter: a frame showing the same screen as the one kept
        // before it buys nothing and costs a request.
        var kept: [(candidate: FrameCandidate, data: Data)] = []
        for candidate in planned {
            guard let data = frames[candidate.start] else { continue }
            if let previous = kept.last?.data, !MeetingFrames.differs(data, from: previous) {
                continue
            }
            kept.append((candidate, data))
        }
        let dropped = planned.count - kept.count

        try FileManager.default.createDirectory(
            at: folder.screensURL, withIntermediateDirectories: true)

        var notes: [ScreenNote] = []
        let batches = stride(from: 0, to: kept.count, by: 4).map {
            Array(kept[$0..<min($0 + 4, kept.count)])
        }
        for (index, batch) in batches.enumerated() {
            progress(.frames(index: index + 1, count: batches.count))
            let described = try await client.complete(
                prompt: MeetingPrompts.screenNotes(for: batch.map {
                    (timecode: timecode($0.candidate.start),
                     expectation: $0.candidate.expectation,
                     context: context(around: $0.candidate.start, in: transcript))
                }),
                images: batch.map(\.data),
                model: Self.model)
            notes += ScreenNoteParser.notes(from: described)
        }

        // Only the frames the model found worth describing are written: an
        // empty desktop should not leave a file behind either.
        var written = 0
        for note in notes where note.isUseful {
            guard let data = kept.first(where: { $0.candidate.start == note.start })?.data
            else { continue }
            try? data.write(to: folder.screensURL.appendingPathComponent(note.fileName))
            written += 1
        }
        return (notes, dropped + max(0, kept.count - written))
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
```

- [ ] **Step 5: Собрать и прогнать все тесты**

Run: `swift build && swift test`
Expected: PASS, все тесты проекта

- [ ] **Step 6: Проверить полный цикл вручную**

Записать короткую встречу с демонстрацией экрана — открыть в браузере страницу с заметным заголовком и сказать про неё «вот здесь видно». Остановить, дождаться обработки, открыть `transcript.md`:

- в шапке есть таблица участников;
- после реплики про экран стоит блок с описанием и ссылкой на файл;
- файл лежит в `screens/` и открывается;
- счётчик кадров в шапке сходится с числом блоков.

- [ ] **Step 7: Коммит**

```bash
git add Sources/Cyclop/Meetings/MeetingProcessor.swift Sources/CyclopMeetings/MeetingProgress.swift Sources/CyclopMeetings/MeetingFolder.swift Tests/CyclopMeetingsTests/MeetingFolderTests.swift
git commit -m "Обработка достаёт кадры и подписывает говорящих"
```

---

## Что этот план сознательно не делает

**Роли не запрашиваются.** `MeetingPrompts.roles(transcript:names:)` написан в Task 5 и остаётся неиспользованным до отдельной задачи: он требует ещё одного запроса и своего парсера, а имена в ленте полезны и без ролей. Участники пока идут с `role: nil`, таблица показывает прочерк.

**Календарь не подключён.** `ParticipantRoster.candidateNames` принимает `calendar:` и получает пустой массив: `CalendarStore` сейчас не читает участников события, а добавление `EKEvent.attendees` и сопоставление встречи с папкой — своя задача со своим разрешением.

**Стадии пишутся, но не читаются.** `MeetingStages` из Task 7 сохраняется в `.state.json`; повторный запуск пока проходит все стадии заново. Возобновление с середины — следующий шаг, и он дешевле, когда стадии уже есть на диске.

Всё три помечены в спеке как часть замысла, но каждое требует своего цикла и не блокирует то, ради чего план написан: описанные экраны и имена вместо номеров.
