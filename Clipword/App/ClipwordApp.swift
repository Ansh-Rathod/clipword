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

        let schema = Schema([HistoryItem.self, WordFrequency.self, DailyStats.self, BookmarkItem.self])
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
