import Defaults
import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class HistoryStore {
    private let modelContext: ModelContext
    private(set) var items: [HistoryItem] = []
    var searchQuery = ""
    var selectedItemID: UUID?
    var pasteStack: [HistoryItem] = []
    var activeCategory: ClipboardCategory?
    var activeAppBundleId: String?

    private var analyticsEngine: AnalyticsEngine?

    /// Legacy categories are backfilled once per install, off the launch path, and
    /// only for bounded payloads — decoding/classifying a multi-MB blob on the
    /// main thread at launch froze the app (hotkey never even registered).
    private static let categoryBackfillMaxBytes = 512 * 1024

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        reload()
        reloadBookmarks()
    }

    func setAnalyticsEngine(_ engine: AnalyticsEngine) {
        analyticsEngine = engine
    }

    func reload() {
        pruneByRetention()
        let sort = sortDescriptor()
        var descriptor = FetchDescriptor<HistoryItem>(sortBy: [sort])
        descriptor.fetchLimit = Defaults[.historySize] + 50
        items = (try? modelContext.fetch(descriptor)) ?? []
        scheduleCategoryBackfill()
        applyFilters()
    }

    /// Deletes every unpinned item older than the retention cutoff (see
    /// `Defaults[.historyRetention]`). Uses its own fetch so items beyond the
    /// in-memory `historySize` cap are still pruned. No-op for unlimited.
    func pruneByRetention() {
        guard let cutoff = Defaults[.historyRetention].cutoffDate else { return }
        var descriptor = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.lastCopiedAt < cutoff && !$0.isPinned }
        )
        descriptor.fetchLimit = 2000
        let stale = (try? modelContext.fetch(descriptor)) ?? []
        guard !stale.isEmpty else { return }
        for item in stale {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func scheduleCategoryBackfill() {
        guard !Defaults[.didBackfillCategories] else { return }
        Task { @MainActor [weak self] in
            self?.backfillCategoriesIfNeeded()
        }
    }

    private func backfillCategoriesIfNeeded() {
        guard !Defaults[.didBackfillCategories] else { return }
        var changed = false
        for item in items {
            guard item.contentData.count <= Self.categoryBackfillMaxBytes else { continue }
            guard let snapshot = PasteboardSnapshot.decode(from: item.contentData) else { continue }
            let classified = ContentClassifier.classify(
                snapshot: snapshot,
                pasteboardTypes: item.pasteboardTypes ?? [],
                hasColorOnPasteboard: false
            )
            if item.category != classified {
                item.category = classified
                changed = true
            }
        }
        if changed { try? modelContext.save() }
        Defaults[.didBackfillCategories] = true
    }

    private func sortDescriptor() -> SortDescriptor<HistoryItem> {
        switch Defaults[.sortOrder] {
        case .lastCopied:
            return SortDescriptor(\.lastCopiedAt, order: .reverse)
        case .firstCopied:
            return SortDescriptor(\.firstCopiedAt, order: .reverse)
        case .copyCount:
            return SortDescriptor(\.copyCount, order: .reverse)
        }
    }

    private var filteredItems: [HistoryItem] = []

    var displayedItems: [HistoryItem] {
        filteredItems
    }

    private func sortedDisplayItems() -> [HistoryItem] {
        let pinned = items.filter(\.isPinned)
        let unpinned = items.filter { !$0.isPinned }
        switch Defaults[.pinPosition] {
        case .top:
            return pinned + unpinned
        case .bottom:
            return unpinned + pinned
        }
    }

    func applyFilters(using searchService: SearchService? = nil) {
        var result = sortedDisplayItems()

        if let activeCategory {
            result = result.filter { $0.category == activeCategory }
        }

        if let activeAppBundleId {
            result = result.filter { $0.applicationBundleId == activeAppBundleId }
        }

        if !searchQuery.isEmpty {
            if let searchService {
                result = searchService.search(query: searchQuery, in: result)
            } else {
                result = result.filter {
                    ($0.plainText?.localizedCaseInsensitiveContains(searchQuery) ?? false)
                        || ($0.title?.localizedCaseInsensitiveContains(searchQuery) ?? false)
                }
            }
        }

        filteredItems = result
    }

    func setCategoryFilter(_ category: ClipboardCategory?) {
        activeCategory = category
        applyFilters()
    }

    func setAppFilter(_ bundleId: String?) {
        activeAppBundleId = bundleId
        applyFilters()
    }

    func count(for category: ClipboardCategory) -> Int {
        items.filter { $0.category == category }.count
    }

    var availableApps: [AppFilterOption] {
        var counts: [String: Int] = [:]
        for item in items {
            let key = item.applicationBundleId ?? "unknown"
            counts[key, default: 0] += 1
        }
        return counts.map { bundleId, count in
            AppFilterOption(bundleId: bundleId, name: appName(for: bundleId), count: count)
        }
        .sorted { $0.count > $1.count }
    }

    private func appName(for bundleId: String) -> String {
        if bundleId == "unknown" { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId
    }

    @discardableResult
    func addFromPasteboard(_ pasteboard: NSPasteboard) -> HistoryItem? {
        guard let snapshot = PasteboardSnapshot.capture(from: pasteboard) else { return nil }
        guard !IgnoreRules.shouldIgnore(pasteboard: pasteboard, plainText: snapshot.plainText) else { return nil }
        guard IgnoreRules.shouldSave(snapshot: snapshot) else { return nil }

        if let existing = findDuplicate(snapshot: snapshot) {
            existing.lastCopiedAt = .now
            existing.copyCount += 1
            try? modelContext.save()
            reload()
            return existing
        }

        let category = ContentClassifier.classify(
            snapshot: snapshot,
            pasteboardTypes: snapshot.pasteboardTypes ?? [],
            hasColorOnPasteboard: snapshot.hasColorOnPasteboard ?? false
        )
        let metrics = snapshot.plainText.map { TextAnalytics.metrics(for: $0) }
        let item = HistoryItem(
            contentData: snapshot.encode() ?? Data(),
            plainText: snapshot.plainText,
            contentType: snapshot.contentType,
            contentCategory: category,
            pasteboardTypes: snapshot.pasteboardTypes,
            applicationBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            wordCount: metrics?.wordCount ?? 0,
            lineCount: metrics?.lineCount ?? 0,
            charCount: metrics?.charCount ?? 0,
            readingTimeSeconds: metrics?.readingTimeSeconds ?? 0,
            imageData: snapshot.imageData,
            title: snapshot.plainText.map(boundedTitle)
        )
        modelContext.insert(item)
        try? modelContext.save()
        prune()
        analyticsEngine?.recordCopy(item: item)
        reload()

        if snapshot.contentType == .image, let imageData = snapshot.imageData {
            Task {
                if let text = await OCRService.recognizeText(from: imageData) {
                    item.title = text
                    item.plainText = text
                    let metrics = TextAnalytics.metrics(for: text)
                    item.wordCount = metrics.wordCount
                    item.lineCount = metrics.lineCount
                    item.charCount = metrics.charCount
                    item.readingTimeSeconds = metrics.readingTimeSeconds
                    try? modelContext.save()
                    analyticsEngine?.recordCopy(item: item)
                    reload()
                }
            }
        }

        return item
    }

    /// First line of text, capped so huge payloads can't produce giant titles
    /// (a huge title would stall Text layout in the list).
    private func boundedTitle(_ text: String) -> String {
        let head = text.prefix(200)
        if let newline = head.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(head[..<newline])
        }
        return String(head)
    }

    private func findDuplicate(snapshot: PasteboardSnapshot) -> HistoryItem? {
        guard let data = snapshot.encode() else { return nil }
        return items.first { $0.contentData == data }
    }

    func prune() {
        let limit = Defaults[.historySize]
        let removable = items
            .filter { !$0.isPinned }
            .sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        if removable.count > limit {
            for item in removable.dropFirst(limit) {
                modelContext.delete(item)
            }
            try? modelContext.save()
        }
    }

    func select(_ item: HistoryItem, paste: Bool, withoutFormatting: Bool = false) {
        guard let snapshot = PasteboardSnapshot.decode(from: item.contentData) else { return }
        let strip = withoutFormatting || Defaults[.pasteWithoutFormatting]
        PasteService.copyToClipboard(snapshot: snapshot, withoutFormatting: strip)
        let shouldPaste = paste || Defaults[.pasteAutomatically]
        if shouldPaste {
            item.pasteCount += 1
            item.lastPastedAt = .now
            try? modelContext.save()
            analyticsEngine?.recordPaste(item: item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                PasteService.paste()
            }
        } else {
            try? modelContext.save()
        }
        reload()
    }

    func updateContent(_ item: HistoryItem, content: String) {
        if var snapshot = PasteboardSnapshot.decode(from: item.contentData) {
            snapshot.plainText = content
            item.contentData = snapshot.encode() ?? item.contentData
        }
        item.plainText = content
        item.title = boundedTitle(content)
        item.category = ContentClassifier.classify(item: item)
        let metrics = TextAnalytics.metrics(for: content)
        item.wordCount = metrics.wordCount
        item.lineCount = metrics.lineCount
        item.charCount = metrics.charCount
        item.readingTimeSeconds = metrics.readingTimeSeconds
        try? modelContext.save()
        reload()
    }

    func togglePin(_ item: HistoryItem) {
        item.isPinned.toggle()
        try? modelContext.save()
        reload()
    }

    func toggleBookmark(_ item: HistoryItem) {
        if let existing = findBookmark(matching: item.contentData) {
            modelContext.delete(existing)
            item.isBookmarked = false
        } else {
            modelContext.insert(BookmarkItem(from: item))
            item.isBookmarked = true
        }
        try? modelContext.save()
        reloadBookmarks()
        reload()
    }

    func isContentBookmarked(_ contentData: Data) -> Bool {
        bookmarks.contains { $0.contentData == contentData }
    }

    private(set) var bookmarks: [BookmarkItem] = []
    var selectedBookmarkID: UUID?

    func reloadBookmarks() {
        let descriptor = FetchDescriptor<BookmarkItem>(
            sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)]
        )
        bookmarks = (try? modelContext.fetch(descriptor)) ?? []
        migrateLegacyBookmarksIfNeeded()
    }

    private var didMigrateBookmarks = false

    private func migrateLegacyBookmarksIfNeeded() {
        guard !didMigrateBookmarks else { return }
        didMigrateBookmarks = true
        var added = false
        for item in items where item.isBookmarked {
            if findBookmark(matching: item.contentData) == nil {
                modelContext.insert(BookmarkItem(from: item))
                added = true
            }
        }
        if added {
            try? modelContext.save()
            let descriptor = FetchDescriptor<BookmarkItem>(
                sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)]
            )
            bookmarks = (try? modelContext.fetch(descriptor)) ?? []
        }
    }

    private func findBookmark(matching contentData: Data) -> BookmarkItem? {
        bookmarks.first { $0.contentData == contentData }
            ?? {
                var descriptor = FetchDescriptor<BookmarkItem>()
                let all = (try? modelContext.fetch(descriptor)) ?? []
                return all.first { $0.contentData == contentData }
            }()
    }

    func selectBookmark(_ item: BookmarkItem, paste: Bool, withoutFormatting: Bool = false) {
        guard let snapshot = PasteboardSnapshot.decode(from: item.contentData) else { return }
        let strip = withoutFormatting || Defaults[.pasteWithoutFormatting]
        PasteService.copyToClipboard(snapshot: snapshot, withoutFormatting: strip)
        if paste || Defaults[.pasteAutomatically] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                PasteService.paste()
            }
        }
    }

    func updateBookmarkContent(_ item: BookmarkItem, content: String) {
        if var snapshot = PasteboardSnapshot.decode(from: item.contentData) {
            snapshot.plainText = content
            item.contentData = snapshot.encode() ?? item.contentData
        }
        item.plainText = content
        item.title = boundedTitle(content)
        let metrics = TextAnalytics.metrics(for: content)
        item.wordCount = metrics.wordCount
        item.lineCount = metrics.lineCount
        item.charCount = metrics.charCount
        item.readingTimeSeconds = metrics.readingTimeSeconds
        try? modelContext.save()
        reloadBookmarks()
    }

    func deleteBookmark(_ item: BookmarkItem) {
        // Clear flag on any matching history item, but do not delete history.
        if let history = items.first(where: { $0.contentData == item.contentData }) {
            history.isBookmarked = false
        }
        modelContext.delete(item)
        try? modelContext.save()
        if selectedBookmarkID == item.id { selectedBookmarkID = nil }
        reloadBookmarks()
        reload()
    }

    var bookmarkedItems: [HistoryItem] {
        items.filter(\.isBookmarked).sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    func delete(_ item: HistoryItem) {
        modelContext.delete(item)
        try? modelContext.save()
        if selectedItemID == item.id { selectedItemID = nil }
        reload()
    }

    func clear(unpinnedOnly: Bool) {
        for item in items where unpinnedOnly ? !item.isPinned : true {
            modelContext.delete(item)
        }
        try? modelContext.save()
        reload()
    }

    func addToPasteStack(_ item: HistoryItem) {
        if !pasteStack.contains(where: { $0.id == item.id }) {
            pasteStack.append(item)
        }
    }

    func popPasteStack() -> HistoryItem? {
        guard !pasteStack.isEmpty else { return nil }
        return pasteStack.removeFirst()
    }

    var databaseSize: String {
        let url = modelContext.container.configurations.first?.url
        guard let url, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

import AppKit
