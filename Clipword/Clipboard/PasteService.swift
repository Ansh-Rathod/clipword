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
        // our popup only ever activates Clipword itself.
        let target = WindowManager.shared.reactivatePreviousApp()
        if let target {
            // Don't post on a fixed timer — slow apps (Electron, debug-mode
            // Flutter builds) can still be settling 120ms after activation and
            // silently drop the synthetic keystroke. Wait until the target is
            // actually frontmost (bounded), then paste.
            let name = target.localizedName ?? "pid \(target.processIdentifier)"
            print("[Paste] switched back to \(name); waiting for frontmost…")
            waitForFrontmost(target, timeout: 0.7) {
                print("[Paste] posting ⌘V to pid \(target.processIdentifier) (\(name))")
                postPasteKeyEvent(to: target.processIdentifier)
            }
        } else {
            let front = NSWorkspace.shared.frontmostApplication
            print("[Paste] posting ⌘V to current app pid \(front?.processIdentifier ?? 0) (\(front?.localizedName ?? "?"))")
            postPasteKeyEvent(to: nil)
        }
    }

    private static func waitForFrontmost(_ app: NSRunningApplication, timeout: TimeInterval, then action: @escaping () -> Void) {
        let start = Date()
        func poll() {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                action()
            } else if Date().timeIntervalSince(start) < timeout {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
            } else {
                // Best effort: activation never confirmed, paste anyway.
                print("[Paste] frontmost wait timed out for \(app.localizedName ?? "?") — posting anyway")
                action()
            }
        }
        poll()
    }

    /// Posts ⌘V **directly to the target app's pid** (`CGEvent.postToPid`).
    ///
    /// Verified empirically (keyspy + Sigil's own widget dump, 2026-09):
    /// events injected into the shared event stream via `CGEventPost` get
    /// repackaged by the window server with a reserved marker bit
    /// (0x20000000, see Hammerspoon's libeventtap_event.m) plus recomputed
    /// flags, and Flutter-based apps silently drop those keyDowns. Events
    /// posted to the pid bypass the window-server repackage and are accepted
    /// by Flutter, Chrome, Zed, etc.
    ///
    /// Sequence mirrors AppleScript `keystroke "v" using command down`:
    /// flagsChanged(⌘ down) → v down → v up → flagsChanged(⌘ up), with the
    /// ⌘ flag including the device-specific left-command bit (0x8).
    private static func postPasteKeyEvent(to targetPid: pid_t?) {
        let pid = targetPid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        // .maskCommand | NX_DEVICELCOMMANDKEYMASK (0x100000 | 0x8)
        let cmdFlags = CGEventFlags(rawValue: 0x100008)

        func route(_ event: CGEvent) {
            if let pid {
                event.postToPid(pid)
            } else {
                event.post(tap: .cgSessionEventTap) // fallback: no pid known
            }
        }
        func postV(_ down: Bool) {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: down)
            e?.flags = cmdFlags
            if down {
                var chars = Array("v".utf16)
                e?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            }
            route(e!)
        }
        func postCmdChange(_ down: Bool) {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            e?.type = .flagsChanged
            e?.flags = down ? cmdFlags : []
            route(e!)
        }

        postCmdChange(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
            postV(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                postV(false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
                    postCmdChange(false)
                }
            }
        }
    }

    /// Phase B inline accept: deletes the typed prefix (backspace × n), writes
    /// the snippet to the pasteboard, simulates ⌘V, then restores the user's
    /// previous clipboard content (marked so ClipboardMonitor ignores the churn).
    static func insertText(_ item: HistoryItem, deleteBackCount: Int) {
        guard isAccessibilityTrusted else {
            requestAccessibility()
            return
        }
        guard let text = item.plainText, !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("clipword", forType: PasteboardTypes.clipwordMarker)

        // Delete the typed prefix first.
        for _ in 0..<deleteBackCount {
            postKeyEvent(virtualKey: 51) // kVK_Delete
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            postPasteKeyEvent(to: nil)
            // Restore what the user had on the clipboard before we borrowed it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let saved, !saved.isEmpty else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(saved, forType: .string)
                pb.setString("clipword", forType: PasteboardTypes.clipwordMarker)
            }
        }
    }

    private static func postKeyEvent(virtualKey: CGKeyCode, flags: CGEventFlags = [], isKeyUp: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: !isKeyUp)
        if !flags.isEmpty { event?.flags = flags }
        event?.post(tap: .cghidEventTap)
    }

    static func copyToClipboard(snapshot: PasteboardSnapshot, withoutFormatting: Bool) {
        let pasteboard = NSPasteboard.general
        snapshot.write(to: pasteboard, withoutFormatting: withoutFormatting)
    }
}
