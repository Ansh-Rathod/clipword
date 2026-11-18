#if DEBUG
import AppKit
import Defaults
import Foundation
import OSLog

/// Debug-only data seeding + performance self-test. Wired into the status-bar
/// menu (right-click) in DEBUG builds; compiled out of Release entirely.
///
/// Seeded rows go through `HistoryStore.addSnapshot` — the real encode/hash/
/// dedupe/classify pipeline — so seeding is also a throughput measurement of
/// the copy path (watch the `snapshot.*` and `store.*` signposts while it runs).
@MainActor
enum DebugTools {
    /// Every seeded row's plainText starts with this marker so they can be
    /// bulk-deleted without touching real history.
    static let seedMarker = "clipword-seed-"

    /// Inserts `count` unique rows (dedupe would otherwise collapse repeats).
    /// Mixes short text, URLs and one ~200KB payload per hundred rows to
    /// exercise external-storage blobs and the bounded search/analytics paths.
    @discardableResult
    static func seedItems(_ count: Int, into store: HistoryStore) -> String {
        Perf.event("debug.seed.begin", "count=\(count)")
        var timer = PerfTimer()
        var inserted = 0
        var bigPayload = String(repeating: "payload-", count: 200_000 / 8)
        bigPayload.append("seed-end")

        for i in 0..<count {
            let text = seededText(index: i, bigPayload: bigPayload)
            let snapshot = PasteboardSnapshot(
                plainText: text,
                contentType: .text,
                pasteboardTypes: ["public.utf8-plain-text"],
                hasColorOnPasteboard: false
            )
            // deferRefresh: the whole loop pays one derived rebuild below,
            // not one O(n) rebuild per row.
            if let item = store.addSnapshot(snapshot, deferRefresh: true) {
                // Spread timestamps ~1min apart so seeds sort like real
                // history — a shared timestamp makes row order unstable
                // across rebuilds and produces multiple day sections.
                let stamp = Date(timeIntervalSinceNow: -Double(count - i) * 60)
                item.firstCopiedAt = stamp
                item.lastCopiedAt = stamp
                inserted += 1
            }
            if i > 0, i % 250 == 0 {
                timer.mark("seeded \(i) of \(count)")
            }
        }
        try? store.modelContext.save()
        store.refreshWithoutFetch()
        timer.mark("seeded \(inserted) rows + final rebuild")
        let report = "Seed \(count): inserted \(inserted)\n\(timer.report())"
        Perf.log.info("\(report, privacy: .public)")
        print("[Clipword] \(report)")
        Perf.event("debug.seed.end", "inserted=\(inserted)")
        return report
    }

    private static func seededText(index: Int, bigPayload: String) -> String {
        switch index % 20 {
        case 0:
            return "\(seedMarker)\(index) https://example.com/page/\(index)?q=perf-test"
        case 5:
            return "\(seedMarker)\(index) func build\(index)() -> View { /* seeded code */ }"
        case 10:
            return "\(seedMarker)\(index) \(bigPayload)"
        default:
            return "\(seedMarker)\(index) Seeded clipboard row \(index) — the quick brown fox jumps over the lazy dog."
        }
    }

    /// Deletes every row created by `seedItems` in one save + one rebuild.
    @discardableResult
    static func clearSeededItems(from store: HistoryStore) -> String {
        var timer = PerfTimer()
        let marker = seedMarker
        let removed = store.deleteItems { $0.plainText?.hasPrefix(marker) ?? false }
        timer.mark("deleted \(removed) seeded rows")
        let report = "Clear seeded: removed \(removed)\n\(timer.report())"
        Perf.log.info("\(report, privacy: .public)")
        print("[Clipword] \(report)")
        return report
    }

