import AppKit
import Defaults
import KeyboardShortcuts
import SwiftData
import SwiftUI

@main
struct ClipwordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar accessory only — UI is a floating panel from WindowManager.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var modelContainer: ModelContainer!
    private(set) var historyStore: HistoryStore!
    private(set) var analyticsEngine: AnalyticsEngine!
    private(set) var appState: AppState!
    private let statusBarController = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        print("[Clipword] launched pid \(ProcessInfo.processInfo.processIdentifier), inlineSuggestions=\(Defaults[.inlineSuggestionsEnabled]), trigger=\(Defaults[.inlineTriggerMode].rawValue)")
        migrateDefaultsIfNeeded()

        let schema = Schema([
            HistoryItem.self,
            ClipboardEvent.self,
            WordFrequency.self,
            DailyStats.self,
            BookmarkItem.self,
            BookmarkFolder.self,
        ])
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Clipword", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let storeURL = url.appendingPathComponent("Storage.sqlite")
        let config = ModelConfiguration(url: storeURL)
        let container = try! ModelContainer(for: schema, configurations: config)
        modelContainer = container

        let store = HistoryStore(modelContext: container.mainContext)
        let analytics = AnalyticsEngine(modelContext: container.mainContext)
        let state = AppState(historyStore: store, analyticsEngine: analytics)
        historyStore = store
        analyticsEngine = analytics
        appState = state

        WindowManager.shared.configure(historyStore: store, analyticsEngine: analytics, appState: state)
        statusBarController.install(appState: state)
        registerHotkeys()
    }

    /// One-time default migrations (safe to run before any SwiftData work).
    private func migrateDefaultsIfNeeded() {
        if !Defaults[.didSetDefaultIgnoredApps] {
            var apps = Defaults[.ignoredApps]
            for bundleId in Defaults.Keys.defaultIgnoredAppBundleIDs
            where !apps.contains(bundleId) {
                apps.append(bundleId)
            }
            Defaults[.ignoredApps] = apps
            Defaults[.didSetDefaultIgnoredApps] = true
        }
        removeLegacyOptionHotkeys()
    }

    /// Earlier builds shipped ⌥P/⌥B/⌥⌫ as *defaults* for pin/bookmark/delete,
    /// and KeyboardShortcuts persisted them to UserDefaults — where they were
    /// registered as global Carbon hotkeys, eating ⌥⌫ (delete-word) in every
    /// app. Drop the persisted values that exactly match those old defaults.
    private func removeLegacyOptionHotkeys() {
        guard !Defaults[.didRemoveLegacyOptionHotkeys] else { return }
        Defaults[.didRemoveLegacyOptionHotkeys] = true
        // (key, carbonKeyCode, carbonModifiers) — 2048 = Carbon optionKey
        let legacy: [(String, Int)] = [
            ("KeyboardShortcuts_deleteItem", 51),   // ⌥⌫
            ("KeyboardShortcuts_pinItem", 35),      // ⌥P
            ("KeyboardShortcuts_bookmarkItem", 11), // ⌥B
        ]
        let ud = UserDefaults.standard
        for (key, keyCode) in legacy {
            guard let raw = ud.string(forKey: key),
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["carbonKeyCode"] as? Int == keyCode,
                  obj["carbonModifiers"] as? Int == 2048 else { continue }
            ud.removeObject(forKey: key)
            print("[Hotkeys] removed legacy global hotkey \(key) (was eating an Option combo)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Defaults[.clearOnQuit] {
            historyStore?.clear(unpinnedOnly: false)
        }
    }

    private func registerHotkeys() {
        KeyboardShortcuts.onKeyUp(for: .openClipword) { [weak self] in
            Task { @MainActor in
                self?.appState?.toggleWindow(section: .clipboard)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .inlinePalette) { [weak self] in
            Task { @MainActor in
                self?.appState?.toggleSuggestionPalette()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .pinItem) { [weak self] in
            Task { @MainActor in
                guard WindowManager.shared.isVisible else { return }
                self?.appState?.togglePinSelected()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .bookmarkItem) { [weak self] in
            Task { @MainActor in
                guard WindowManager.shared.isVisible else { return }
                self?.appState?.toggleBookmarkSelected()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .deleteItem) { [weak self] in
            Task { @MainActor in
                guard WindowManager.shared.isVisible else { return }
                self?.appState?.deleteSelected()
            }
        }
    }
}
