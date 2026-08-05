import AppKit
import CyclopDictation

/// Watches the right Option key, system-wide.
///
/// Right Option is free of macOS shortcuts (unlike F5, which is Dictation) and
/// is not the one used to type special characters, which is the left. Reading
/// it anywhere but in our own windows needs an event tap, and an event tap
/// needs Accessibility — the permission is requested when dictation is first
/// used, never at launch.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = HoldGesture(minimumHold: 0.25)

    /// Virtual keycode of the right Option key.
    private static let rightOptionKeyCode: Int64 = 61

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt. Only ever called from an explicit user action.
    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasAccessibilityPermission else { return false }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Listen only: the key must keep working for whoever else wants it.
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The tap is disabled by the system if it ever times out; re-arming is
        // cheaper than losing the hotkey until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOptionKeyCode
        else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let isDown = event.flags.contains(.maskAlternate)
        if isDown {
            if gesture.press(at: now) { onPress?() }
        } else {
            if case .recorded(let held) = gesture.release(at: now) { onRelease?(held) }
            else { onRelease?(0) }
        }
    }
}
