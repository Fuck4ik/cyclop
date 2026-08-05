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

    /// Original encoded line for each record, used to preserve unknown JSON fields
    /// when retention rewrites the file. Nil for records added after the last reload.
    private var originalLines: [DictationRecord.ID: String] = [:]

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

    /// Loads history from file, newest first.
    /// Preserves original encoded lines to keep unknown JSON fields on rewrite.
    public func reload() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            items = []
            originalLines = [:]
            return
        }

        var loaded: [DictationRecord] = []
        originalLines = [:]

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(line)
            if let record = DictationRecord.decode(line: lineStr) {
                loaded.append(record)
                originalLines[record.id] = lineStr
            }
        }

        items = loaded.sorted { $0.at > $1.at }
    }

    /// Appends a record to history.
    /// For normal append: writes atomically to the end of file using O_APPEND.
    /// For retention: rewrites the entire file, using original lines when available
    /// to preserve unknown JSON fields.
    public func append(_ record: DictationRecord) {
        // Insert in correct position by date (newest first)
        let insertIndex = items.firstIndex { $0.at < record.at } ?? items.count
        items.insert(record, at: insertIndex)

        // Apply retention limit, trimming oldest
        let didTrim = items.count > limit
        if didTrim {
            items.removeLast(items.count - limit)
        }

        persist(newRecord: record, forceRewrite: didTrim)
    }

    /// Persists items to disk.
    /// - If just appending one new record without exceeding limit: appends single line atomically.
    /// - If retention trimmed history: rewrites entire file, preserving original lines.
    private func persist(newRecord: DictationRecord? = nil, forceRewrite: Bool = false) {
        // Determine if we need a full rewrite: happened if retention trimmed the list
        let needsRewrite = forceRewrite

        if needsRewrite {
            // Rewrite mode: preserve original lines, re-encode only new ones
            let sortedItems = items.sorted { $0.at < $1.at }
            var lines: [String] = []

            for record in sortedItems {
                if let original = originalLines[record.id] {
                    lines.append(original)
                } else {
                    if let encoded = try? record.encodedLine() {
                        lines.append(encoded)
                    }
                }
            }

            let body = lines.joined(separator: "\n") + "\n"
            try? body.write(to: file, atomically: true, encoding: .utf8)
        } else {
            // Append mode: add only the passed record atomically
            guard let record = newRecord,
                  let line = try? record.encodedLine() else {
                return
            }

            // Use FileHandle for atomic append
            let lineWithNewline = line + "\n"
            guard let data = lineWithNewline.data(using: .utf8) else { return }

            // Open or create file with O_APPEND flag
            let path = file.path
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }

            _ = data.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
        }
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
