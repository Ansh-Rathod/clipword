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

    /// True when the text is safe to deliver as typed keystrokes: no newlines
    /// (typing "return" would trigger form submits / chat sends), non-empty.
    private static func isTypeable(_ text: String) -> Bool {
        !text.isEmpty && text.rangeOfCharacter(from: .newlines) == nil
    }

    static func paste(item: HistoryItem? = nil) {
        guard isAccessibilityTrusted else {
            requestAccessibility()
            return
        }

        // Delivery strategy:
        // - single-line plain text → typed keystroke injection (works in
        //   Chromium web content, Flutter, native apps; no clipboard churn)
        // - multi-line text / rich content → synthetic ⌘V posted to the target
        //   app's pid (typing newlines would trigger form submits/chat sends)
        let typeableText: String? = {
            guard let text = item?.plainText, isTypeable(text) else { return nil }
            return text
        }()

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
                if let typeableText {
                    print("[Paste] typing \(typeableText.count) chars into pid \(target.processIdentifier) (\(name))")
                    injectText(typeableText, to: target.processIdentifier)
                } else {
                    print("[Paste] posting ⌘V to pid \(target.processIdentifier) (\(name))")
                    postPasteKeyEvent(to: target.processIdentifier)
                }
            }
        } else {
            let front = NSWorkspace.shared.frontmostApplication
            if let typeableText {
                print("[Paste] typing \(typeableText.count) chars into current app pid \(front?.processIdentifier ?? 0) (\(front?.localizedName ?? "?"))")
                injectText(typeableText, to: front?.processIdentifier)
            } else {
                print("[Paste] posting ⌘V to current app pid \(front?.processIdentifier ?? 0) (\(front?.localizedName ?? "?"))")
                postPasteKeyEvent(to: nil)
            }
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

    /// Phase B inline accept: deletes the typed prefix (backspace × n), then
    /// inserts the snippet. Single-line snippets are typed directly (keystroke
    /// injection) — no clipboard borrow, no ⌘V, no restore dance. Multi-line
    /// snippets fall back to clipboard + ⌘V (typing newlines would trigger
    /// form submits / chat sends).
    static func insertText(_ item: HistoryItem, deleteBackCount: Int) {
        guard isAccessibilityTrusted else {
            requestAccessibility()
            return
        }
        guard let text = item.plainText, !text.isEmpty else { return }

        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        if isTypeable(text) {
            // Delete the typed prefix first.
            for _ in 0..<deleteBackCount {
                postKeyEvent(virtualKey: 51) // kVK_Delete
            }
            if deleteBackCount > 0 {
                usleep(50_000)
            }
            injectText(text, to: targetPid)
            return
        }

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
            postPasteKeyEvent(to: targetPid)
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

    /// macOS virtual keycodes for characters, used only as a hint — the actual
    /// character travels in the event's unicode string (keycode 0 otherwise).
    private static let charKeycodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46, " ": 49,
    ]

    /// Types `text` as per-character keyDown/keyUp events posted directly to
    /// the target app's pid, with the real character in the event's unicode
    /// string. This is the only delivery path accepted by Chromium *web
    /// content* (email fields etc.): synthetic ⌘-modified keyDowns — posted
    /// via pid or the event stream — are dropped there, but plain keyDowns
    /// are inserted (verified against Helium, Flutter/Sigil, Zed).
    /// Must not contain newlines — see `isTypeable(_:)`.
    private static func injectText(_ text: String, to targetPid: pid_t?) {
        func post(_ virtualKey: CGKeyCode, _ down: Bool, characters: String) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: down)
            if down {
                var chars = Array(characters.utf16)
                event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            }
            if let targetPid {
                event?.postToPid(targetPid)
            } else {
                event?.post(tap: .cgSessionEventTap)
            }
        }

        for ch in text {
            let virtualKey = charKeycodes[Character(ch.lowercased())] ?? 0
            post(virtualKey, true, characters: String(ch))
            usleep(1_500)
            post(virtualKey, false, characters: String(ch))
            usleep(1_500)
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
