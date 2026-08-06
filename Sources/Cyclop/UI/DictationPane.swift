import SwiftUI
import CyclopDictation

/// History of what was dictated, laid out like the snippets tab it sits next
/// to: a search row above a list, click to copy. The one thing snippets does
/// not have is a state that is not "here is the list" — recording and
/// transcribing are shown here, and mirrored in the header by `trailing` in
/// `NotchContentView`, so the state is visible whether the panel is open to
/// this tab or not.
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

    // Laid out like `CalendarPane.permissionPrompt`: a title, a smaller and
    // dimmer explanation below it, then a capsule button — not one paragraph
    // doing both jobs at once.
    private var permission: some View {
        VStack(spacing: 9) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("Dictate into any app")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("Cyclop needs the microphone and Accessibility: one\nto hear you, the other to see the key and paste the text.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
            Button {
                dictation.enable()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.surfaceHover))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
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
            // Without this, a steady failure (no microphone, a worker that
            // will not start) leaves the tab showing nothing else ever again
            // — there is no operation to retry, but there is a history to go
            // back to, and this is the same recompute `refreshPermission()`
            // already runs on every visit to the tab, just reachable without
            // having to leave and come back.
            Button("Retry") { dictation.refreshPermission() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
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

    /// One line for the row. With no search, the start of the text — which is
    /// also what a click copies, so what is shown is what is taken. While
    /// searching, a window around the match instead: `filtered(_:)` searches
    /// up to 1800 characters, and a hit in the middle of a long dictation
    /// would otherwise land the record on the list with nothing on screen to
    /// show why.
    private static func preview(_ text: String, matching query: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same options as `DictationHistoryStore.filtered`, so the row that
        // ends up on screen is always one the highlighted range actually
        // explains.
        guard !needle.isEmpty,
              let match = flat.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        else { return flat }

        let radius = 40
        let start = flat.index(match.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(match.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        var window = String(flat[start..<end])
        if start > flat.startIndex { window = "…" + window }
        if end < flat.endIndex { window += "…" }
        return window
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : "waveform")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 14)
            Text(Self.preview(record.text, matching: dictation.query))
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
