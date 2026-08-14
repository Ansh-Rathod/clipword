import AppKit
import ApplicationServices
import Foundation

@MainActor
enum PasteService {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func paste() {
        guard isAccessibilityTrusted else {
            requestAccessibility()
            return
        }

        // Deliver the keystroke to the app the user came from, not to Clipword:
        // our popup only ever activates Clipword itself. Wait a beat after the
        // app switch so the target app is frontmost before the event is posted.
        let switchedBack = WindowManager.shared.reactivatePreviousApp()
        let delay = switchedBack ? 0.12 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            postPasteKeyEvent()
        }
    }

    private static func postPasteKeyEvent() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    static func copyToClipboard(snapshot: PasteboardSnapshot, withoutFormatting: Bool) {
        let pasteboard = NSPasteboard.general
        snapshot.write(to: pasteboard, withoutFormatting: withoutFormatting)
    }
}
