import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel
    /// This screen's share of the panel. Everything the pointer decides is
    /// here; everything shown is in `vm`, the same on every display.
    @ObservedObject var panel: PanelState

    @State private var hoveringIndicator = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { panel.isActive }
    private var size: CGSize { panel.bodySize }
    private var topRadius: CGFloat { isOpen ? Theme.openTopRadius : Theme.collapsedTopRadius }

    var body: some View {
        // The shape is wider than the body by `topRadius` on each side: that
        // slack is where the concave shoulders live, so it must not be clipped.
        ZStack(alignment: .top) {
            NotchShape(
                topRadius: topRadius,
                bottomRadius: isOpen ? Theme.openBottomRadius : Theme.collapsedBottomRadius
            )
            .fill(Color.black)
            .frame(width: size.width + 2 * topRadius, height: size.height)
            .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 18, y: 8)

            VStack(spacing: 0) {
                header
                // Drawn inside the same frame the open/closed animation
                // already sizes and clips, same as `content` below it. This
                // view never reads or sets `isOpen` itself — `NotchController`
                // is what forces the panel open the moment `vm.meetings.offer`
                // turns true (a collapsed panel has no room for two buttons)
                // and hands it back to the pointer once the card clears — so
                // by the time this `if` is ever true, `isOpen` is already
                // true too, and the row this card draws is not the sliver
                // that would get clipped away collapsed.
                if vm.meetings.offer {
                    RecordingOffer(
                        accept: { vm.meetings.acceptOffer() },
                        dismiss: { vm.meetings.dismissOffer() }
                    )
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : .bouncy, value: vm.meetings.offer)
                }
                if isOpen {
                    content
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()

            // Dictation shows itself here instead of expanding the panel: the
            // notch lights up under its own lower edge and nothing else moves.
            // Sits outside the clipped stack above, so it is drawn on the
            // transparent part of the window rather than on the black body.
            if let mood = waveMood {
                // Taller than the strip it draws: a Canvas clips to its own
                // bounds, and a blurred glow reaching the edge is cut off there
                // — a hard line across the haze, the one thing a glow must not
                // have. Overlapping the notch's lower edge rather than sitting
                // below it, so the light reads as spilling out of the cutout
                // instead of hanging under it as a separate widget.
                dictationAnimation(mood)
                    .frame(width: panel.geometry.notchSize.width, height: 130)
                    .offset(y: panel.geometry.notchSize.height - vm.waveStyle.coreInset + 2)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.openAnimation, value: isOpen)
        .animation(Theme.paneAnimation, value: vm.tab)
        .animation(Theme.contentAnimation, value: waveMood)
    }

    /// Nil whenever dictation is idle — and then the wave view does not exist
    /// at all, so its display-linked redraw is not running either. The panel
    /// costs 0 % CPU at rest, and a decoration is not a reason to change that.
    @ViewBuilder
    private func dictationAnimation(_ mood: DictationMood) -> some View {
        switch vm.waveStyle {
        case .siri:
            DictationSiriWave(mood: mood) { [vm] in vm.dictation.micLevel }
        case .strands:
            DictationStrands(mood: mood) { [vm] in vm.dictation.micLevel }
        }
    }

    private var waveMood: DictationMood? {
        // Not while the panel is open: the strip would be drawn across the
        // header and the pane, and the open panel says the same thing in words
        // ("Запись", "Распознаю…") in the place the eye is already looking.
        guard !isOpen else { return nil }
        switch vm.dictation.state {
        case .recording: return .listening
        case .transcribing: return .thinking
        default: return nil
        }
    }

    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. Nothing interactive goes in
    // this row; the tab switcher lives in the rail below.

    private var header: some View {
        HStack(spacing: 0) {
            if isOpen {
                Text(vm.tab.title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 16)
                    .id(vm.tab)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            // This slot sits exactly over the physical notch, and — unlike
            // the title and `trailing` either side of it — is not gated on
            // `isOpen`: it is the one part of the header that is still there
            // when the panel is collapsed to nothing else. That makes it the
            // right place for the recording dot while collapsed, and the
            // only place for it: `trailing`'s own `.meetings` case already
            // says the same thing once the panel is open on that tab, so
            // showing it here too while open would just repeat it.
            //
            // Centred only on a physical notch, where `collapsedDepth` covers
            // this whole row and the alignment is invisible either way. On a
            // synthetic one `collapsedDepth` is a deliberately shallow strip
            // hugging the top edge (see `NotchGeometry`, protecting menu bar
            // icons it sits on top of), while this row is drawn the full,
            // taller `notchSize.height` — centred content would then sit
            // below the only band that actually takes clicks, unreachable
            // without opening the panel first. Top-aligning here puts the
            // dot's own top edge, not its middle, at the row's top — which is
            // where that band starts.
            ZStack(alignment: panel.geometry.isPhysical ? .center : .top) {
                Color.clear
                if !isOpen {
                    recordingIndicator
                }
            }
            .frame(width: panel.geometry.notchSize.width, height: panel.geometry.notchSize.height)
            Spacer(minLength: 0)
            if isOpen {
                trailing
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .frame(height: panel.geometry.notchSize.height)
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : Theme.contentAnimation,
            value: vm.meetings.isRecording
        )
    }

    /// Recording shows in the collapsed panel regardless of which tab was
    /// open before it collapsed: it is the one state worth interrupting
    /// everything else for, and stopping it must not require opening the
    /// panel first — the button below works from right here, collapsed.
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

    @ViewBuilder
    private var trailing: some View {
        switch vm.tab {
        case .media:
            HStack(spacing: 6) {
                if vm.media.track != nil {
                    EqualizerBars(isAnimating: vm.media.isPlaying)
                }
                Text(vm.media.sourceName ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        case .shelf:
            counter(vm.shelf.items.count)
        case .clipboard:
            counter(vm.clipboard.items.count)
        case .snippets:
            counter(vm.snippets.items.count)
        case .dictation:
            // Recording and transcribing show here regardless of what the
            // pane itself is drawing below — the permission prompt and the
            // failure screen both replace the list, so the header is the one
            // place that always reflects the live state at a glance.
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
                // `count`, not `history.count`: the header must not shrink
                // while someone types a search query into the pane below it.
                counter(vm.dictation.count)
            }
        case .calendar:
            if let next = vm.calendar.next {
                Text(CalendarPane.countdown(to: next, from: vm.calendar.now))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(next.isRunning ? Color.white.opacity(0.8) : Theme.tertiary)
            }
        case .translate:
            // Nothing: the columns name both languages already, and the strip
            // is the one part of the panel worth not spending on a repeat.
            EmptyView()
        case .notes:
            NotesCounter(notes: vm.notes)
        case .teleprompter:
            EmptyView()
        case .meetings:
            recordingIndicator
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - Body

    private var content: some View {
        HStack(spacing: 14) {
            Rail(vm: vm, panel: panel, tabs: NotchViewModel.Tab.leftRail)
            panes
            Rail(vm: vm, panel: panel, tabs: NotchViewModel.Tab.rightRail)
        }
        .padding(.horizontal, 14)
        // The body's height is measured from this same number, so the two
        // cannot drift apart into a rail that does not fit.
        .padding(.bottom, NotchGeometry.bodyBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The rail is vertical and
        // the panes are unrelated, so a direction would only be decoration.
        ZStack {
            pane
                .id(vm.tab)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .scale(scale: 0.97))
                        .animation(Theme.paneIn),
                    removal: .opacity
                        .combined(with: .scale(scale: 1.02))
                        .animation(Theme.paneOut)
                ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var pane: some View {
        switch vm.tab {
        case .media:
            MediaPane(media: vm.media)
        case .shelf:
            ShelfPane(shelf: vm.shelf, isTargeted: panel.isDropTargeted)
        case .clipboard:
            ClipboardPane(clipboard: vm.clipboard, privacy: vm.privacy)
        case .calendar:
            CalendarPane(calendar: vm.calendar, privacy: vm.privacy)
        case .snippets:
            SnippetsPane(
                snippets: vm.snippets,
                privacy: vm.privacy,
                wantsKeyboard: $panel.wantsKeyboard,
                claimKeyboard: { if vm.tabHasField { panel.wantsKeyboard = true } }
            )
        case .dictation:
            DictationPane(
                dictation: vm.dictation,
                wantsKeyboard: $panel.wantsKeyboard,
                openSettings: { panel.select(.settings) }
            )
        case .translate:
            TranslatePane(translator: vm.translator, wantsKeyboard: $panel.wantsKeyboard)
        case .notes:
            NotesPane(notes: vm.notes, privacy: vm.privacy, wantsKeyboard: $panel.wantsKeyboard)
        case .teleprompter:
            TeleprompterPane(prompter: vm.teleprompter, wantsKeyboard: $panel.wantsKeyboard)
        case .meetings:
            MeetingsPane(meetings: vm.meetings)
        case .settings:
            SettingsPane(shelf: vm.shelf, dictation: vm.dictation)
        }
    }
}

/// Watches the note store itself rather than reading through the view model:
/// notes are born and deleted inside the pane while this counter is on
/// screen, and the view model deliberately does not forward keystroke-driven
/// stores.
private struct NotesCounter: View {
    @ObservedObject var notes: NoteStore

    var body: some View {
        if !notes.notes.isEmpty {
            Text("\(notes.notes.count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// Tab switcher.
///
/// Hovering switches tabs, but only after the pointer has stopped: a pointer
/// crossing the rail on its way somewhere else is gone in a few dozen
/// milliseconds, while one that came to choose stays put. The same dwell
/// threshold is what separates "the mouse was flung across the top of the
/// screen" from "the mouse came to the notch" in `PointerWatcher`.
private struct Rail: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var panel: PanelState
    /// Which icons this rail carries — there are two rails now, one per side.
    let tabs: [NotchViewModel.Tab]

    @State private var hovered: NotchViewModel.Tab?

    /// Long enough to swallow a pass-through, short enough that a deliberate
    /// hover still feels like it answered instantly.
    private let dwell = Duration.milliseconds(150)

    var body: some View {
        VStack(spacing: NotchGeometry.railSpacing) {
            ForEach(tabs) { tab in
                Button {
                    panel.select(tab)
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: panel.geometry.railIconHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(fill(for: tab))
                        )
                        .foregroundStyle(vm.tab == tab ? Color.white : Theme.tertiary)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        // A render-time transform. Growing the frame instead
                        // would re-lay out the rail on every hover, and layout
                        // that runs on pointer movement is exactly the kind
                        // that shows up as a stutter.
                        .scaleEffect(hovered == tab ? 1.15 : 1)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = tab
                    } else if hovered == tab {
                        hovered = nil
                    }
                }
            }
        }
        // The hovered icon grows by 15 %, and the frames below clip to their
        // own bounds: without this the enlarged first and last icons would be
        // shaved flat top and bottom.
        .padding(.vertical, 3)
        .frame(width: 30)
        // Centred in the height an ordinary tab has, then that block pinned to
        // the top of whatever height this tab actually got. On the ordinary
        // tabs the two are the same and nothing moves; on the teleprompter the
        // extra 192 pt goes to the script below, and the icons stay put.
        .frame(height: panel.geometry.standardContentHeight, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Theme.contentAnimation, value: hovered)
        // Moving to another icon cancels the pending switch along with the
        // task, so only the icon actually rested on ever wins.
        .task(id: hovered) {
            guard let hovered, hovered != vm.tab else { return }
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            panel.select(hovered)
        }
    }

    private func fill(for tab: NotchViewModel.Tab) -> Color {
        if vm.tab == tab { return Theme.surfaceHover }
        return hovered == tab ? Theme.surface : .clear
    }
}
