import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchController {
    private var panel: NotchPanel?
    private var rootView: NotchRootView?
    private var viewModel: NotchViewModel?
    private let pointer = PointerWatcher()
    private var closeActiveRectWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    func install() {
        build()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        }
    }

    /// The panel belongs to the desktop it was opened on. ⌘-Tab to another one
    /// leaves the pointer wherever it happened to be — which is not a decision
    /// to keep the panel expanded over a screen the user has just arrived at.
    /// Collapsing also puts hover tracking back in step: nothing moved the
    /// mouse, so nothing else would have.
    private func activeSpaceChanged() {
        guard viewModel?.isOpen == true else { return }
        // What was typed is kept — only the panel closes.
        setOpen(false)
        pointer.setInside(false)
    }

    private func screenParametersChanged() {
        let fresh = NotchGeometry.current()
        guard let current = viewModel?.geometry, current.matches(fresh) else {
            rebuild()
            return
        }
        // Same display, same notch: keep the panel and everything on it.
        panel?.setFrame(fresh.windowFrame, display: false)
    }

    func teardown() {
        pointer.stop()
        viewModel?.stop()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
    }

    func toggle() {
        guard let viewModel else { return }
        setOpen(!viewModel.isOpen)
        pointer.setInside(viewModel.isOpen)
    }

    // MARK: - Construction

    private func rebuild() {
        let previousTab = viewModel?.tab
        pointer.stop()
        viewModel?.stop()
        closeActiveRectWork?.cancel()
        cancellables.removeAll()
        panel?.acceptsKeyboard = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        rootView = nil
        viewModel = nil
        build()
        if let previousTab { viewModel?.tab = previousTab }
    }

    private func build() {
        let geometry = NotchGeometry.current()
        let vm = NotchViewModel(geometry: geometry)
        viewModel = vm

        let panel = NotchPanel(contentRect: geometry.windowFrame)
        let root = NotchRootView(frame: CGRect(origin: .zero, size: geometry.windowSize))
        root.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: NotchContentView(vm: vm))
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 14.0, *) {
            hosting.sizingOptions = []
        }
        root.addSubview(hosting)

        root.onDragEntered = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            vm.tab = .shelf
            vm.isDropTargeted = true
            self.setOpen(true)
        }
        root.onDragExited = { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            vm.isDropTargeted = false
            // The pointer usually is not over the panel after a drag leaves.
            self.scheduleCollapseIfPointerAway()
        }
        root.onDrop = { [weak self] urls in
            guard let self, let vm = self.viewModel else { return false }
            vm.isDropTargeted = false
            let accepted = vm.accept(urls: urls)
            self.pointer.setInside(true)
            self.setOpen(true)
            self.scheduleCollapseIfPointerAway()
            return accepted
        }

        // Clicking away drops the keyboard but leaves the tab where it was, so
        // a click back into the panel has to be able to ask for it again.
        // `tabHasField`, not `tab.needsKeyboard`: a click on dictation's
        // permission prompt or failure screen has no field to hand the
        // keyboard to either.
        panel.onPress = { [weak self] in
            guard let vm = self?.viewModel, vm.tabHasField else { return }
            vm.wantsKeyboard = true
        }

        panel.contentView = root
        panel.ignoresMouseEvents = true
        panel.setFrame(geometry.windowFrame, display: false)
        panel.orderFrontRegardless()

        self.panel = panel
        self.rootView = root

        applyActiveRect(open: false)

        pointer.openRect = geometry.hoverRect
        pointer.warmZone = geometry.warmZone
        pointer.closeRect = geometry.expandedHoverRect
        pointer.isDragging = { [weak root] in root?.isReceivingDrag ?? false }
        pointer.isPanelOpen = { [weak vm] in vm?.isOpen ?? false }
        pointer.onChange = { [weak self] inside in
            self?.setOpen(inside)
        }
        // Everything outside the visible panel must reach the app underneath:
        // a `nil` from hitTest only discards the event, it does not forward it.
        pointer.onInteractiveChange = { [weak self] interactive in
            self?.panel?.ignoresMouseEvents = !interactive
        }
        pointer.start()

        // Driven by the deliberate request, not by which tab is showing: a
        // hover can land on the typing tab now, and that alone must not take
        // the keyboard away from the window underneath.
        vm.$wantsKeyboard
            .removeDuplicates()
            .sink { [weak self] wants in
                MainActor.assumeIsolated { self?.setKeyboard(wants) }
            }
            .store(in: &cancellables)

        // Clicking into another app drops the keyboard: there is no
        // click-outside to catch, but losing key status says the same. The tab
        // stays as it was — only the claim on the keyboard is dropped.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.viewModel?.wantsKeyboard = false }
            }
            .store(in: &cancellables)

        vm.start()

        // A rebuilt panel starts closed. If the pointer is already sitting on
        // it, reopen at once instead of waiting for a trip back to the notch.
        if geometry.expandedHoverRect.contains(NSEvent.mouseLocation) {
            pointer.setInside(true)
            setOpen(true)
        }
    }

    // MARK: - Open / close

    /// Hands the keyboard to the panel, or gives it back.
    private func setKeyboard(_ wants: Bool) {
        if wants {
            setOpen(true)
            pointer.setInside(true)
        }
        panel?.acceptsKeyboard = wants
        // What was typed stays: clicking away to look something up should not
        // be the same as throwing the text out. Esc and the ✕ do that.
        if !wants { scheduleCollapseIfPointerAway() }
    }

    /// The pointer decides, always. A field with something in it does not hold
    /// the panel open: it is opened by hovering, and anything that survives the
    /// pointer leaving would have to be dismissed some other way, which is a
    /// second rule to learn for a panel that has exactly one. What was typed is
    /// kept, so coming back finds it where it was left.
    private func setOpen(_ open: Bool) {
        guard let vm = viewModel, vm.isOpen != open else { return }
        closeActiveRectWork?.cancel()

        if open {
            // Grow the interactive area first so the pointer never falls
            // through a region the animation has not covered yet.
            applyActiveRect(open: true)
            withAnimation(Theme.openAnimation) { vm.isOpen = true }
            vm.media.setActive(true)
        } else {
            // A collapsed panel has no business holding the keyboard.
            vm.wantsKeyboard = false
            withAnimation(Theme.openAnimation) { vm.isOpen = false }
            vm.media.setActive(false)
            // Shrink only once the panel has finished collapsing. Doing it
            // while it is still visibly there would leave a window in which
            // clicks land on whatever is behind the panel.
            let work = DispatchWorkItem { [weak self] in self?.applyActiveRect(open: false) }
            closeActiveRectWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func scheduleCollapseIfPointerAway() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let geometry = self.viewModel?.geometry else { return }
            // Resync either way. A pointer that is still on the panel has to be
            // recorded as inside, or hover tracking stays convinced it left and
            // the panel hangs open until the notch is touched again.
            let away = !geometry.expandedHoverRect.contains(NSEvent.mouseLocation)
            self.pointer.setInside(!away)
            if away { self.setOpen(false) }
        }
    }

    private func applyActiveRect(open: Bool) {
        guard let vm = viewModel, let rootView else { return }
        let size = open ? vm.geometry.expandedSize : vm.geometry.notchSize
        var rect = vm.geometry.contentRect(for: size)
        if open {
            // Slack so the concave shoulders stay grabbable. Never while
            // collapsed: that would swallow clicks on menu bar items next to
            // the notch.
            rect = rect.insetBy(dx: -Theme.openTopRadius, dy: 0)
        }
        rootView.activeRect = rect
        pointer.interactiveRect = vm.geometry
            .contentScreenRect(for: size)
            .insetBy(dx: open ? -Theme.openTopRadius : 0, dy: 0)
    }
}
