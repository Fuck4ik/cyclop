import AppKit
import UniformTypeIdentifiers

/// Content view of the panel. Everything outside `activeRect` is click-through,
/// so the window can stay at its full expanded size while the panel is collapsed.
final class NotchRootView: NSView {
    /// Interactive area, in window coordinates.
    var activeRect: CGRect = .zero {
        didSet {
            guard activeRect != oldValue else { return }
            refreshCursorArea()
        }
    }

    private var cursorArea: NSTrackingArea?

    var onDragEntered: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDrop: (([URL]) -> Bool)?

    private(set) var isReceivingDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The app never becomes active, so without this the first click on the
    /// panel would be spent activating instead of hitting the control.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While a drag is in flight the whole window must stay a valid target,
        // otherwise AppKit drops us as the destination mid-animation.
        guard isReceivingDrag || activeRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshCursorArea()
    }

    /// The cursor shape comes from the topmost window claiming a region under
    /// the pointer. Claiming nothing does not mean "leave the cursor alone", it
    /// means the panel is invisible to that lookup and the window underneath
    /// gets to decide — an I-beam over a text editor, say. So claim exactly the
    /// part of the panel that takes events and pin it to the arrow.
    ///
    /// A cursor rect would not do: AppKit disables those for non-key windows,
    /// and this panel is never key. `.activeAlways` keeps the tracking area
    /// live regardless of that and of the app being inactive.
    private func refreshCursorArea() {
        if let cursorArea {
            removeTrackingArea(cursorArea)
            self.cursorArea = nil
        }
        guard !activeRect.isEmpty else { return }
        let area = NSTrackingArea(
            rect: activeRect,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        cursorArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    /// The pointer can already be inside a freshly installed area — entering is
    /// then the first notification we get, and no cursor update precedes it.
    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    // MARK: - Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(from: sender).isEmpty else { return [] }
        isReceivingDrag = true
        onDragEntered?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDragSession()
    }

    /// The end AppKit always sends, whichever way the drag finished.
    ///
    /// `draggingExited` is not that end: a drop the destination refuses —
    /// `prepareForDragOperation` answering false — finishes here and nowhere
    /// else. Left clearing only the local flag, that path never told the panel
    /// the drag was over, so `isDropTargeted` stayed true; and the panel is
    /// drawn open on `isOpen || isDropTargeted`, so it stood open with nothing
    /// able to fold it. Both ends now go through the same door.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDragSession()
    }

    /// Reports the end once per session. A drop reports its own — the drag is
    /// already over by the time `onDrop` runs — and the `draggingEnded` that
    /// follows it must not schedule a second collapse behind it.
    private func endDragSession() {
        guard isReceivingDrag else { return }
        isReceivingDrag = false
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !urls(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(from: sender)
        // A drop that lands reports the end itself: `onDrop` hands the panel
        // back to the pointer. A drop that turns out to carry nothing has no
        // such report, so it leaves by the ordinary door rather than clearing
        // the flag and going quiet.
        guard !files.isEmpty else {
            endDragSession()
            return false
        }
        isReceivingDrag = false
        return onDrop?(files) ?? false
    }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
