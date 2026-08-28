import AppKit
import CyclopFinderPath
import FinderSync

/// The "Copy Full Path" item in Finder's contextual menu.
///
/// Info.plist names this class as `NSExtensionPrincipalClass`, so the `@objc`
/// name is load-bearing: the system looks it up by string, and renaming the
/// Swift type without renaming that string gives an extension that loads and
/// then does nothing.
@objc(CyclopFinderMenu)
final class CyclopFinderMenu: FIFinderSync {
    override init() {
        super.init()
        // Finder offers an extension's menu only for items inside a directory
        // that extension declared it watches, and "whatever the user
        // right-clicked" is the whole disk — external volumes included, since
        // they mount under /Volumes. Watching root is cheap here: badges are
        // the expensive half of Finder Sync, and this extension asks for none,
        // so nothing is computed per file.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // Only the menu that comes up on selected files and folders. The
        // container and sidebar menus would put the item in front of people
        // right-clicking empty space, where there is no selection to copy.
        guard menuKind == .contextualMenuForItems else { return nil }
        let menu = NSMenu(title: "")
        // A single item, so Finder shows it at the top level of the menu
        // instead of folding it into a submenu named after the extension.
        menu.addItem(
            withTitle: localized("Copy Full Path"),
            action: #selector(copyFullPath(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    /// Copies, and that is all.
    ///
    /// Nothing is shown, nothing is brought forward, and Cyclop itself does not
    /// have to be running: this process is Finder's, and the pasteboard is the
    /// whole result. Announcing the copy would cost the user their focus for
    /// something they can verify by pasting.
    @objc func copyFullPath(_ sender: AnyObject?) {
        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        let text = FinderPathText.lines(for: urls)
        // Finder can hand back nothing at all — a selection that vanished while
        // the menu was open. Clearing the pasteboard then would throw away what
        // the user had copied earlier and give nothing back.
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
