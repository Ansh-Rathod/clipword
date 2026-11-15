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
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.appState?.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var modelContainer: ModelContainer!
    private(set) var historyStore: HistoryStore!
    private(set) var appState: AppState!
    private let statusBarController = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        print("[Clipword] launched pid \(ProcessInfo.processInfo.processIdentifier)")
        migrateDefaultsIfNeeded()

        let schema = Schema([
            HistoryItem.self,
            ClipboardEvent.self,
            WordFrequency.self,
            DailyStats.self,
            BookmarkItem.self,
            BookmarkFolder.self,
        ])
        let url = AppSupport.directory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: AppSupport.storeURL)
        let container = try! ModelContainer(for: schema, configurations: config)
        modelContainer = container

        let store = HistoryStore(modelContext: container.mainContext)
        let state = AppState(historyStore: store)
        historyStore = store
        appState = state

        WindowManager.shared.configure(historyStore: store, appState: state)
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
        removeRetiredItemHotkeys()
    }

    /// Pin / bookmark / delete used to be global Carbon hotkeys. Clear any
    /// leftover UserDefaults so they can't keep consuming keystrokes.
    private func removeRetiredItemHotkeys() {
        let ud = UserDefaults.standard
        for key in [
            "KeyboardShortcuts_deleteItem",
            "KeyboardShortcuts_pinItem",
            "KeyboardShortcuts_bookmarkItem",
        ] where ud.object(forKey: key) != nil {
            ud.removeObject(forKey: key)
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
                self?.appState?.toggleWindow()
            }
        }
    }
}
