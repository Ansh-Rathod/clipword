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

@Observable
@MainActor
final class AppState {
    let historyStore: HistoryStore
    let analyticsEngine: AnalyticsEngine
    let searchService = SearchService()
    let clipboardMonitor = ClipboardMonitor()
    let typingMonitor = TypingMonitor()

    var mainSection: MainSection = .clipboard
    var cycleIndex = 0
    var isCycling = false
    var isSearchFocused = false
    var searchFocusToken = 0
    /// Bumped every time the main window is shown (reset sidebar / list selection).
    var windowPresentationToken = 0
    private var pasteStackMonitor: Any?

    init(historyStore: HistoryStore, analyticsEngine: AnalyticsEngine) {
        self.historyStore = historyStore
        self.analyticsEngine = analyticsEngine
        historyStore.setAnalyticsEngine(analyticsEngine)
        typingMonitor.configure(analyticsEngine: analyticsEngine)
        typingMonitor.syncWithPreference()

        clipboardMonitor.onNewCopy = { [weak self] pasteboard in
            self?.historyStore.addFromPasteboard(pasteboard)
        }
        clipboardMonitor.start()
        registerPasteStackMonitor()
    }

    func toggleWindow(section: MainSection = .clipboard) {
        WindowManager.shared.toggleMainWindow(section: section)
    }

    func showWindow(section: MainSection = .clipboard) {
        WindowManager.shared.showMainWindow(section: section)
    }

    func hideWindow() {
        WindowManager.shared.hideMainWindow()
    }

    func requestSearchFocus() {
        isSearchFocused = true
        searchFocusToken += 1
    }

    func selectSection(_ section: MainSection) {
        mainSection = section
    }

    func cycleSection(_ delta: Int) {
        let all = MainSection.allCases
        guard let index = all.firstIndex(of: mainSection) else { return }
        let next = index + delta
        guard all.indices.contains(next) else { return }
        mainSection = all[next]
    }

    func togglePinSelected() {
        switch mainSection {
        case .clipboard:
            guard let item = selectedHistoryItem() else { return }
            historyStore.togglePin(item)
        default:
            break
        }
    }

    func toggleBookmarkSelected() {
        switch mainSection {
        case .clipboard:
            guard let item = selectedHistoryItem() else { return }
            historyStore.toggleBookmark(item)
        case .bookmarks:
            guard let item = selectedBookmarkItem() else { return }
            historyStore.deleteBookmark(item)
        default:
            break
        }
    }

    func deleteSelected() {
        switch mainSection {
        case .clipboard:
            guard let item = selectedHistoryItem() else { return }
            historyStore.delete(item)
        case .bookmarks:
            guard let item = selectedBookmarkItem() else { return }
            historyStore.deleteBookmark(item)
        default:
            break
        }
    }

    func copySelected(paste: Bool, withoutFormatting: Bool = false) {
        switch mainSection {
        case .clipboard:
            guard let item = selectedHistoryItem() else { return }
            historyStore.select(item, paste: paste, withoutFormatting: withoutFormatting)
            if paste { hideWindow() }
        case .bookmarks:
            guard let item = selectedBookmarkItem() else { return }
            historyStore.selectBookmark(item, paste: paste, withoutFormatting: withoutFormatting)
            if paste { hideWindow() }
        default:
            break
        }
    }

    private func selectedHistoryItem() -> HistoryItem? {
        guard let id = historyStore.selectedItemID else { return nil }
        return historyStore.displayedItems.first { $0.id == id }
    }

    private func selectedBookmarkItem() -> BookmarkItem? {
        guard let id = historyStore.selectedBookmarkID else { return nil }
        return historyStore.bookmarks.first { $0.id == id }
    }

    func cycleNext() {
        let items = historyStore.displayedItems
        guard !items.isEmpty else { return }
        cycleIndex = (cycleIndex + 1) % items.count
        historyStore.selectedItemID = items[cycleIndex].id
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
        }
        showWindow(section: .clipboard)
    }

    func endCycleMode() {
        guard isCycling else { return }
        isCycling = false
        pasteCycledItem()
    }

    private func registerPasteStackMonitor() {
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
