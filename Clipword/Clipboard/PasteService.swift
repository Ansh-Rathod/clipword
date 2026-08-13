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
