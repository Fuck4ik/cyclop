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
}
