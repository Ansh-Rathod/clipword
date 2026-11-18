import AppKit
import Defaults
import Foundation
import Observation

@Observable
@MainActor
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    var onNewCopy: ((NSPasteboard) -> Void)?

    func start() {
        stop()
        let interval = Defaults[.clipboardCheckInterval]
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        onNewCopy?(pasteboard)
    }
}

enum PaletteSource: String, CaseIterable, Identifiable, Hashable {
    case history, bookmarks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: "Recent"
        case .bookmarks: "Bookmarks"
        }
    }
}

enum PaletteSelection: Hashable {
    case history(UUID)
    case bookmark(UUID)
    case folder(UUID)
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, storage, ignore, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .storage: "Storage"
        case .ignore: "Ignore"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gear"
        case .storage: "internaldrive"
        case .ignore: "eye.slash"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    static let settings: [SettingsSection] = [.general, .storage, .ignore, .advanced]
}

@Observable
@MainActor
final class AppState {
    let historyStore: HistoryStore
    let searchService = SearchService()
    let clipboardMonitor = ClipboardMonitor()

    var paletteSource: PaletteSource = .history
    var paletteSelection: PaletteSelection? {
        // didSet runs post-commit (the new value), synchronously — unlike
        // withObservationTracking's willSet-phase onChange — so every write
        // site gets an instant, correct row-state update + table highlight.
        didSet { PaletteSelectionRegistry.shared.apply(selection: paletteSelection) }
    }
    /// Folders the user collapsed in Bookmarks. Kept across hide/show.
    var collapsedFolderIDs: Set<UUID> = []
    /// Pixel offsets for the palette list and preview panes. Survives focus loss.
    let scrollStore = PaletteScrollStore()
    var settingsSection: SettingsSection = .general
    var cycleIndex = 0
    var isCycling = false
    var isSearchFocused = false
    var searchFocusToken = 0
    /// Bumped every time the main window is shown so search can take keyboard
    /// focus again without wiping scroll, source, or selection.
    var windowPresentationToken = 0
    private var pasteStackMonitor: Any?

    init(historyStore: HistoryStore) {
        self.historyStore = historyStore

        clipboardMonitor.onNewCopy = { [weak self] pasteboard in
            self?.historyStore.addFromPasteboard(pasteboard)
        }
        clipboardMonitor.start()
        registerPasteStackMonitor()
    }

    func toggleWindow(source: PaletteSource? = nil, fromStatusItem: Bool = false) {
        WindowManager.shared.toggleMainWindow(source: source, fromStatusItem: fromStatusItem)
    }

    func showWindow(source: PaletteSource? = nil, fromStatusItem: Bool = false) {
        WindowManager.shared.showMainWindow(source: source, fromStatusItem: fromStatusItem)
    }

    func hideWindow() {
        WindowManager.shared.hideMainWindow()
    }

    func showSettings(section: SettingsSection = .general) {
        WindowManager.shared.showSettingsWindow(section: section)
    }

    func closeSettings() {
        WindowManager.shared.handleSettingsClosed()
    }

    func requestSearchFocus() {
        isSearchFocused = true
        searchFocusToken += 1
    }

    func togglePinSelected() {
        guard case .history(let id) = paletteSelection,
              let item = historyStore.displayedItems.first(where: { $0.id == id }) else { return }
        historyStore.togglePin(item)
    }

    func toggleBookmarkSelected() {
        switch paletteSelection {
        case .history(let id):
            guard let item = historyStore.displayedItems.first(where: { $0.id == id }) else { return }
            historyStore.toggleBookmark(item)
        case .bookmark(let id):
            guard let item = historyStore.bookmarks.first(where: { $0.id == id }) else { return }
            historyStore.deleteBookmark(item)
        case .folder, nil:
            break
        }
    }

    func deleteSelected() {
        switch paletteSelection {
        case .history(let id):
            guard let item = historyStore.displayedItems.first(where: { $0.id == id }) else { return }
            historyStore.delete(item)
        case .bookmark(let id):
            guard let item = historyStore.bookmarks.first(where: { $0.id == id }) else { return }
            historyStore.deleteBookmark(item)
        case .folder, nil:
            break
        }
    }

    func copySelected(paste: Bool, withoutFormatting: Bool = false) {
        switch paletteSelection {
        case .history(let id):
            guard let item = historyStore.displayedItems.first(where: { $0.id == id }) else { return }
            historyStore.select(item, paste: paste, withoutFormatting: withoutFormatting)
            if paste { hideWindow() }
        case .bookmark(let id):
            guard let item = historyStore.bookmarks.first(where: { $0.id == id }) else { return }
            historyStore.selectBookmark(item, paste: paste, withoutFormatting: withoutFormatting)
            if paste { hideWindow() }
        case .folder, nil:
            break
        }
    }

    func cycleNext() {
        let items = historyStore.displayedItems
        guard !items.isEmpty else { return }
        cycleIndex = (cycleIndex + 1) % items.count
        let item = items[cycleIndex]
        paletteSelection = .history(item.id)
        historyStore.selectedItemID = item.id
    }

    func pasteCycledItem() {
        let items = historyStore.displayedItems
        guard !items.isEmpty else { return }
        let item = items[cycleIndex % items.count]
        historyStore.select(item, paste: true)
        hideWindow()
    }

    func handlePasteStack() {
        if let item = historyStore.popPasteStack() {
            historyStore.select(item, paste: true)
        }
    }

    func startCycleMode() {
        isCycling = true
        cycleIndex = 0
        if let first = historyStore.displayedItems.first {
            historyStore.selectedItemID = first.id
            paletteSelection = .history(first.id)
        }
        showWindow(source: .history)
    }

    func endCycleMode() {
        guard isCycling else { return }
        isCycling = false
        pasteCycledItem()
    }

    private func registerPasteStackMonitor() {
        // A global keyDown monitor asks TCC for Device Access. Installing it
        // on every launch re-prompts even when the permission is already on.
        guard PasteService.isAccessibilityTrusted else { return }
        pasteStackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let self else { return }
            Task { @MainActor in
                if !self.historyStore.pasteStack.isEmpty {
                    self.handlePasteStack()
                }
            }
        }
    }
}
