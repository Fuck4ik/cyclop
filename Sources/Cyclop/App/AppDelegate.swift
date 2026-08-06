import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        installStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "eye.fill",
            accessibilityDescription: "Cyclop"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Cyclop \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: localized("Open Panel"),
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let login = NSMenuItem(
            title: localized("Launch at Login"),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        login.target = self
        login.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(login)

        let saveShots = NSMenuItem(
            title: localized("Save Clipboard Screenshots"),
            action: #selector(toggleSaveClipboardImages),
            keyEquivalent: ""
        )
        saveShots.target = self
        saveShots.state = saveClipboardImagesEnabled ? .on : .off
        menu.addItem(saveShots)

        let openFolder = NSMenuItem(
            title: localized("Show Screenshots Folder"),
            action: #selector(revealScreenshots),
            keyEquivalent: ""
        )
        openFolder.target = self
        menu.addItem(openFolder)

        let openSnippets = NSMenuItem(
            title: localized("Show Snippets File"),
            action: #selector(revealSnippets),
            keyEquivalent: ""
        )
        openSnippets.target = self
        menu.addItem(openSnippets)

        // Which animation the notch shows while dictating. Two of them exist
        // because the choice is a matter of taste, so it belongs to the user
        // rather than to a constant in the source.
        let styles = NSMenuItem(title: localized("Dictation Animation"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for style in DictationWaveStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(selectWaveStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = DictationWaveStyle.current == style ? .on : .off
            submenu.addItem(item)
        }
        styles.submenu = submenu
        menu.addItem(styles)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        controller?.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Defaults to on: the feature is the reason the folder exists.
    private var saveClipboardImagesEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: NotchViewModel.saveClipboardImagesKey) != nil else { return true }
        return defaults.bool(forKey: NotchViewModel.saveClipboardImagesKey)
    }

    @objc private func toggleSaveClipboardImages(_ sender: NSMenuItem) {
        UserDefaults.standard.set(!saveClipboardImagesEnabled, forKey: NotchViewModel.saveClipboardImagesKey)
        sender.state = saveClipboardImagesEnabled ? .on : .off
    }

    @objc private func selectWaveStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = DictationWaveStyle(rawValue: raw) else { return }
        DictationWaveStyle.current = style
        controller?.setWaveStyle(style)
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == raw ? .on : .off
        }
    }

    @objc private func revealScreenshots() {
        ScreenshotVault.reveal()
    }

    @objc private func revealSnippets() {
        SnippetStore.reveal()
    }

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Cyclop: launch-at-login failed: \(error.localizedDescription)")
        }
        sender.state = launchAtLoginEnabled ? .on : .off
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
