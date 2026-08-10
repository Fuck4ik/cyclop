import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, snippets, calendar, translate, dictation, notes, settings
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .media: return "music.note"
            case .shelf: return "tray.full.fill"
            case .clipboard: return "list.clipboard.fill"
            case .snippets: return "pin.fill"
            case .dictation: return "waveform"
            case .calendar: return "calendar"
            case .translate: return "translate"
            case .notes: return "note.text"
            case .settings: return "gearshape.fill"
            }
        }

        var title: String {
            switch self {
            case .media: return localized("Music")
            case .shelf: return localized("Shelf")
            case .clipboard: return localized("Clipboard")
            case .snippets: return localized("Snippets")
            case .dictation: return localized("Dictation")
            case .calendar: return localized("Calendar")
            case .translate: return localized("Translate")
            case .notes: return localized("Notes")
            case .settings: return localized("Settings")
            }
        }

        /// Tabs that can show a field, at least in some state. Translate,
        /// snippets and notes always do; dictation only in its default state —
        /// see `NotchViewModel.tabHasField`, which is what actually decides
        /// whether to grab the keyboard.
        var needsKeyboard: Bool {
            self == .translate || self == .snippets || self == .dictation || self == .notes
        }


        /// Which rail the icon sits on. The left one carries the original six
        /// and is full — icon height is a ceiling now, not a constant (#26,
        /// #27), so a seventh icon would not overflow the panel, but it would
        /// shrink every icon on the rail to make room, which is the same
        /// objection in a quieter voice. Growth continues in a second column
        /// on the right, which the scratch notes open. Settings joins that
        /// column rather than the content rail: it is not something to hover
        /// past on the way to a track or a calendar, so it sits last,
        /// furthest from the tabs people actually rest on.
        static let leftRail: [Tab] = [.media, .shelf, .clipboard, .snippets, .calendar, .translate]
        /// Dictation joins the right column too: the left rail is full, and
        /// settings stays last — the one icon nobody hovers past on the way
        /// somewhere else.
        static let rightRail: [Tab] = [.dictation, .notes, .settings]
    }

    @Published var isOpen = false
    @Published var isDropTargeted = false
    /// Which dictation animation the notch shows. Published rather than read
    /// from defaults at draw time, so switching it in the menu bar takes effect
    /// on the next take instead of the next relaunch.
    @Published var waveStyle = DictationWaveStyle.current
    @Published var tab: Tab = .media {
        didSet {
            // Opening the tab only re-checks the status. The permission prompt
            // is the user's own press on the button inside the pane: this is
            // the one permission Cyclop asks for at all, and it deserves an
            // explanation before the system dialog, not after.
            if tab == .calendar { calendar.refreshAccess() }
            // The snippets file is edited from outside the app, so it is read
            // on the way in rather than held from launch.
            if tab == .snippets { snippets.reload() }
            // Leaving the notes sweeps out the blank ones — they cost one
            // hover to recreate, and a trail of empty cards is the clutter a
            // scratchpad exists to avoid.
            if oldValue == .notes, tab != .notes { notes.leave() }
            // Same two reasons as the calendar: permission may have changed
            // since the tab was last shown, and the history file can have
            // grown from outside this launch too.
            if tab == .dictation {
                dictation.refreshPermission()
                dictation.reload()
            }
            // Leaving the tab that types gives the keyboard straight back.
            // `tabHasField`, not `tab.needsKeyboard`: the calls above just
            // decided whether dictation's search field is actually the thing
            // on screen right now, and the permission prompt and the failure
            // screen both have nowhere to type either.
            if !tabHasField { releaseKeyboard() }
        }
    }

    /// Whether the pane currently on screen has a field to type into. Static
    /// for translate and snippets — their pane is always the editor — but
    /// dictation's search field only exists in its default state: the
    /// permission prompt and the failure screen show neither, and grabbing
    /// the keyboard for a field that is not there would only dim the caret in
    /// whatever app was focused, for nothing. Reads `dictation.state` fresh,
    /// so it must only be consulted after `refreshPermission()` has already
    /// run for this visit — which the `didSet` above guarantees.
    ///
    /// Checked ahead of everything else, for every tab, not only dictation's:
    /// `NotchController` forces the panel onto the dictation tab and pins it
    /// open for the whole take, but nothing stops a hover from then landing
    /// on Snippets or Translate — both of which otherwise report a field
    /// unconditionally. A click or a tab-icon dwell claiming the keyboard
    /// mid-take is the same bug `NotchController`'s `releaseKeyboard()` on
    /// entering `.recording` already fixed once for dictation's own field;
    /// this closes it for every other field too, and for a click landing
    /// back on dictation's own while `.recording`/`.transcribing` — both
    /// still count as "has a field" in `dictationHasField` below, which only
    /// answers a different question (the latch in `dictationStateChanged`),
    /// not this one. Reading `dictation.isBusy` here is safe even from the
    /// reentrant call this property sees mid-`didSet` while a recording is
    /// just starting (`dictation.state` is briefly stale then — see
    /// `DictationController.beginRecording()`): the stale read only ever
    /// under-reports busy, never over-reports it, and resolves before any
    /// real click or hover could happen.
    var tabHasField: Bool {
        guard !dictation.isBusy else { return false }
        guard tab.needsKeyboard else { return false }
        guard tab == .dictation else { return true }
        return Self.dictationHasField(dictation.state)
    }

    private static func dictationHasField(_ state: DictationController.State) -> Bool {
        switch state {
        // The catalog and the download bar have no search field on them, so
        // there is nothing here worth taking the keyboard from another app
        // for — same reasoning as the permission screen.
        case .needsPermission, .needsModel, .downloading, .failed: return false
        case .idle, .recording, .transcribing: return true
        }
    }

    /// Whether the panel currently holds the keyboard.
    ///
    /// Tracked apart from `tab` because the two come apart in one direction:
    /// clicking into another app drops the claim without changing which tab is
    /// showing, so the text one was typing survives and the panel is free to
    /// collapse. Landing on a tab that types always raises it again — there is
    /// no such thing as a panel that shows a field but cannot receive a key.
    @Published var wantsKeyboard = false

    /// Set alongside `wantsKeyboard = false` exactly when a dictation state
    /// change is what took the keyboard away — never by a tab switch, a click
    /// elsewhere, or the panel collapsing. Only this flag means "give it back
    /// once a field reappears": the hotkey fires from anywhere, so a
    /// recording that was started with this tab already open and focused can
    /// fail while the user has since moved on to dictating into some other
    /// app entirely, and by the time it fails the keyboard must already be
    /// out of the panel's hands, not waiting to be reclaimed later.
    private var keyboardSuspendedByDictation = false

    /// Drops the keyboard for a reason unrelated to dictation's own state —
    /// leaving the tab, clicking elsewhere, the panel collapsing. Clearing the
    /// latch here is what stops a dictation state change, arriving later for
    /// its own reasons, from reaching back and grabbing focus from whatever
    /// the user has moved on to since.
    func releaseKeyboard() {
        wantsKeyboard = false
        keyboardSuspendedByDictation = false
    }

    /// Grabs the keyboard for a deliberate reason — landing on a typing tab,
    /// clicking back into the panel. Clears the latch too: this is a fresh,
    /// explicit claim, and it should not be undone later by bookkeeping left
    /// over from an unrelated suspension.
    func claimKeyboard() {
        wantsKeyboard = true
        keyboardSuspendedByDictation = false
    }

    /// The gated version of `claimKeyboard()`: goes through `tabHasField`
    /// first, same as `select(_:)` and `NotchController`'s `panel.onPress`.
    /// For a claim triggered from inside a pane itself — `SnippetsPane`'s "+"
    /// button starting a new entry — rather than from switching to or
    /// clicking back into the tab, where the caller already checks
    /// `tabHasField` before calling `claimKeyboard()` directly. Without this
    /// gate, opening the editor row while dictation is mid-take would still
    /// grab the keyboard out from under it: `TextInserter` posts a synthetic
    /// ⌘V to whatever window is key, and the draft field would catch the
    /// transcript instead of the app dictation was meant to reach.
    func claimKeyboardIfAvailable() {
        if tabHasField { claimKeyboard() }
    }

    let geometry: NotchGeometry
    let media: MediaController
    let shelf: ShelfStore
    let clipboard: ClipboardStore
    let calendar: CalendarStore
    let translator: Translator
    let snippets: SnippetStore
    let notes: NoteStore
    let dictation: DictationController
    /// Shared by every pane that shows something worth not showing.
    let privacy = PrivacyMode()

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        self.media = MediaController()
        self.shelf = ShelfStore()
        self.clipboard = ClipboardStore()
        self.calendar = CalendarStore()
        self.translator = Translator()
        self.snippets = SnippetStore()
        self.notes = NoteStore()
        self.dictation = DictationController()

        // The panel header reads through to the stores — counters, the source
        // name, the equalizer. Nested ObservableObjects do not propagate on
        // their own, so those would only refresh when something else happened
        // to redraw the view.
        //
        // Forwarded only while the panel is open. Collapsed, there is nothing
        // these redraws could change — the panel is a black shape — yet the
        // stores keep their own schedule: a track change every few minutes, a
        // copy whenever one happens, and each send re-evaluated the whole
        // view for nobody. Opening repaints from the stores directly, because
        // `isOpen` is itself @Published and its own send does that.
        //
        // The stores with a text field in their pane — the translator, the
        // snippets and the notes — are deliberately absent. They change on every
        // keystroke, and redrawing the whole panel per letter costs more than a
        // stale counter: it rebuilds the field, which drops the focus, so the
        // first letter typed is also the last one that lands. Their panes
        // observe them directly, and the header counter refreshes anyway,
        // because the list is only ever re-read on the way into the tab.
        for child in [
            media.objectWillChange,
            shelf.objectWillChange,
            clipboard.objectWillChange,
            calendar.objectWillChange,
            dictation.objectWillChange,
        ] {
            child
                .sink { [weak self] _ in
                    guard let self, self.isOpen || self.isDropTargeted else { return }
                    self.objectWillChange.send()
                }
                .store(in: &cancellables)
        }

        // Separate from the loop above: that one just forwards for redraws.
        // This reacts to *which* state dictation is in, and it has to, because
        // the state can change with no tab switch and no click involved at
        // all — the hotkey listens globally. `didSet` on `tab` alone only
        // catches the keyboard going stale on the way in or out of the tab;
        // this catches it going stale while the user never left.
        dictation.$state
            .removeDuplicates()
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    // The forwarding loop above stops at a closed panel — and
                    // the animation under the notch is drawn *only* while the
                    // panel is closed (see `waveMood`). So nothing redrew it
                    // when dictation moved on: the wave appeared in listening
                    // blue when the hotkey forced the tab over, and then stayed
                    // that way — never turning to the orange of transcription,
                    // never leaving when the take was done. State changes are a
                    // handful per dictation; redrawing on each costs nothing.
                    self?.objectWillChange.send()
                    self?.dictationStateChanged(state)
                }
            }
            .store(in: &cancellables)
    }

    /// Keeps the keyboard claim honest against a dictation state that just
    /// changed out from under it. Only acts while dictation is the visible
    /// tab — elsewhere the state changing has nothing to do with what the
    /// panel is showing. Symmetric: drops the keyboard the moment the field
    /// disappears, and — only for a drop this same method made — returns it
    /// once a field is back. A drop for any other reason (leaving the tab, a
    /// click elsewhere, the panel collapsing) goes through `releaseKeyboard()`
    /// instead, which clears the latch, so this never claims the keyboard back
    /// on behalf of a user who has since moved on.
    private func dictationStateChanged(_ state: DictationController.State) {
        guard tab == .dictation else { return }
        let hasField = Self.dictationHasField(state)
        if !hasField, wantsKeyboard {
            // Order is load-bearing — do not reorder these two lines, and do
            // not lift them into a shared helper that might. Setting
            // `wantsKeyboard` re-enters synchronously, right here, before
            // this assignment returns: `NotchController` observes
            // `$wantsKeyboard` and calls `panel.acceptsKeyboard = false`,
            // whose `orderOut` + `orderFrontRegardless` round trip resigns
            // key status, which posts `didResignKeyNotification`, which
            // `NotchController` also observes and answers by calling
            // `releaseKeyboard()` — the very method below this one — which
            // sets `keyboardSuspendedByDictation = false` in the middle of
            // this call, before the next line has had a chance to set it
            // true. Setting the latch *after* `wantsKeyboard = false`, not
            // before, is what makes it survive that reentrant clear; the
            // reverse order would silently leave it false, and the `else if`
            // below would never fire once a field reappears — the panel
            // would stop reclaiming its own search field on its own, back to
            // needing an extra click, which is the exact bug this latch was
            // added to fix (see the ledger entry for Task 9). No test can
            // catch a swap here — the executable target cannot be imported
            // by the test target (see Package.swift).
            wantsKeyboard = false
            keyboardSuspendedByDictation = true
        } else if hasField, keyboardSuspendedByDictation {
            claimKeyboard()
        }
    }

    /// Size of the visible body for the current state.
    var bodySize: CGSize {
        isOpen || isDropTargeted ? geometry.expandedSize : geometry.notchSize
    }

    /// Off switch for people who copy images all day and do not want them kept.
    static let saveClipboardImagesKey = "saveClipboardImages"

    /// Defaults to on: the feature is the reason the folder exists.
    static var saveClipboardImagesEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: saveClipboardImagesKey) != nil else { return true }
        return defaults.bool(forKey: saveClipboardImagesKey)
    }

    /// Hover and click both land here. A tab that types takes the keyboard
    /// either way: showing a field one cannot type into is worse than briefly
    /// dimming the caret of the window underneath, and the dwell threshold on
    /// the rail already keeps a passing pointer from arriving here at all.
    func select(_ tab: Tab) {
        self.tab = tab
        // Read after the assignment above, whose `didSet` has by now called
        // `dictation.refreshPermission()` — `tabHasField` needs that state to
        // already be current, not whatever it was before this hover/click.
        if tabHasField { claimKeyboard() }
    }

    func start() {
        media.start()
        shelf.load()
        snippets.reload()
        // Only picks up where it left off if access was granted earlier; it
        // never prompts on its own.
        calendar.start()
        // Same discipline: loads existing history and arms the hotkey only if
        // Accessibility was already granted, never prompting on launch.
        dictation.start()

        // Screenshots reach the shelf through here whether they were taken on
        // this Mac or on a phone: a copy made on the phone arrives in the same
        // pasteboard, carried over by Continuity.
        //
        // The switch is asked by the store before it touches image data, not
        // here after the fact: turned off, a copied picture used to be encoded
        // to PNG in full just to be dropped on this doorstep — pure heat on
        // exactly the machines whose owners turned the feature off.
        clipboard.wantsImages = { Self.saveClipboardImagesEnabled }
        clipboard.onImage = { [weak self] png in
            guard let self, let url = ScreenshotVault.save(png) else { return }
            self.receivedScreenshot(at: url)
        }
        clipboard.start()
    }

    func stop() {
        media.stop()
        clipboard.stop()
        calendar.stop()
        // Whatever was typed makes it to disk even when quitting mid-thought.
        notes.flush()
        dictation.stop()
    }

    /// A screenshot that arrived on its own — copied elsewhere, or synced
    /// from a phone by Continuity — rather than one the user handed to the
    /// panel directly. It goes on the shelf either way, but only switches to
    /// showing it when nobody is mid-sentence: the tab's own field would
    /// slide out from under the caret, and losing the keyboard mid-word sends
    /// the rest of the sentence to whatever is underneath. The shelf's
    /// counter already shows the new picture, so nothing about it is lost by
    /// waiting.
    func receivedScreenshot(at url: URL) {
        shelf.add([url])
        guard !wantsKeyboard else { return }
        tab = .shelf
    }

    /// A file the user dropped on the panel by hand — switching to the shelf
    /// is the point, not a side effect to guard against.
    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        tab = .shelf
        return true
    }
}
