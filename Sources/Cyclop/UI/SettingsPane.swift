import SwiftUI
import FinderSync
import ServiceManagement

/// What used to live in the status bar menu, minus the two items that belong
/// there: opening the panel and hiding its contents are both things people
/// reach for in a hurry, often without wanting to open the panel at all — the
/// rest is configuration, read rarely, and reads better as a tab like any
/// other than as a menu that grows a new row per feature.
struct SettingsPane: View {
    @ObservedObject var shelf: ShelfStore

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
    @State private var screenshotUsage: (files: Int, bytes: Int64) = (0, 0)
    @State private var finderMenuEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var cloudHost = CloudTranscriber.host
    @State private var cloudToken = CloudCredentials.token
    @State private var ownerName = MeetingsController.ownerName

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(localized("General")) {
                    toggleRow(
                        symbol: "arrow.forward.to.line",
                        title: localized("Launch at Login"),
                        isOn: launchAtLoginBinding
                    )
                }

                section(localized("Screenshots")) {
                    toggleRow(
                        symbol: "photo.on.rectangle",
                        title: localized("Save Clipboard Screenshots"),
                        isOn: saveClipboardImagesBinding
                    )
                    actionRow(symbol: "folder", title: localized("Show Screenshots Folder")) {
                        ScreenshotVault.reveal()
                    }
                    actionRow(
                        symbol: "trash",
                        title: clearTitle,
                        disabled: screenshotUsage.files == 0
                    ) {
                        ScreenshotVault.clear()
                        shelf.load()
                        // The files were just deleted, so the cards have to go
                        // with them. Safe to look here: the vault lives in the
                        // app's own folder, which macOS does not guard.
                        shelf.refreshFromDisk()
                        refreshUsage()
                    }
                }

                section(localized("Snippets")) {
                    actionRow(symbol: "doc.text", title: localized("Show Snippets File")) {
                        SnippetStore.reveal()
                    }
                }

                // Cloud recognition needs an address and a key, and neither can
                // live in the repository. The section is here rather than in the
                // dictation tab because that tab is about models and history,
                // while these two are credentials — and the key is the reason
                // the row exists at all: without it the cloud model in the
                // catalog stays unselectable.
                section(localized("Cloud dictation")) {
                    fieldRow(
                        symbol: "network",
                        title: localized("Address"),
                        placeholder: "127.0.0.1:8317",
                        text: $cloudHost,
                        secure: false
                    ) {
                        CloudTranscriber.host = cloudHost
                    }
                    fieldRow(
                        symbol: "key",
                        title: localized("API key"),
                        placeholder: localized("stored in Keychain"),
                        text: $cloudToken,
                        secure: true
                    ) {
                        CloudCredentials.token = cloudToken
                    }
                }

                // A row for where recordings land and one for the name that
                // signs the owner's own lines in the transcript — both live
                // here rather than on the meetings tab itself, same reasoning
                // as the cloud section above: that tab is for recording and
                // the list of what came out of it, not for configuration.
                section(localized("Meetings")) {
                    actionRow(
                        symbol: "folder",
                        title: localized("Meetings folder"),
                        detail: MeetingsController.rootFolder.lastPathComponent
                    ) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = MeetingsController.rootFolder
                        if panel.runModal() == .OK, let url = panel.url {
                            MeetingsController.rootFolder = url
                        }
                    }
                    fieldRow(
                        symbol: "person",
                        title: localized("My name"),
                        placeholder: localized("signs your lines"),
                        text: $ownerName,
                        secure: false
                    ) {
                        MeetingsController.ownerName = ownerName
                    }
                }

                // The Finder menu item is drawn by an extension, and an
                // extension arrives switched off: only System Settings can turn
                // it on, and until it is on the item simply is not there. So
                // the row says which of the two it is and opens the place where
                // that is changed — a feature that silently does nothing is
                // worse than one that is missing.
                section(localized("Finder")) {
                    actionRow(
                        symbol: "doc.on.clipboard",
                        title: localized("Copy Full Path in Finder"),
                        detail: finderMenuEnabled ? localized("Enabled") : localized("Disabled")
                    ) {
                        FIFinderSyncController.showExtensionManagementInterface()
                    }
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Live state, not a snapshot taken once at launch: System Settings can
        // flip Launch at Login from outside, and the folder can empty or fill
        // between visits to this tab (#11 taught the same lesson for the menu
        // this replaces).
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            saveClipboardImages = NotchViewModel.saveClipboardImagesEnabled
            finderMenuEnabled = FIFinderSyncController.isExtensionEnabled
            cloudHost = CloudTranscriber.host
            cloudToken = CloudCredentials.token
            ownerName = MeetingsController.ownerName
            refreshUsage()
        }
    }

    private var clearTitle: String {
        guard screenshotUsage.files > 0 else { return localized("Clear Screenshots Folder") }
        let size = ByteCountFormatter.string(fromByteCount: screenshotUsage.bytes, countStyle: .file)
        return localized("Clear Screenshots Folder (%@)", size)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { wants in
                do {
                    if wants {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("Cyclop: launch-at-login failed: \(error.localizedDescription)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        )
    }

    private var saveClipboardImagesBinding: Binding<Bool> {
        Binding(
            get: { saveClipboardImages },
            set: { wants in
                saveClipboardImages = wants
                UserDefaults.standard.set(wants, forKey: NotchViewModel.saveClipboardImagesKey)
            }
        )
    }

    /// Off the main thread: walking the folder takes as long as the folder is
    /// big, and this is the thread the whole panel lives on (#11).
    private func refreshUsage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let usage = ScreenshotVault.usage()
            DispatchQueue.main.async { screenshotUsage = usage }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func section<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 8)
            VStack(spacing: 1) {
                rows()
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
            )
        }
    }

    private func toggleRow(symbol: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    /// A settings row that holds a value rather than a switch.
    ///
    /// The value is written when editing ends, not on every keystroke: the key
    /// goes to the keychain, and storing a half-typed one there would leave the
    /// catalog claiming the cloud is configured when it is not.
    private func fieldRow(
        symbol: String,
        title: String,
        placeholder: String,
        text: Binding<String>,
        secure: Bool,
        commit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(.white)
            .tint(Theme.secondary)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 150)
            .onSubmit(commit)
            // A panel that hides on mouse-out takes the field with it, and
            // `onSubmit` alone would lose everything typed without Enter.
            .onChange(of: text.wrappedValue) { _, _ in commit() }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private func actionRow(
        symbol: String,
        title: String,
        detail: String? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}
