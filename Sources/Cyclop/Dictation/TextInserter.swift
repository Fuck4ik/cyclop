import AppKit

/// Puts text into the focused field of whatever app is in front.
///
/// Through the pasteboard and a synthetic ⌘V: typing the characters one by one
/// would need the same Accessibility permission and would be slower and less
/// reliable with non-Latin text. The previous pasteboard contents are restored
/// afterwards — a dictation should not cost the user what they had copied.
enum TextInserter {
    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        // Marks both writes below as Cyclop's own, the same convention
        // ShelfStore.copy uses, so ClipboardStore's history poll (which runs
        // twice a second) skips them. Without it a single dictation shows up
        // as two extra history entries — the recognised text, then the old
        // clipboard content again with a fresh timestamp, masquerading as a
        // new copy the user never made.
        pasteboard.setData(Data(), forType: .cyclopInternal)
        pasteboard.setString(text, forType: .string)
        let changeCountAfterInsert = pasteboard.changeCount

        postPaste()

        // Long enough for the target app to have read the pasteboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let saved else { return }
            // If the change count moved since we set it, the user copied
            // something of their own in the meantime (e.g. pressed ⌘C right
            // after the paste). Restoring unconditionally would silently
            // overwrite that copy with whatever predates the dictation, even
            // though the history list already shows their new item — so skip
            // the restore rather than fight a copy that came after ours.
            guard pasteboard.changeCount == changeCountAfterInsert else { return }
            pasteboard.clearContents()
            pasteboard.setData(Data(), forType: .cyclopInternal)
            pasteboard.setString(saved, forType: .string)
        }
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // 9 is the "v" key.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
