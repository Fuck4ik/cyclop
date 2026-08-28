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
    /// Where the address and the key are filled in. The cloud row is useless
    /// until they are, and a row that does nothing when clicked reads as
    /// broken — so it takes the user there instead.
    var openSettings: () -> Void = {}

    @FocusState private var searching: Bool

    var body: some View {
        VStack(spacing: 6) {
            switch dictation.state {
            case .needsPermission:
                permission
            case .failed(let message):
                failure(message)
            // The catalog is one screen, whether it was asked for or forced:
            // a download draws its bar inside the row it belongs to, so there
            // is nothing a separate progress screen would add except a place
            // where the other models stop being visible.
            case .needsModel:
                catalog(dismissible: false)
            case .downloading:
                catalog(dismissible: dictation.showsCatalog)
            default:
                if dictation.showsCatalog {
                    catalog(dismissible: true)
                } else {
                    search
                    list
                }
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
            // The way back to the catalog once a model is in place — without
            // it, choosing a model would be a one-time decision made on the
            // first launch and never revisitable.
            Button { dictation.toggleCatalog() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
            .buttonStyle(.plain)
            .help(localized("Recognition model"))
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
            // Which of the two is still missing. Without this the screen
            // repeats the same request after one of them is already granted,
            // and the button looks like it does nothing.
            VStack(alignment: .leading, spacing: 3) {
                permissionRow(localized("Microphone"), granted: !dictation.missing.microphone, pane: .microphone)
                permissionRow(localized("Accessibility"), granted: !dictation.missing.accessibility, pane: .accessibility)
            }
            .padding(.top, 1)
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

    /// A line per permission, and each one is a way in: clicking what is still
    /// missing opens the very pane where its switch lives. The system dialog
    /// is macOS's to show or withhold — this route always works.
    private func permissionRow(
        _ title: String,
        granted: Bool,
        pane: DictationController.SettingsPane
    ) -> some View {
        Button {
            DictationController.openSettings(pane)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 9))
                    .foregroundStyle(granted ? Color.green.opacity(0.8) : Theme.tertiary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(granted ? Theme.secondary : Theme.tertiary)
                if !granted {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(localized("Open in System Settings"))
    }

    // MARK: - Models

    /// Everything about models on one screen: which one dictates, which are on
    /// disk, what each weighs, and the bar of whatever is arriving. The same
    /// tab rather than a window of its own — models exist for dictation, and
    /// dictation lives here.
    ///
    /// `dismissible` is false on the screen someone lands on with no model at
    /// all: there is nothing behind it to go back to.
    private func catalog(dismissible: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if dismissible {
                    Button { dictation.toggleCatalog() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Text(dismissible ? "Recognition model" : "Pick a recognition model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(dictation.models) { model in
                        ModelRow(
                            model: model,
                            progress: dictation.downloadingID == model.id ? currentProgress : nil,
                            select: {
                                if model.id == DictationController.cloudModelID, !model.ready {
                                    openSettings()
                                } else {
                                    dictation.download(model.id)
                                }
                            },
                            delete: { dictation.delete(model.id) },
                            configure: openSettings
                        )
                    }
                }
            }
            // Only while a take is waiting: on a fresh machine the first phrase
            // is recorded during the download, and the point is that it is not
            // lost — worth saying, but only when it is true.
            if dictation.isWaitingToTranscribe {
                Text("Your words will be pasted once it is here.")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentProgress: DownloadProgress? {
        if case .downloading(let progress) = dictation.state { return progress }
        return nil
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

/// One model in the catalog: what it is good for, what it weighs, whether it
/// is the one dictating, and — while it is being fetched — how far along.
private struct ModelRow: View {
    let model: DictationModel
    let progress: DownloadProgress?
    let select: () -> Void
    let delete: () -> Void
    /// Only the cloud row has anything to configure — the address and the key.
    let configure: () -> Void
    @State private var hovering = false

    /// The cloud row is not a checkpoint: nothing to download, nothing to
    /// delete, and no megabytes to show on the right.
    private var isCloud: Bool { model.sizeMB == 0 }

    private var size: String {
        let (value, isGigabytes) = model.size
        let number = isGigabytes
            ? String(format: "%.1f", value).replacingOccurrences(of: ".", with: decimalSeparator)
            : String(Int(value.rounded()))
        return "\(number) \(localized(isGigabytes ? "GB" : "MB"))"
    }

    private var decimalSeparator: String {
        Locale(identifier: appLanguage).decimalSeparator ?? "."
    }

    /// The left mark is state and only state, the same three answers for every
    /// row: ◉ dictating, ✓ ready but idle, and not-ready. Not-ready differs by
    /// what would fix it — ↓ for weights that are missing, ○ for a cloud model
    /// that is merely unconfigured, since there is nothing to download.
    /// Configuring it is an action, and actions live on the right.
    private var mark: (name: String, color: Color) {
        if model.selected, model.ready { return ("largecircle.fill.circle", .white) }
        if model.ready { return ("checkmark.circle", Color.green.opacity(0.8)) }
        if isCloud { return ("circle", Theme.tertiary) }
        return ("arrow.down.circle", Theme.tertiary)
    }

    private var helpText: String {
        if isCloud, !model.ready { return "Set the address and key in settings" }
        return model.ready ? "Click to dictate with this one" : "Click to download"
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: mark.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(mark.color)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    // Whisper's own name for the checkpoint, not a nickname:
                    // the point of this list is to know exactly which model is
                    // running, and "Large v3 Turbo Q4" says that where
                    // "Fast" only hinted at it. Not localized — model names
                    // are the same in every language.
                    Text(model.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    Text(isCloud ? model.detail : localized(model.detail))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                // Nothing to delete while it is still arriving, and the bin
                // would sit exactly where the eye is watching the bar.
                if model.ready, progress == nil, hovering, !isCloud {
                    Button(action: delete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(localized("Delete to free up space"))
                }
                // Always shown, not only on hover: an unconfigured cloud row
                // has nothing else to point at.
                if isCloud {
                    Button(action: configure) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 10))
                            .foregroundStyle(model.ready ? Theme.secondary : .white)
                    }
                    .buttonStyle(.plain)
                    .help(localized("Address and key"))
                }
                if !isCloud {
                    Text(size)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
            if let progress {
                HStack(spacing: 7) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surfaceHover).frame(height: 4)
                            Capsule()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: geo.size.width * max(0, min(1, progress.fraction)), height: 4)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(height: 4)
                    if progress.isDeterminate {
                        Text(verbatim: "\(Int(progress.downloadedMB)) / \(Int(progress.totalMB))")
                            .font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .padding(.leading, 23)
                .animation(Theme.contentAnimation, value: progress.fraction)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.surfaceHover : Theme.surface))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if progress == nil { select() } }
        .help(localized(helpText))
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: progress == nil)
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

    private var isPlaying: Bool { record.audio != nil && dictation.playingAudio == record.audio }

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
            // Stays visible while playing even after the pointer leaves: the
            // sound is still going, and the only way to stop it is this button.
            if record.audio != nil, hovering || isPlaying {
                Button { dictation.play(record) } label: {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(isPlaying ? .white : Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized(isPlaying ? "Stop playback" : "Play the recording"))
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
