import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, snippets, dictation, calendar, translate
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
            }
        }

        /// Tabs that can show a field, at least in some state. Translate and
        /// snippets always do; dictation only in its default state — see
        /// `NotchViewModel.tabHasField`, which is what actually decides
        /// whether to grab the keyboard.
        var needsKeyboard: Bool { self == .translate || self == .snippets || self == .dictation }
    }

    @Published var isOpen = false
    @Published var isDropTargeted = false
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
            if !tabHasField { wantsKeyboard = false }
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
    var tabHasField: Bool {
        guard tab.needsKeyboard else { return false }
        guard tab == .dictation else { return true }
        switch dictation.state {
        case .needsPermission, .failed: return false
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

    let geometry: NotchGeometry
    let media: MediaController
    let shelf: ShelfStore
    let clipboard: ClipboardStore
    let calendar: CalendarStore
    let translator: Translator
    let snippets: SnippetStore
    let dictation: DictationController

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry) {
        self.geometry = geometry
        self.media = MediaController()
        self.shelf = ShelfStore()
        self.clipboard = ClipboardStore()
        self.calendar = CalendarStore()
        self.translator = Translator()
        self.snippets = SnippetStore()
        self.dictation = DictationController()

        // The panel header reads through to the stores — counters, the source
        // name, the equalizer. Nested ObservableObjects do not propagate on
        // their own, so those would only refresh when something else happened
        // to redraw the view.
        //
        // The two stores with a text field in their pane — the translator and
        // the snippets — are deliberately absent. They change on every
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
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    /// Size of the visible body for the current state.
    var bodySize: CGSize {
        isOpen || isDropTargeted ? geometry.expandedSize : geometry.notchSize
    }

    /// Off switch for people who copy images all day and do not want them kept.
    static let saveClipboardImagesKey = "saveClipboardImages"

    /// Hover and click both land here. A tab that types takes the keyboard
    /// either way: showing a field one cannot type into is worse than briefly
    /// dimming the caret of the window underneath, and the dwell threshold on
    /// the rail already keeps a passing pointer from arriving here at all.
    func select(_ tab: Tab) {
        self.tab = tab
        // Read after the assignment above, whose `didSet` has by now called
        // `dictation.refreshPermission()` — `tabHasField` needs that state to
        // already be current, not whatever it was before this hover/click.
        if tabHasField { wantsKeyboard = true }
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
        clipboard.onImage = { [weak self] png in
            guard let self else { return }
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: Self.saveClipboardImagesKey) == nil
                    || defaults.bool(forKey: Self.saveClipboardImagesKey) else { return }
            guard let url = ScreenshotVault.save(png) else { return }
            self.shelf.add([url])
            self.tab = .shelf
        }
        clipboard.start()
    }

    func stop() {
        media.stop()
        clipboard.stop()
        calendar.stop()
        dictation.stop()
    }

    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        tab = .shelf
        return true
    }
}
