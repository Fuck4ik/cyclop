import Foundation

/// What the model is asked for.
///
/// The vocabulary is a shortened variant of the one the local Whisper prompt
/// carries — the same list up to React, without the Swift and MLX terms that
/// belong to dictating code and not to a meeting. It is here for the same
/// reason it is there: without it English technical terms come back
/// transliterated into Cyrillic. The filler rule spells the fillers out
/// instead of saying "remove filler words" — the general wording makes the
/// model rewrite whole sentences rather than clean them.
///
/// Not shared with `CloudTranscription.prompt` on purpose: that one is tuned
/// for dictation and is not to be edited for a meeting's sake.
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
}
