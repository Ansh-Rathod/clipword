# ClipWord: VSCode-like Snippet Suggestions — Comprehensive Plan

> As-you-type suggestions from clipboard history, ghost-text style, system-wide on macOS 15.

**Status:** Phases A + B implemented (sandbox removal OK'd by owner); QA pending  
**Author:** Sigil (research on `clipword` at 2026-05-13)  
**Stack:** SwiftUI · SwiftData · `LSUIElement` accessory app · `NSEvent.addGlobalMonitor` · `CGEvent` paste · `NSPanel` overlay

> **2026-09-01 — Paste reliability fix (proven empirically):** Synthetic ⌘V posted
> into the shared event stream (`CGEventPost` at `.cghidEventTap`/`.cgSessionEventTap`,
> any source) is repackaged by the window server with recomputed flags plus an
> unnamed reserved marker bit `0x20000000` (see Hammerspoon
> `extensions/eventtap/libeventtap_event.m`). Flutter-based apps silently drop
> such flag-carrying keyDowns; Chrome/Zed accept them. **Fix:** post directly to
> the target app's pid with `CGEvent.postToPid` (`PasteService.postPasteKeyEvent(to:)`),
> sequence flagsChanged(⌘ dn) → v dn → v up → flagsChanged(⌘ up), ⌘ flag =
> `0x100008` (`.maskCommand` + device-left-⌘ `0x8`), explicit unicode string on
> keyDown. Verified: pastes into Flutter/Sigil, Zed, Chrome. Verified method:
> listen-only keyspy tap to diff event streams + reading the target app's own
> Flutter widget dump via its debug VM service.

---

## 1. Executive Summary

**Goal:** When the user starts typing in *any* app (VS Code, Xcode, Slack, Chrome...), show a VSCode-like inline suggestion strip filtered from previous copies. Accept with `Tab`/`→`/`Enter`, dismiss with `Esc`. Falls back to a hotkey-triggered palette where AX is unavailable.

**Feasibility: YES.** ClipWord already has 80% of the primitives. True ghost-text is medium-hard (caret + `CGEventTap`); a triggered palette is easy. Recommend shipping in phases.

| Phase | UX | Effort | Gate |
|-------|-----|--------|------|
| **A — Triggered Palette (MVP)** | `^Space` / `;;` / double-`⌘V` near cursor, filtered list | 1–2 weeks | No AX caret, no `CGEventTap` |
| **B — Auto Inline (opt-in)** | As you type, caret-anchored, `Tab` to accept | 3–5 weeks | `AXIsProcessTrusted` + sandbox off + `CGEventTap` |
| **C — Ghost Text + IME** | Rendered inside host app via InputMethodKit | 2–3 months | Separate IMK bundle — **defer** |

**Recommendation:** Ship A behind a feature flag, validate matching/ranking, then iterate to B. Do not build C unless B proves too janky.

---

## 2. Current Architecture (ground truth)

```
Clipword/App/ClipwordApp.swift          @main App + AppDelegate — builds ModelContainer(Schema:[HistoryItem,WordFrequency,DailyStats,BookmarkItem]) at ~/Library/Application Support/Clipword/Storage.sqlite
Clipword/Services/AppState.swift         ClipboardMonitor (Timer 0.5s poll of NSPasteboard.changeCount → HistoryStore.addFromPasteboard)
Clipword/Models/HistoryItem.swift        @Model plainText, contentData:Data (PasteboardSnapshot JSON .sortedKeys), contentType/category, appBundleId, counts, pin/bookmark
Clipword/Clipboard/PasteboardTypes.swift PasteboardSnapshot.capture/write — file > url > image(PNG) > html/rtf > string
Clipword/Services/HistoryStore.swift     items/displayedItems, sorting, prune(), retention, dedupe (byte-compare + legacy fallback), select(paste:) via PasteService
Clipword/Services/SearchService.swift    exact / fuzzy(Fuse threshold 0.4) / regex / mixed over plainText/title
Clipword/Services/TypingMonitor.swift    OPT-IN global NSEvent.addGlobalMonitor .keyDown, buffer letters/numbers/' lowercased, flush on space/tab/return (36/48/49), delete 51, idleGap 2s, flushTimer 5s → analytics only
Clipword/Clipboard/PasteService.swift    AXIsProcessTrusted(+Prompt), CGEvent virtualKey 0x09 flags .maskCommand → .cghidEventTap, reactivatePreviousApp()
Clipword/App/WindowManager.swift         KeyablePanel:NSPanel .borderless .nonactivatingPanel .floating .transient hidesOnDeactivate, positionNearStatusItem
Clipword/Utilities/FloatingPanel.swift   Legacy PopupPanelController (560×520) — same tech, different anchor
Clipword/Utilities/AppPreferences.swift  Defaults[.historySize]=200, searchMode, historyRetention, typingAnalyticsEnabled=false, sortOrder, pinPosition
Clipword/Clipword.entitlements           com.apple.security.app-sandbox=true + user-selected.read-write
Clipword/Resources/Info.plist            LSUIElement=true, LSMinimumSystemVersion 15.0
```

**Key observations**
* `HistoryStore.reload()` fetchLimit `historySize+50`, `prune()` drops oldest unpinned — **200 items is trivial** for prefix filtering (<5ms).
* `TypingMonitor` is *observing* (`addGlobalMonitor`), not intercepting — it cannot swallow `Tab`. B needs `CGEventTapCreate`.
* No caret/AX code anywhere (`kAXFocusedUIElement`, `kAXSelectedTextRange`, `kAXBoundsForRange`), no `CGEventTap`, no `InputMethodKit`.
* `PasteService.paste()` already remembers `previousApp` via `WindowManager.reactivatePreviousApp()` and delays 0.12s — reusable for insertion.
* Sandbox will block reliable `CGEventTap`/`AXUIElement` for other apps. Auto-paste works today only because Accessibility is granted, but App Store sandbox is incompatible with tap.

---

## 3. Goals / Non-Goals

**Goals**
* G1 System-wide as-you-type suggestions from clipboard history (text/code/links/snippets), no Dock, no per-app plugin
* G2 VSCode fidelity: max 5 items, highlighted prefix, ghost suffix, `Tab`/`→` accepts, `Esc` dismisses, auto-dismiss on click/app switch
* G3 Fast (<80ms debounce → render), no flicker, correct multi-screen/retina/scaled positioning
* G4 Privacy: never in password/secure fields, respect `ignoredApps`/concealed types, no network
* G5 Opt-in, off by default, cheap to disable

**Non-Goals**
* Cloud sync, AI generation, templated variables (`${cursor}`), per-snippet hotkeys — future
* Full inline ghost rendered *inside* host app's text view (requires IMK) — Phase C only if needed
* Windows/Linux

---

## 4. UX Specification

### 4.1 Trigger

| Mode | How it appears | When | Notes |
|------|----------------|------|-------|
| **A hotkey** | Tiny floating palette near cursor (fallback) | User presses `^Space` (configurable, default) or types `;;` quickly, or double-taps `⌘V` within 400ms | Works everywhere, no caret needed. Uses `NSEvent.mouseLocation`. |
| **B auto** | Inline strip under caret | As user types `≥ minChars` (default 2) alphanumerics without `⌘/⌃` | Debounced 80ms. Requires `AXIsProcessTrusted` + `inlineSuggestionsEnabled`. |
| Both | Dismiss on `Esc`, click outside, app switch, `⌘` hold, buffer cleared (>1.5s idle or space/punct), host app becomes ClipWord itself | | |

Settings: `Inline Suggestions` toggle (default OFF), `Trigger` {auto, hotkey only}, `Hotkey` recorder (`KeyboardShortcuts`), `Trigger characters` (`;;`), `Min chars` 1–4 slider.

### 4.2 Overlay

* **Window:** `SuggestionPanel: KeyablePanel` — `styleMask [.borderless,.nonactivatingPanel]`, `level .popUpMenu` (A) or `.screenSaver` (B), `collectionBehavior [.canJoinAllSpaces,.stationary]`, `backgroundColor .clear`, `hasShadow true`, `hidesOnDeactivate true`, `isMovableByWindowBackground false`. SwiftUI `NSHostingView` with `VisualEffectView` + rounded 10pt.
* **Content:** Up to 5 rows. Each: `icon(category) + title(80ch head, prefix bold) + subtitle(category·words·×count) + ghost suffix faded`. Selected row blue, `↑/↓` moves, `Tab/→/Enter` accepts, `Esc` dismisses. Footer: `Tab to accept · Esc to dismiss`.
* **Position:** Query caret rect via AX (see §6). Fallback → `NSEvent.mouseLocation` with visibleFrame clamping (`visible.minX+8 ... maxX-width-8`). Respects `NSScreen.screens` + scale. Offset `y = caret.maxY + 6`, flip above if below `visible.minY`. Cache per-bundleId caret query to 50ms.
* **Performance:** Render via SwiftUI, filter synchronously on main, limit scan to `plainText.prefix(400)` head (avoids multi-MB blobs that already caused launch freeze, cf. `HistoryItem.displayTitle`).

### 4.3 Accept / Insert

1. Compute `suffix = selected.plainText[buffer.count...]` (case-preserving original, not lowercased buffer)
2. Preserve current pasteboard: `NSPasteboard.general.string(forType:.string)` snapshot + `changeCount`
3. Delete `buffer.count` chars: `CGEvent(keyCode:51)` × n (delete) posted to `.cghidEventTap` — only for B auto. For A palette, no delete needed (insert at caret via paste).
4. Insert: prefer **paste without stealing pasteboard** — write `suffix` to pasteboard with marker `com.clipword.app.marker`, `CGEvent ⌘V`, then restore after 300ms. Alternative for short suffix (<30ch): `CGEvent` keystroke injection via `CGEvent(keyboardEventSource, virtualKey, keyDown)` per char (avoids clipboard churn, but layout-dependent — prefer paste).
5. If insertion fails (secure field), just copy to clipboard + HUD "Copied — paste with ⌘V".

### 4.4 Ranking

See §7. Must not show images/files/colors; only `.text`/`.rtf`/`.html` with `plainText`.

---

## 5. Data Model & Filtering

**What to suggest**
* `HistoryStore.items` where `plainText != nil && !plainText!.isEmpty` and `contentType ∈ {.text,.rtf,.html}` and `category ∈ {.plainText,.code,.link,.styledText}` (exclude `.image/.file/.color`)
* Length: `2 ≤ plainText.count ≤ 500` (configurable max, avoid multi-MB) and `buffer.count ≥ minChars && plainText.lowercased().hasPrefix(buffer.lowercased())` for prefix mode; fallback fuzzy via `Fuse` when `hasPrefix` yields <3 and `buffer.count ≥ 3`
* Deduplicate by `plainText.lowercased()` (keep most recent `lastCopiedAt`)
* Exclude items matching `IgnoreRules.shouldIgnore` / `ignoredApps` already filtered on capture, but re-check `activeAppBundleId` vs `ignoredApps`

**Why prefix first:** User expectation is "I type `hel` → `hello world` I copied 2 mins ago" — prefix is instant, predictable, cheap. Fuzzy is for typos, but initial shipped as prefix to keep <10ms.

---

## 6. Caret Detection (hard part)

```swift
// Services/CaretProvider.swift (new)
struct CaretRect { var screenRect: NSRect; var screen: NSScreen? }

enum CaretProvider {
 static func caretRect() -> CaretRect? {
   guard AXIsProcessTrusted() else { return nil }
   let system = AXUIElementCreateSystemWide()
   var focused: AnyObject?
   guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
         let el = focused else { return nil }
   // skip password/secure fields
   if let role = ax(el, kAXRoleAttribute) as? String, role == kAXSecureTextFieldRole as String { return nil }
   if let subrole = ax(el, kAXSubroleAttribute) as? String, subrole.contains("Secure") { return nil }

   // Try kAXBoundsForRange (most accurate)
   if let rangeVal = trySelectedRange(el),
      let rect = tryBoundsForRange(el, range: rangeVal) { return screenClamped(rect) }

   // Fallback: element position+size (coarse, works for single-line fields)
   if let pos = ax(el, kAXPositionAttribute) as? NSValue, let size = ax(el, kAXSizeAttribute) as? NSValue {
     return screenClamped(NSRect(origin: pos.pointValue, size: size.sizeValue))
   }
   return nil
 }
}
```

* Must run off main? AX can block 5–20ms — dispatch to background, cache 50ms, throttle to 80ms debounce with filter.
* Known broken hosts: Electron (`VS Code`, `Slack`), Chrome — return `nil` → fallback to mouse. Acceptable for A; for B, still show at mouse with note "near cursor".
* Secure Input: additionally check `CGEventSource.keyState` / `IsSecureEventInputEnabled()` — if true, suppress suggestions entirely.

---

## 7. Matching & Ranking Algorithm

```swift
// Services/SuggestionMatcher.swift (new)
// Inputs: buffer: String (lowercased), items: [HistoryItem], limit: Int = 5
func suggestions(for buffer: String, in items: [HistoryItem]) -> [HistoryItem] {
 guard buffer.count >= Defaults[.inlineMinChars] else { return [] }
 let lower = buffer.lowercased()
 let candidates = items.filter {
   guard let t = $0.plainText, t.count >= buffer.count, t.count <= Defaults[.inlineMaxLength] else { return false }
   guard $0.contentType == .text || $0.contentType == .rtf || $0.contentType == .html else { return false }
   return t.lowercased().hasPrefix(lower)
 }
 // Optional fuzzy fallback if prefix <3 and buffer ≥3:
 // let fuzzy = Fuse(threshold:0.45).search(... ) if candidates.count < 3

 // Deduplicate by normalized text, keep most recent
 let deduped = Dictionary(grouping: candidates, by: { $0.plainText!.lowercased() })
   .compactMap { $0.value.max(by: { $0.lastCopiedAt < $1.lastCopiedAt }) }

 // Score: 0.5 recency + 0.3 copyCount + 0.2 pinned/bookmarked boost + 0.1 prefix exact-case bonus
 let now = Date()
 return deduped.sorted { a, b in score(a, lower, now) > score(b, lower, now) }.prefix(limit).map { $0 }
}
private func score(_ item: HistoryItem, _ lower: String, _ now: Date) -> Double {
 var s = 0.0
 let hours = max(0.1, now.timeIntervalSince(item.lastCopiedAt)/3600)
 s += 10 / hours // recency decay
 s += Double(min(item.copyCount, 10)) * 0.6
 if item.isPinned { s += 4 }
 if item.isBookmarked { s += 2 }
 if item.plainText?.hasPrefix(lower) == true { s += 1 } // case-sensitive bonus
 // Prefer shorter completions (less noise)
 if let t = item.plainText { s -= Double(t.count) * 0.002 }
 return s
}
```

* Keep `displayTitle` truncation (80ch/200 head) for row rendering.
* Exclude items where `plainText == buffer` (exact, no suggestion).
* Limit `plainText.prefix(400)` for `hasPrefix` to avoid scanning multi-MB (already bounded in `HistoryItem`).

---

## 8. Insertion Details

* **Preserve pasteboard:** Save `NSPasteboard.general.pasteboardItems`/`changeCount` before write, restore after `0.3s` via `DispatchQueue.main.asyncAfter`. Mark ClipWord writes with `PasteboardTypes.clipwordMarker` so `ClipboardMonitor` ignores them (already in `IgnoreRules`).
* **Delete buffer:** For B auto only. Send `buffer.count` delete key events (`kVK_Delete 0x33`) via `CGEvent`. Must not delete if fallback was mouse-anchored (no buffer context) — then just paste full item.
* **Paste:** Reuse `PasteService` pattern: `AXIsProcessTrusted` gate, `WindowManager` previousApp not needed (we never activated ClipWord — panel is nonactivating). Direct `postPasteKeyEvent` after `NSPasteboard` write.
* **Secure-field guard:** If `IsSecureEventInputEnabled()` or `kAXSecureTextFieldRole`, do not post deletes/paste — just `NSPasteboard.general.setString(item.plainText, forType:.string)` + `NSUserNotification`/HUD.

---

## 9. Permissions, Sandbox, Distribution

| Requirement | Today | Needed for A | Needed for B |
|-------------|-------|--------------|--------------|
| Accessibility (`AXIsProcessTrusted`) | Yes (paste) | Yes (global monitor) — already requested | Yes + `CGEventTap` |
| Sandbox | `true` | OK (palette at mouse, no caret) | **Must be removed** — `CGEventTapCreate`/`AXUIElement` against other apps is denied under sandbox. Keep `com.apple.security.files.user-selected.read-write` for files, drop `app-sandbox`. |
| `Info.plist` | `LSUIElement` | Add `NSAppleEventsUsageDescription` if using AppleEvents | Same |
| `generate_project.py` | `ENABLE_HARDENED_RUNTIME=YES` | Keep | Keep, but `CODE_SIGN_ENTITLEMENTS` updated |
| Distribution | Dev ID? Not App Store already | Dev ID + notarization — fine | Same |

**Action:** In `Clipword.entitlements` remove `com.apple.security.app-sandbox`, keep file entitlements. In `Info.plist` add `NSSystemAdministrationUsageDescription` string for prompt. Gate all inline code with `AXIsProcessTrusted() else { request + disable flag }` identical to `TypingMonitor.syncWithPreference()`.

---

## 10. Settings & Persistence

Add to `Utilities/AppPreferences.swift`:

```swift
static let inlineSuggestionsEnabled = Key<Bool>("inlineSuggestionsEnabled", default: false)
static let inlineTriggerMode = Key<InlineTriggerMode>("inlineTriggerMode", default: .hotkey) // .auto / .hotkey
static let inlineHotkey = Key<KeyboardShortcuts.Name>("inlineHotkey", default: .inlinePalette) // ^Space
static let inlineMinChars = Key<Int>("inlineMinChars", default: 2)
static let inlineMaxLength = Key<Int>("inlineMaxLength", default: 500)
static let inlineMaxSuggestions = Key<Int>("inlineMaxSuggestions", default: 5)
static let inlineDebounceMs = Key<Double>("inlineDebounceMs", default: 80)
enum InlineTriggerMode: String, Defaults.Serializable, CaseIterable { case auto, hotkey }
```

Expose in new Settings pane `Inline Suggestions` (or inside `General`) with: Master toggle (shows Accessibility prompt + "Grant" button calling `PasteService.requestAccessibility()`), Trigger mode picker, Hotkey recorder, Min chars slider, Max length stepper, "Show near" {caret, cursor} preview.

---

## 11. Component Diagram

```
[NSEvent global .keyDown] ──> TypingMonitor / InlineBuffer ──┐
                                                              ├─> InlineSuggestionService (debounce 80ms, filter via SuggestionMatcher, HistoryStore.items)
[CaretProvider AX] ────────── caret NSRect ──────────────────┤
                                                              ├─> SuggestionPanelController (NSPanel + HostingView)
[HistoryStore] ─────────── items ─────────────────────────────┘        │
                                                                      ├─> CGEvent delete+paste (PasteService.insertText)
                                                                      └─> NSPasteboard restore
WindowManager/StatusBarController remain unchanged (main 900×600 panel)
```

---

## 12. Files to Create / Modify

**New**
* `Clipword/Services/InlineSuggestionService.swift` — `@Observable @MainActor`, holds `currentBuffer`, debounced `suggestions:[HistoryItem]`, `selectedIndex`, `isVisible`, drives panel
* `Clipword/Services/CaretProvider.swift` — AX caret query + `IsSecureEventInputEnabled` guard + per-bundle cache
* `Clipword/Services/SuggestionMatcher.swift` — pure function `suggestions(for:in:)` + scoring (or fold into service)
* `Clipword/Views/Inline/SuggestionPanelView.swift` — SwiftUI list (5 rows + footer)
* `Clipword/Views/Inline/SuggestionPanelController.swift` — `KeyablePanel` wrapper (reuse `FloatingPanel` pattern) with `show(at:suggestions:)`/`hide()`, arrow key handling, `CGEventTap` ownership
* `Clipword/Views/Settings/InlineSettingsView.swift` — new pane

**Modify**
* `Clipword/Services/TypingMonitor.swift` — expose `currentWordBuffer` publisher or merge into `InlineSuggestionService`; add `onBufferChange` callback; ignore when ClipWord frontmost; add secure-field early return
* `Clipword/Services/AppState.swift` — own `InlineSuggestionService`, wire `typingMonitor`→service, own `CGEventTap` lifecycle gated by `Defaults[.inlineSuggestionsEnabled] && AXIsProcessTrusted()`
* `Clipword/App/ClipwordApp.swift` — create service in `applicationDidFinishLaunching`, pass to `AppState`; add `KeyboardShortcuts.Name.inlinePalette` registration
* `Clipword/Clipboard/PasteService.swift` — add `insertText(_:deleteBackCount:)` + `pasteWithPreservation(_:)` + `postDelete(count:)`
* `Clipword/Utilities/AppPreferences.swift` — keys above
* `Clipword/App/WindowManager.swift` — no change, but ensure `reactivatePreviousApp` not called for inline (panel never activates)
* `Clipword/Resources/Info.plist` — add `NSAppleEventsUsageDescription` / accessibility strings
* `Clipword/Clipword.entitlements` — remove sandbox
* `generate_project.py` — reflect entitlements change; do not add new SPM deps (no need)
* `Clipword/Views/Main/MainRootView.swift` (or Settings root) — add Inline section to sidebar

---

## 13. Detailed Implementation Steps

### Phase A — Triggered Palette (MVP, ~1–2 weeks)

1. **Prefs + hotkey** — Add `Defaults` keys, register `KeyboardShortcuts.Name.inlinePalette` (`^Space`), add toggle in Settings.
2. **Matcher** — Implement `SuggestionMatcher` (prefix, dedup, score, limit 5) with unit tests against fixture `HistoryItem`s.
3. **Panel controller** — Copy `FloatingPanel.PopupPanelController` pattern to `SuggestionPanelController` (borderless, `.popUpMenu`, `canJoinAllSpaces`). Positioning via `NSEvent.mouseLocation` + `visibleFrame` clamp.
4. **Panel view** — SwiftUI list, `ArrowFocus` reuse, `Tab/Enter/→` accept, `Esc` hide, `↑/↓` move. Accept → `HistoryStore.select(item,paste:true)` + `hide()`.
5. **Service glue** — `InlineSuggestionService` with `showPalette()` reading `HistoryStore.items`, filtering on current word fragment detected by sampling last word via AX `kAXValue` + `kAXSelectedTextRange` prefix up to caret *or* just show most recent 5 when no buffer (simplest MVP: hotkey shows recent pins/bookmarks when no prefix).
6. **Paste preservation** — Implement `PasteService.pasteWithPreservation` with marker ignore.
7. **Manual QA** — VS Code, Xcode, Chrome, Slack, Notes, Terminal.

### Phase B — Auto Inline (~3–5 weeks, behind flag)

8. **Buffer ownership** — Extend/replace `TypingMonitor` buffer to publish `currentWordBuffer` without flushing; suppress when `NSWorkspace.shared.frontmostApplication == .current`.
9. **Debounce + filter** — `InlineSuggestionService.onBufferChange` debounced 80ms, `SuggestionMatcher` call, `suggestions.isEmpty → hide`.
10. **Caret provider** — Implement `CaretProvider` with AX + secure-field guard + mouse fallback, background queue, 50ms cache.
11. **CGEventTap for Tab** — Create `CGEventTapCreate(.cghidEventTap, .headInsertEventTap, .defaultTap, [1<<kCGEventKeyDown], callback)` to intercept `Tab`/`RightArrow`/`Esc`/`Up/Down` when panel visible. Must run on `CFRunLoop`. Fallback to `NSEvent.addGlobalMonitor` + `addLocalMonitor` if tap fails (no swallow, but can still hide/accept via paste).
12. **Insertion with delete** — `PasteService.insertText(suffix, deleteBackCount: buffer.count)` — delete then paste suffix, with pasteboard preservation.
13. **Throttling & safety** — Ignore if `IsSecureEventInputEnabled()`, if `buffer` contains non alphanumerics, if host is password manager (`ignoredApps` includes `com.apple.Passwords` already), if ClipWord frontmost.
14. **Settings polish** — Auto vs hotkey toggle, minChars, debounce, maxLength, enable/disable UX with Accessibility prompt.
15. **QA matrix** — See §15.

### Phase C — Ghost (defer)

* Only if B's floating strip feels wrong. Requires `InputMethodKit` bundle `ClipwordIMK.appex`, `IMKInputController.markedText`, enabled in `System Settings → Keyboard → Input Sources`. High friction.

---

## 14. Edge Cases & Mitigations

* **Multi-MB copies** — Already bounded via `HistoryItem.displayTitle` (200 head) and `PasteboardSnapshot.encode` — matcher caps at 400ch head. No O(n) over blob.
* **Password fields / Secure Input** — Check `kAXSecureTextFieldRole` + `IsSecureEventInputEnabled()` → suppress.
* **Own pasteboard writes** — Tag with `com.clipword.app.marker`, `IgnoreRules` already ignores — prevents suggestion loop.
* **ClipWord frontmost** — Suppress global buffer when `NSWorkspace.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier`.
* **Mouse vs caret mismatch** — Always prefer caret; when nil show at mouse with 0.9 opacity and "near cursor" caption to set expectation.
* **Retina / multi-screen** — Convert AX rect (screen coords bottom-left origin) via `NSScreen` + `backingScaleFactor`; clamp to `visibleFrame`.
* **Cmd/Control held** — `TypingMonitor` already early-returns on `.command/.control` — reuse.
* **Rapid typing / flicker** — Debounce 80ms + `suggestions` diff (only update panel when array changes).
* **App switch mid-buffer** — Clear `currentWordBuffer` on `NSWorkspace.didActivateApplicationNotification`.
* **Accessibility revoked** — `syncWithPreference` pattern: disable flag + show Settings banner.
* **History empty / filtered** — Show nothing, not "No items".
* **Pasteboard restore failure** — Timeout 300ms restore is best-effort; log but don't block.

---

## 15. Testing Plan

**Unit**
* `SuggestionMatcherTests` — prefix exact, case-insensitive, dedup, pinned boost, recency, maxLength filter, empty buffer, secure-field exclusion.
* `CaretProviderTests` — mock AX (inject `AXUIElement` protocol) for success/nil/secure cases.

**Manual matrix** (A + B)
* Hosts: VS Code, Xcode, TextEdit, Chrome (docs + password field), Slack, Notion, Terminal/iTerm, Finder rename, Spotlight.
* Screens: single, dual, Retina 2x, scaled, Spaces, fullscreen.
* Inputs: `hel` → `hello`, code snippet `func `, link `https://`, 3-char fuzzy, rapid typing, delete/backspace, `Esc`, `Tab` accept, `→` accept, click-outside dismiss, `⌘Tab` switch.
* Permissions: Accessibility denied/granted/revoked mid-session, Secure Input enabled (1Password).
* Performance: hold key repeat, 200 items, 10MB item in store (should not hang).

**Automation**
* `xcodebuild test` for matcher; no UI automation for AX (manual).

---

## 16. Metrics (local only, no network)

* `suggestionsShown`, `accepted`, `dismissed`, `hotkeyInvoked` counters in `AnalyticsEngine` (extend `DailyStats`).
* Acceptance rate = accepted/shown — target >25% for auto, >60% for palette.
* Time-to-accept latency (buffer→accept) — target p50 <600ms.

---

## 17. Rollout

1. Behind `Defaults[.inlineSuggestionsEnabled]=false` (default OFF).
2. Ship Phase A in next minor (e.g. 1.3) — announce as "Snippet Palette (beta)" with `^Space`.
3. Dogfood 1 week, tune ranking (especially `copyCount` vs recency weight).
4. Phase B as opt-in `Auto inline` toggle — requires explicit Accessibility re-prompt + sandbox removal + notarized DMG.
5. If acceptance > threshold and no AX complaints, flip default for new installs to `auto` in following release.

---

## 18. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| AX broken in Electron/Chrome | High | Suggestions at mouse, not caret | Mouse fallback + caption; document limitation |
| Sandbox removal blocks App Store | Certain | Cannot ship to App Store | ClipWord is already LSUIElement + auto-paste — App Store was never viable; stay Developer ID + notarization (current path) |
| CGEventTap requires extra prompt / fails | Med | Tab not intercepted | Fallback to palette-only; show "Grant Input Monitoring" guide |
| Performance regression (AX 20ms) | Med | Typing lag | Background queue + 80ms debounce + cache |
| Pasteboard churn annoys users | Low | Overwrites clipboard | Preservation restore + marker; offer keystroke injection for short suffixes |
| Security review (keylogging fear) | Med | User distrust | Local-only, opt-in, explicit Accessibility prompt, respect Secure Input, open-source matcher |

---

## 19. Alternatives Considered

* **In-app only autocomplete (inside ClipWord panel)** — Trivial (filter `displayedItems`) but not the ask; user wants it *while typing in other apps*.
* **Poll pasteboard + periodically sample frontmost text** — Polling AX every 0.5s is wasteful + misses keystrokes.
* **Replace TypingMonitor with InputMethodKit immediately** — Most faithful ghost text, but requires Input Source enablement, separate bundle, breaks for many users — overkill until B validates demand.
* **Use `CGEventTap` to capture every keystroke instead of `NSEvent monitor`** — More powerful (can swallow Tab) but needs same permission; keep `NSEvent` for observation + `CGEventTap` only when panel visible to minimize tap lifetime.

---

## 20. Resolved Decisions

1. **Hotkey: `⌥Space` (Option+Space), user-configurable via recorder.** Rejected `⌘Space` (Spotlight), `⌃Space` (VS Code "Trigger Suggest" — collides in the primary target app), `⇧⌘C` (taken by main window). Only common conflict is Alfred; recorder allows change. The `;;` digraph trigger is deferred (Phase B consideration).
2. **Min chars: 2** for prefix suggestions; empty query shows recent text items instead. Revisit after dogfooding.
3. **Insertion: paste-based** (clipboard write + `⌘V` with marker ignore) — layout-safe. Keystroke injection only if pasteboard flicker complaints materialize.
4. **TypingMonitor stays separate** for Phase A (palette owns its own text field — no global buffer needed). Unify in Phase B.
5. **Sandbox: removed** — owner confirmed App Store distribution is abandoned; Developer ID + notarization only.

---

## 21. Checklist (copy into issue)

- [x] Resolve open questions → §20 decisions
- [x] Remove sandbox in entitlements
- [x] Add `Defaults` keys + Settings UI + `KeyboardShortcuts.Name.inlinePalette` (⌥Space)
- [x] Implement `SuggestionMatcher`
- [x] Build `SuggestionPanelView` + `SuggestionPanelController` (mouse-anchored palette with type-to-filter)
- [x] Wire hotkey via `AppState`/`ClipwordApp` → palette
- [x] Manual QA matrix for A (palette shows, paste lands, focus restores)
- [x] Implement `CaretProvider` + secure-field guard
- [x] Add `InlineKeyTap` (CGEventTap) for Tab/Esc interception + `PasteService.insertText(_:deleteBackCount:)` with clipboard restore
- [x] Wire auto buffer + debounce + caret-anchored ghost panel (`InlineSuggestionService`, `InlineSuggestionPanel`)
- [x] Settings: trigger mode picker (As you type / Hotkey only)
- [ ] Update `generate_project.py` Info.plist strings if needed
- [ ] QA matrix for B + performance profile
- [ ] Analytics counters + Settings banner for Accessibility
- [ ] Unit tests for `SuggestionMatcher`
- [ ] Docs + release notes

---

*Plan covers ClipWord at `Clipword/App/ClipwordApp.swift`, `Clipword/Services/{AppState,HistoryStore,SearchService,TypingMonitor}`, `Clipword/Clipboard/{PasteService,PasteboardTypes}`, `Clipword/App/WindowManager`, `Clipword/Utilities/{FloatingPanel,AppPreferences}`, `Clipword/Models/HistoryItem`, `Clipword.entitlements`, `Resources/Info.plist`, `generate_project.py`.*