    /// Measures the hot paths against whatever is currently in the store —
    /// seed first for meaningful numbers. Output goes to stdout, the unified
    /// log, and `Perf.log` (subsystem com.clipword.app, category perf).
    @discardableResult
    static func runPerfSelfTest(store: HistoryStore, search: SearchService) -> String {
        Perf.event("debug.selftest.begin")
        var timer = PerfTimer()

        store.reload()
        timer.mark("reload (\(store.items.count) items)")

        let savedQuery = store.searchQuery
        let savedMode = Defaults[.searchMode]
        defer {
            store.searchQuery = savedQuery
            Defaults[.searchMode] = savedMode
            store.applyFilters(using: search)
        }

        for mode in SearchMode.allCases {
            Defaults[.searchMode] = mode
            store.searchQuery = "seed"
            store.applyFilters(using: search)
            timer.mark("applyFilters \(mode) 'seed' → \(store.displayedItems.count)")
        }

        store.searchQuery = ""
        store.applyFilters(using: search)
        timer.mark("applyFilters reset → \(store.displayedItems.count)")

        // Arrow-key path: selection→index, index→row. O(1) per hop via the
        // cached maps; this lap should stay ~flat no matter the store size.
        var checksum = 0
        let rows = store.paletteRows
        if !rows.isEmpty {
            for i in 0..<1000 {
                let row = rows[i % rows.count]
                if let index = store.paletteIndexBySelection[row.selection] {
                    checksum &+= index
                }
            }
        }
        timer.mark("1000 selection→index lookups")

        let snapshot = PasteboardSnapshot(
            plainText: "\(seedMarker)selftest-\(UUID().uuidString)",
            contentType: .text,
            pasteboardTypes: ["public.utf8-plain-text"],
            hasColorOnPasteboard: false
        )
        let added = store.addSnapshot(snapshot)
        timer.mark("addSnapshot (insert)")

        if let added {
            _ = store.deleteItems { $0.id == added.id }
        }
        timer.mark("delete inserted row")

        let report = """
        Perf self-test (\(store.items.count) items, \(store.bookmarks.count) bookmarks)
        \(timer.report())
        """
        Perf.log.info("\(report, privacy: .public)")
        print("[Clipword] \(report)")
        Perf.event("debug.selftest.end")
        return report
    }

    /// Set while `navTest` runs — gates per-press `[mv]` logging so normal
    /// DEBUG sessions don't grow /tmp/navtest-app.log on every arrow key.
    static var navTestActive = false

    // MARK: - Click-latency profiling (--click-test)

    /// Marks collected for the current synthetic click: (name, time since
    /// the click was sent). Reset at each click.send.
    static var clickT0 = ContinuousClock.now
    static var clickMarks: [(name: String, ms: Double)] = []
    static var rowEvals = 0
    private static var applySignpost: OSSignpostIntervalState?

    /// Timestamp a stage of the click pipeline from instrumented call sites.
    /// Emits Instruments marks as well so the same run produces a flame view.
    static func clickMark(_ name: String) {
        guard navTestActive else { return }
        let ms = Double((ContinuousClock.now - clickT0).components.seconds) * 1000
            + Double((ContinuousClock.now - clickT0).components.attoseconds) / 1e15
        clickMarks.append((name, ms))
        switch name {
        case "tap": applySignpost = Perf.begin("click.apply")
        case "applied":
            if let s = applySignpost { Perf.end("click.apply", s) }
        default: break
        }
    }

    /// Count a row-builder evaluation — breadth of the click-driven rebuild.
    static func clickRowEval() {
        if navTestActive { rowEvals += 1 }
    }

    /// Appends a line to /tmp/navtest-app.log — file-based because stdout is
    /// fully buffered when the app isn't launched from a terminal.
    nonisolated static func navLog(_ s: String) {
        let url = URL(fileURLWithPath: "/tmp/navtest-app.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data("\(s)\n".utf8))
            try? h.close()
        }
    }

