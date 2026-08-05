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
