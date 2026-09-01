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
        // - multi-line text / rich content → Edit→Paste menu press (access-
        //   ibility), falling back to synthetic ⌘V pid-post when the target
        //   has no Paste menu item (typing newlines would trigger form
        //   submits / chat sends)
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
                } else if pasteViaMenu(of: target) {
                    print("[Paste] pasted via Edit→Paste menu of \(name)")
                } else {
                    print("[Paste] no Paste menu in \(name) — posting ⌘V to pid \(target.processIdentifier)")
                    postPasteKeyEvent(to: target.processIdentifier)
                }
            }
        } else {
            let front = NSWorkspace.shared.frontmostApplication
            if let typeableText {
                print("[Paste] typing \(typeableText.count) chars into current app pid \(front?.processIdentifier ?? 0) (\(front?.localizedName ?? "?"))")
                injectText(typeableText, to: front?.processIdentifier)
            } else if let front, pasteViaMenu(of: front) {
                print("[Paste] pasted via Edit→Paste menu of \(front.localizedName ?? "?")")
            } else {
                print("[Paste] posting ⌘V to current app pid \(front?.processIdentifier ?? 0) (\(front?.localizedName ?? "?"))")
                postPasteKeyEvent(to: nil)
            }
        }
    }

    /// Pastes by AX-pressing the target app's Edit→Paste menu item. This
    /// goes through the real menu action path and works everywhere synthetic
    /// ⌘V key events fail — including Chromium *web content* (email fields
    /// etc. drop synthetic ⌘-modified keyDowns but honor the menu action).
    /// Requires the app to be frontmost (we open its menu bar).
    /// Returns false when no Edit→Paste item exists (caller falls back to ⌘V).
    private static func pasteViaMenu(of app: NSRunningApplication) -> Bool {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)

        var menubarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &menubarRef) == .success,
              let menubar = menubarRef as! AXUIElement? else { return false }

        var editItem: AXUIElement?
        var menusRef: CFTypeRef?
        AXUIElementCopyAttributeValue(menubar, kAXChildrenAttribute as CFString, &menusRef)
        for menu in (menusRef as? [AXUIElement]) ?? [] {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(menu, kAXTitleAttribute as CFString, &titleRef)
            if titleRef as? String == "Edit" { editItem = menu; break }
        }
        guard let editItem else { return false }

        // Opening the menu forces Chromium to materialize its item tree.
        guard AXUIElementPerformAction(editItem, kAXPressAction as CFString) == .success else { return false }

        var pasteMenuItem: AXUIElement?
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline && pasteMenuItem == nil {
            pasteMenuItem = findMenuItemTitled("Paste", under: editItem)
            if pasteMenuItem == nil { usleep(80_000) }
        }
        guard let pasteMenuItem else {
            postEscapeKey(to: app.processIdentifier)
            return false
        }

        let result = AXUIElementPerformAction(pasteMenuItem, kAXPressAction as CFString)
        return result == .success
    }

    private static func findMenuItemTitled(_ title: String, under element: AXUIElement) -> AXUIElement? {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? "?"
        if role == "AXMenuItem" {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
            if titleRef as? String == title { return element }
        }
        var kidsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kidsRef)
        for kid in (kidsRef as? [AXUIElement]) ?? [] {
            if let hit = findMenuItemTitled(title, under: kid) { return hit }
        }
        return nil
    }

    private static func postEscapeKey(to pid: pid_t) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)
        down?.postToPid(pid)
        usleep(30_000)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
        up?.postToPid(pid)
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
            var pasted = false
            if let front = NSWorkspace.shared.frontmostApplication {
                pasted = pasteViaMenu(of: front)
            }
            if !pasted {
                postPasteKeyEvent(to: targetPid)
            }
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

    /// Types `text` as keyDown/keyUp events posted directly to the target
    /// app's pid, with the real text in the event's unicode string, chunked
    /// at 20 UTF-16 units (espanso's proven chunk size — some apps truncate
    /// longer unicode strings; ~3000 chars/s). This is the only delivery path
    /// accepted by Chromium *web content* (email fields etc.): synthetic
    /// ⌘-modified keyDowns — posted via pid or the event stream — are dropped
    /// there, but plain keyDowns are inserted (verified against Helium,
    /// Flutter/Sigil, Zed). Must not contain newlines — see `isTypeable(_:)`.
    private static func injectText(_ text: String, to targetPid: pid_t?) {
        func post(_ down: Bool, chunk: [UniChar]) {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            var chars = chunk
            event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            if let targetPid {
                event?.postToPid(targetPid)
            } else {
                event?.post(tap: .cgSessionEventTap)
            }
        }

        // 20 UTF-16 units per chunk (espanso uses the same limit).
        var chunk: [UniChar] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 {
                post(true, chunk: chunk)
                usleep(2_000)
                post(false, chunk: chunk)
                usleep(3_000)
                chunk = []
            }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty {
            post(true, chunk: chunk)
            usleep(2_000)
            post(false, chunk: chunk)
            usleep(3_000)
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
