import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, snippets, calendar, translate, dictation, notes, teleprompter, meetings, settings
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
            case .teleprompter: return "text.viewfinder"
            case .meetings: return "record.circle"
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
            case .teleprompter: return localized("Teleprompter")
            case .meetings: return localized("Meetings")
            case .settings: return localized("Settings")
            }
        }

        /// Tabs that can show a field, at least in some state. Translate,
        /// snippets, notes and settings always do; dictation only in its
        /// default state — see `NotchViewModel.tabHasField`, which is what
        /// actually decides whether to grab the keyboard.
        ///
        /// Settings joined the list the moment it grew fields of its own: the
        /// address, the key and a name are all typed, and a field that cannot
        /// take a keystroke reads as a broken field, not as a considerate one.
        /// The keyboard is still taken on a click into the panel rather than on
        /// hover, so nothing is stolen from the app underneath by accident.
        var needsKeyboard: Bool {
            self == .translate || self == .snippets || self == .dictation || self == .notes
                || self == .settings
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
        /// somewhere else. Meetings joins it for the same reason, right
        /// before settings.
        static let rightRail: [Tab] = [.dictation, .notes, .teleprompter, .meetings, .settings]
    }

    /// What every screen's panel adds up to, kept by `NotchController`: this
    /// model is shared by all of them and has no panel of its own. Plain
    /// properties, because nothing on screen reads them — a view asks its own
    /// `PanelState` about its own display.
    var isPanelActive = false
    var isTyping = false

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
            // Same reason, sharper stakes: the shelf can hold files inside the
            // folders macOS guards, and looking at one raises a permission
            // prompt. It is asked here, with the shelf on screen, rather than
            // at launch with nothing to explain it.
            if tab == .shelf { shelf.refreshFromDisk() }
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
            // Leaving the tab that types gives the keyboard straight back —
            // done per screen, where the claim lives, in `NotchScreenPanel`.
            // Leaving the teleprompter stops the scroll and drops the pin, so
            // the panel goes back to obeying the pointer like everything else.
            if oldValue == .teleprompter, tab != .teleprompter { teleprompter.suspend() }
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

    /// Whether the panel must stay open with no pointer on it.
    ///
    /// This is the one exception to the rule stated at `NotchController.setOpen`
    /// — the pointer decides, always — and it exists because the teleprompter
    /// cannot work under that rule: the whole point is reading while looking at
    /// the camera, hands nowhere near the trackpad. The exception is kept as
    /// narrow as it can be. It applies to one tab, only while the script is
    /// actually moving, and it ends three ways that need no explaining: the
    /// script runs out, Escape, or a click anywhere outside the panel.
    ///
    /// The offer card joins it for the same underlying reason: it has real
    /// buttons, not a decoration, and a call starting almost never finds the
    /// pointer anywhere near the notch. `NotchController` forces the panel
    /// open the moment the card appears; this is what stops the very next
    /// pointer sample — the mouse is usually still wherever it was — from
    /// folding it straight back before anyone can read it.
    var holdsOpen: Bool {
        (tab == .teleprompter && teleprompter.isRunning) || meetings.offer
    }


    let media: MediaController
    let shelf: ShelfStore
    let clipboard: ClipboardStore
    let calendar: CalendarStore
    let translator: Translator
    let snippets: SnippetStore
    let notes: NoteStore
    let dictation: DictationController
    let teleprompter: TeleprompterStore
    let meetings = MeetingsController()
    /// Shared by every pane that shows something worth not showing.
    let privacy = PrivacyMode()

    private var cancellables = Set<AnyCancellable>()

    init() {
        self.media = MediaController()
        self.shelf = ShelfStore()
        self.clipboard = ClipboardStore()
        self.calendar = CalendarStore()
        self.translator = Translator()
        self.snippets = SnippetStore()
        self.notes = NoteStore()
        self.dictation = DictationController()
        self.teleprompter = TeleprompterStore()

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
                    guard let self, self.isPanelActive else { return }
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
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        // Same reason as dictation's own subscription just above: the
        // recording indicator and the offer card are drawn by
        // `NotchContentView` directly, outside `MeetingsPane`, specifically
        // so they show over a collapsed panel — and the forwarding loop at
        // the top of this initializer stops at a closed one. Two
        // subscriptions rather than one `CombineLatest`: `state` and `offer`
        // change independently (an offer accepted moves one without the
        // other touching), and nothing here needs them paired up.
        meetings.$state
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
        meetings.$offer
            .removeDuplicates()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
    }

    /// Off switch for people who copy images all day and do not want them kept.
    static let saveClipboardImagesKey = "saveClipboardImages"

    /// Defaults to on: the feature is the reason the folder exists.
    static var saveClipboardImagesEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: saveClipboardImagesKey) != nil else { return true }
        return defaults.bool(forKey: saveClipboardImagesKey)
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
        // Screen-recording permission is asked for the same way, the moment
        // a recording is actually requested — not here. start() only arms
        // the call detector, which reads the microphone's busy flag and
        // needs nothing granted to it at all.
        // Wired before start(): the detector is armed inside it, and a
        // detector that cannot tell dictation from a call offers to record
        // one every time a long paragraph is dictated.
        meetings.isDictating = { [weak self] in self?.dictation.state == .recording }
        meetings.start()

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
        guard !isTyping else { return }
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