    /// Opens the palette and posts synthetic ↓ keyDown events through
    /// `NSApp.sendEvent`, logging the selection index after each. Diagnoses
    /// arrow-key navigation without UI automation tools.
    private static func navTest(appState: AppState) {
        let store = appState.historyStore
        navTestActive = true
        appState.showWindow(source: .history)
        let logURL = URL(fileURLWithPath: "/tmp/navtest-app.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        func findTable(in view: NSView) -> NSTableView? {
            if let t = view as? NSTableView { return t }
            for sub in view.subviews {
                if let t = findTable(in: sub) { return t }
            }
            return nil
        }
        func logSel(_ tag: String) {
            let sel = appState.paletteSelection
            let idx = sel.flatMap { store.paletteIndexBySelection[$0] }
            var tableInfo = "no-table"
            if let win = NSApp.keyWindow ?? NSApp.windows.first,
               let table = findTable(in: win.contentView!) {
                let vis = table.visibleRect
                let rows = table.rows(in: vis)
                tableInfo = "rows=\(table.numberOfRows) visible=\(rows.location)-\(rows.location + rows.length - 1) clipY=\(Int(vis.origin.y))"
            }
            navLog("[nav-test] \(tag): idx=\(String(describing: idx)) \(tableInfo) vis=\(WindowManager.shared.isVisible)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            logSel("after show")
            // Watch the list's clip view: log a backtrace on any large upward
            // jump so we can see who snapped the scroll back to top.
            var lastY: CGFloat = 0
            if let win = NSApp.keyWindow ?? NSApp.windows.first,
               let table = findTable(in: win.contentView!),
               let clip = table.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clip, queue: .main
                ) { _ in
                    let y = clip.bounds.origin.y
                    if lastY - y > 50 {
                        let stack = Thread.callStackSymbols.prefix(14).joined(separator: "\n")
                        navLog("[snap-up] \(Int(lastY))->\(Int(y))\n\(stack)")
                    }
                    lastY = y
                }
            }
            func sendArrow(_ keyCode: UInt16, _ char: String) {
                let win = NSApp.keyWindow?.windowNumber ?? 0
                let down = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: win, context: nil,
                    characters: char, charactersIgnoringModifiers: char,
                    isARepeat: false, keyCode: keyCode
                )
                let up = NSEvent.keyEvent(
                    with: .keyUp, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: win, context: nil,
                    characters: char, charactersIgnoringModifiers: char,
                    isARepeat: false, keyCode: keyCode
                )
                if let down, let up {
                    NSApp.sendEvent(down)
                    NSApp.sendEvent(up)
                } else {
                    navLog("failed to create event")
                }
            }
            for i in 0..<30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i + 1)) {
                    sendArrow(125, "\u{F701}") // down
                    // Log 0.18s later so a deferred SwiftUI onKeyPress update
                    // has landed — logging immediately after sendEvent races it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        logSel("down \(i + 1)")
                    }
                }
            }
            for i in 0..<12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(31 + i)) {
                    sendArrow(126, "\u{F700}") // up
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        logSel("up \(i + 1)")
                    }
                }
            }
            // Right-click a visible row to exercise the table-level NSMenu
            // (TableContextMenuInstaller replaces per-row .contextMenu).
            // The builder logs "[menu] row=… items=…" when it runs.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * 44) {
                guard let win = NSApp.keyWindow ?? NSApp.windows.first,
                      let table = findTable(in: win.contentView!) else {
                    navLog("[menu] no table")
                    return
                }
                let visRow = table.rows(in: table.visibleRect).location + 1
                navLog("[menu] click row=\(visRow) rows=\(table.numberOfRows)")
                let rect = table.rect(ofRow: visRow)
                let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                guard let ev = NSEvent.mouseEvent(
                    with: .rightMouseDown, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: win.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ) else {
                    navLog("[menu] failed to create event")
                    return
                }
                // popUpContextMenu tracks modally until dismissed — post a real
                // Escape through the HID tap so sendEvent returns.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?
                        .post(tap: .cghidEventTap)
                }
                NSApp.sendEvent(ev)
                navLog("[menu] sendEvent returned")
            }
        }
    }

    /// Posts synthetic left-clicks at real NSTableView row rects and logs the
    /// pipeline latency per click: send → tap-handler (gesture recognition),
    /// handler → selection committed to views (.onChange), applied → next
    /// runloop tick (≈ paint). Also counts row-builder evaluations per click —
    /// the breadth of the selection rebuild. Run under `xctrace record
    /// --template "Time Profiler"` (or `sample`) for the flame view;
    /// `click.apply` appears as an os_signpost interval.
    private static func clickTest(appState: AppState) {
        navTestActive = true
        appState.showWindow(source: .history)
        let logURL = URL(fileURLWithPath: "/tmp/click-test.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        func clog(_ s: String) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(Data("\(s)\n".utf8)); try? h.close()
            }
        }
        func findTable(in view: NSView) -> NSTableView? {
            if let t = view as? NSTableView { return t }
            for sub in view.subviews {
                if let t = findTable(in: sub) { return t }
            }
            return nil
        }
        func sendClick(at point: NSPoint, in win: NSWindow) {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                if let ev = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: win.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ) {
                    NSApp.sendEvent(ev)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            guard let win = NSApp.keyWindow ?? NSApp.windows.first,
                  let table = findTable(in: win.contentView!) else {
                clog("[click-test] no table")
                return
            }
            let vis = table.rows(in: table.visibleRect)
            clog("[click-test] rows=\(table.numberOfRows) visible=\(vis.location)-\(vis.location + vis.length - 1) active=\(NSApp.isActive) key=\(NSApp.keyWindow != nil)")
            // Click spread across visible rows: far-apart targets exercise the
            // worst case (old row deselect + new row select + clip updates).
            guard vis.length >= 6 else {
                clog("[click-test] not enough visible rows")
                return
            }
            let targets = [vis.location + 4, vis.location + 1, vis.location + 5,
                           vis.location + 2, vis.location + 7, vis.location + 4]
            for (i, row) in targets.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Double(i + 1)) {
                    clickT0 = ContinuousClock.now
                    clickMarks.removeAll()
                    rowEvals = 0
                    Perf.event("click.send")
                    let rect = table.rect(ofRow: row)
                    sendClick(at: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), in: win)
                    // ~1 runloop after any deferred attribute-graph commit
                    DispatchQueue.main.async { clickMark("render-tick") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let marks = clickMarks.map { "\($0.name)=\(String(format: "%.1f", $0.ms))ms" }
                            .joined(separator: " ")
                        let sel = appState.paletteSelection
                        let idx = sel.flatMap { appState.historyStore.paletteIndexBySelection[$0] }
                        clog("[click \(i)] row=\(row) sel=\(String(describing: idx)) evals=\(rowEvals) \(marks)")
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * 8) {
                clog("[click-test] done")
            }
        }
    }

    #if DEBUG
    /// Appends a line to the settings-test log from instrumented code paths
    /// (views can't reach the test's local `slog` closure).
    static func settingsLog(_ s: String) {
        guard navTestActive else { return }
        let logURL = URL(fileURLWithPath: "/tmp/settings-test.log")
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(Data("\(s)\n".utf8))
            try? h.close()
        }
    }
    #endif

    /// Opens the settings window and posts synthetic keys, logging observable
    /// state (Defaults toggles, sidebar section, window visibility) so keyboard
    /// navigation is verifiable without UI automation. Arrow movement itself is
    /// proven indirectly: a Return on the *expected* row only lands if focus
    /// actually moved.
    private static func settingsTest(appState: AppState) {
        navTestActive = true
        let logURL = URL(fileURLWithPath: "/tmp/settings-test.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        func slog(_ s: String) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile()
                h.write(Data("\(s)\n".utf8))
                try? h.close()
            }
        }
        func sendKey(_ keyCode: UInt16, _ char: String) {
            // Key events only reach the window that is key; the accessory app
            // can lose activation mid-run, so re-assert both before each event.
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            let settingsWin = NSApp.windows.first { $0.title == "Settings" }
            if let settingsWin, !settingsWin.isKeyWindow { settingsWin.makeKey() }
            let win = settingsWin?.windowNumber ?? NSApp.keyWindow?.windowNumber ?? 0
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: win, context: nil,
                characters: char, charactersIgnoringModifiers: char,
                isARepeat: false, keyCode: keyCode
            )
            let up = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: win, context: nil,
                characters: char, charactersIgnoringModifiers: char,
                isARepeat: false, keyCode: keyCode
            )
            if let down, let up {
                let fr = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                slog("sendKey \(keyCode) fr=\(fr) win=\(win)")
                NSApp.sendEvent(down)
                NSApp.sendEvent(up)
            } else {
                slog("failed to create event")
            }
        }
        func logState(_ tag: String) {
            let fr = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            slog("[settings] \(tag) fr=\(fr) active=\(NSApp.isActive) section=\(appState.settingsSection) pasteAuto=\(Defaults[.pasteAutomatically]) saveImages=\(Defaults[.saveImages]) clearOnQuit=\(Defaults[.clearOnQuit]) allowOnly=\(Defaults[.allowedAppsOnly]) searchFocus=\(appState.isSearchFocused) vis=\(WindowManager.shared.isSettingsVisible)")
        }
        // Snapshot every Defaults key the test flips and restore afterwards.
        // A leaked `clearOnQuit=true` once wiped the whole store on quit —
        // also restore on termination so a mid-test kill can't leak it.
        let savedPasteAuto = Defaults[.pasteAutomatically]
        let savedSaveImages = Defaults[.saveImages]
        let savedClearOnQuit = Defaults[.clearOnQuit]
        let savedAllowOnly = Defaults[.allowedAppsOnly]
        // Idempotent — writing the same values twice is harmless.
        func restoreDefaults() {
            Defaults[.pasteAutomatically] = savedPasteAuto
            Defaults[.saveImages] = savedSaveImages
            Defaults[.clearOnQuit] = savedClearOnQuit
            Defaults[.allowedAppsOnly] = savedAllowOnly
            slog("[settings] defaults restored")
        }
        // willTerminateNotification posts before the delegate's quit hook
        // reads `clearOnQuit`, so restoring here prevents the wipe.
        let termObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { restoreDefaults() } }
        appState.showSettings()
        let step = 0.35
        var t = 1.0
        var stepIdx = 0
        func after(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
            stepIdx += 1
            let idx = stepIdx
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                slog("step \(idx) run")
                MainActor.assumeIsolated { action() }
            }
        }
        after(t) { logState("open") }
        // General page: ↓ ×4 should land on "Paste automatically" (order:
        // launchAtLogin, popupPosition, openShortcut, searchMode, pasteAuto…)
        for i in 0..<4 {
            t += step
            after(t) { sendKey(125, "\u{F701}") }
        }
        t += step; after(t) { sendKey(36, "\r") } // Return → toggle
        t += step; after(t) { logState("general ↓×4 Return → expect pasteAuto flipped") }
        t += step; after(t) { sendKey(53, "\u{1B}") } // Esc → sidebar
        t += step; after(t) { sendKey(125, "\u{F701}") } // sidebar ↓ → storage
        t += step; after(t) { logState("sidebar ↓ → expect section=storage") }
        t += step; after(t) { sendKey(36, "\r") } // Return → enter content (saveText)
        t += step; after(t) { sendKey(125, "\u{F701}") } // ↓ → saveImages
        t += step; after(t) { sendKey(36, "\r") } // Return → toggle saveImages
        t += step; after(t) { logState("storage Return → expect saveImages flipped") }
        t += step; after(t) { sendKey(53, "\u{1B}") }
        t += step; after(t) { sendKey(125, "\u{F701}") } // storage→ignore
        t += step; after(t) { sendKey(125, "\u{F701}") } // ignore→advanced
        t += step; after(t) { logState("sidebar ↓↓ → expect section=advanced") }
        t += step; after(t) { sendKey(36, "\r") } // enter → clearOnQuit
        t += step; after(t) { logState("advanced entered") }
        t += step; after(t) { sendKey(36, "\r") } // toggle clearOnQuit
        t += step; after(t) { logState("advanced Return → expect clearOnQuit flipped") }
        // Ignore page: sidebar ↑ → ignore, enter (focus=.tabs), → switches
        // segmented tab 0→1 (spatial), ↓ lands on .field (tab 1 has no
        // .allowOnly row), Return → fieldActive → isSearchFocused.
        t += step; after(t) { sendKey(53, "\u{1B}") } // → sidebar
        t += step; after(t) { sendKey(126, "\u{F700}") } // sidebar ↑ → ignore
        t += step; after(t) { logState("sidebar ↑ → expect section=ignore") }
        t += step; after(t) { sendKey(36, "\r") } // enter → .tabs
        t += step; after(t) { sendKey(124, "\u{F703}") } // → tab 0→1
        t += step; after(t) { sendKey(125, "\u{F701}") } // ↓ → .field
        t += step; after(t) { sendKey(36, "\r") } // Return → fieldActive
        t += step; after(t) { logState("ignore → ↓ Return → expect searchFocus=true") }
        t += step; after(t) { sendKey(53, "\u{1B}") } // Esc → leave field editing
        t += step; after(t) { logState("ignore Esc → expect searchFocus=false") }
        t += step; after(t) { sendKey(53, "\u{1B}") } // Esc → sidebar
        t += step; after(t) { sendKey(53, "\u{1B}") } // Esc → close window
        t += step; after(t) { logState("final → expect vis=false") }
        t += step; after(t) {
            restoreDefaults()
            NotificationCenter.default.removeObserver(termObserver)
        }
    }

    /// Scriptable entry point for the seed/self-test menu items — processed at
    /// launch so verification doesn't need UI automation:
    ///   Clipword --seed=1500          insert N seeded rows, then keep running
    ///   Clipword --clear-seeded       delete seeded rows, then keep running
    ///   Clipword --selftest           run the perf self-test, then keep running
    ///   Clipword --debug-quit         quit after handling the other flags
    /// Composes: `--seed=1500 --selftest --debug-quit` is a headless benchmark.
    static func handleLaunchArguments(appState: AppState) {
        let args = ProcessInfo.processInfo.arguments
        let store = appState.historyStore
        var didWork = false

        for arg in args where arg.hasPrefix("--seed=") {
            if let count = Int(arg.dropFirst("--seed=".count)), count > 0 {
                seedItems(count, into: store)
                didWork = true
            }
        }
        if args.contains("--clear-seeded") {
            clearSeededItems(from: store)
            didWork = true
        }
        if args.contains("--selftest") {
            _ = runPerfSelfTest(store: store, search: appState.searchService)
            didWork = true
        }
        if args.contains("--nav-test") {
            navTest(appState: appState)
        }
        if args.contains("--click-test") {
            clickTest(appState: appState)
        }
        if args.contains("--settings-test") {
            settingsTest(appState: appState)
        }
        if args.contains("--debug-quit") {
            // Defer a beat so signposts/log flushes land before exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
        }
        if didWork {
            print("[Clipword] debug launch args handled; items=\(store.items.count)")
        }
    }
}
#endif
