import AppKit
import Defaults
import Foundation
import Observation
import SwiftData

public enum HistoryActionKind: Equatable {
    case copied, pasted, bookmarked, unbookmarked, pinned, unpinned
}

public struct HistoryActionEvent: Equatable {
    public let kind: HistoryActionKind
    public let itemID: UUID
    public let token: Int
}

@Observable
@MainActor
public final class HistoryStore {
    private let modelContext: ModelContext
    public private(set) var items: [HistoryItem] = []
    public var searchQuery = ""
    public var selectedItemID: UUID?
    public var pasteStack: [HistoryItem] = []
    public var activeCategory: ClipboardCategory?
    public var activeAppBundleId: String?
    public var timeFilter: HistoryTimeFilter = .any

    public private(set) var lastAction: HistoryActionEvent?
    private var actionToken = 0
    /// Bumped when in-memory list contents change so the virtualized table can
    /// refresh visible cells without a full `reloadData()`.
    public private(set) var listRevision = 0

    /// Legacy categories are backfilled once per install, off the launch path, and
    /// only for bounded payloads — decoding/classifying a multi-MB blob on the
    /// main thread at launch froze the app (hotkey never even registered).
    private static let categoryBackfillMaxBytes = 512 * 1024

    /// Rows deleted per `pruneByRetention` pass; the loop keeps going until the
    /// store is drained, so this is a batch size, not a cap.
    private static let retentionPruneBatchSize = 1000

    /// Caps the per-entry copy/paste log so a hot item can't grow forever.
    private static let maxEventsPerItem = 200

    private var retentionTimer: Timer?

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
        pruneByRetention()
        reload()
        reloadBookmarks()
        reloadFolders()
        reclassifyHTMLLinksIfNeeded()
        scheduleRetentionPrune()
    }

    public func reload() {
        let sort = sortDescriptor()
        var descriptor = FetchDescriptor<HistoryItem>(sortBy: [sort])
        if let cap = itemCap {
            descriptor.fetchLimit = cap
        }
        descriptor.propertiesToFetch = Self.listProperties
        items = (try? modelContext.fetch(descriptor)) ?? []
        scheduleCategoryBackfill()
        applyFilters()
    }

    /// Columns the palette list actually renders. Blobs and events stay faults
    /// until paste/preview touches them.
    private static let listProperties: [PartialKeyPath<HistoryItem>] = [
        \HistoryItem.id,
        \HistoryItem.title,
        \HistoryItem.plainText,
        \HistoryItem.contentTypeRaw,
        \HistoryItem.contentCategoryRaw,
        \HistoryItem.applicationBundleId,
        \HistoryItem.firstCopiedAt,
        \HistoryItem.lastCopiedAt,
        \HistoryItem.copyCount,
        \HistoryItem.isPinned,
        \HistoryItem.isBookmarked,
    ]

    /// `nil` means keep every unpinned item (Settings → History size: Unlimited).
    private var itemCap: Int? {
        let size = Defaults[.historySize]
        return HistorySize.isUnlimited(size) ? nil : size
    }

    /// Deletes every unpinned item older than the retention cutoff (see
    /// `Defaults[.historyRetention]`). Uses its own fetch so items beyond the
    /// in-memory `historySize` cap are still pruned. No-op for unlimited.
    public func pruneByRetention() {
        guard let cutoff = Defaults[.historyRetention].cutoffDate else { return }
        while true {
            var descriptor = FetchDescriptor<HistoryItem>(
                predicate: #Predicate { $0.lastCopiedAt < cutoff && !$0.isPinned }
            )
            descriptor.fetchLimit = Self.retentionPruneBatchSize
            let stale = (try? modelContext.fetch(descriptor)) ?? []
            guard !stale.isEmpty else { break }
            for item in stale {
                if selectedItemID == item.id { selectedItemID = nil }
                modelContext.delete(item)
            }
            // Bail on a failed save so we can't spin on unpersisted deletes.
            guard (try? modelContext.save()) != nil else { break }
            if stale.count < Self.retentionPruneBatchSize { break }
        }
    }

    /// Re-checks retention periodically so items that age past the cutoff while
    /// the app keeps running are still pruned without touching the paste path.
    private func scheduleRetentionPrune() {
        retentionTimer = Timer.scheduledTimer(
            withTimeInterval: 6 * 60 * 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pruneByRetention()
            }
        }
        retentionTimer?.tolerance = 10 * 60
    }

    /// Browsers copy URLs as HTML, so older items were stored as styled text.
    private func reclassifyHTMLLinksIfNeeded() {
        guard !Defaults[.didReclassifyHTMLLinks] else { return }
        var changed = false
        for item in items where item.category == .styledText || item.category == .plainText {
            guard ContentClassifier.isLinkText(item.plainText) else { continue }
            item.category = .link
            changed = true
        }
        for item in bookmarks where item.category == .styledText || item.category == .plainText {
            guard ContentClassifier.isLinkText(item.plainText) else { continue }
            item.category = .link
            changed = true
        }
        if changed {
            try? modelContext.save()
            applyFilters()
        }
        Defaults[.didReclassifyHTMLLinks] = true
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

    public var displayedItems: [HistoryItem] {
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

    public func applyFilters(using searchService: SearchService? = nil) {
        var result = sortedDisplayItems()

        if let activeCategory {
            result = result.filter { $0.category == activeCategory }
        }

        if let activeAppBundleId {
            result = result.filter { $0.applicationBundleId == activeAppBundleId }
        }

        if timeFilter.isActive {
            result = result.filter { timeFilter.contains($0.lastCopiedAt) }
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
        listRevision += 1
    }

    public func setCategoryFilter(_ category: ClipboardCategory?) {
        activeCategory = category
        applyFilters()
    }

    public func setAppFilter(_ bundleId: String?) {
        activeAppBundleId = bundleId
        applyFilters()
    }

    public func setTimeFilter(_ filter: HistoryTimeFilter) {
        timeFilter = filter
        applyFilters()
    }

    /// Bounds the jump-to-day calendar to history that actually exists.
    public var selectableDateRange: ClosedRange<Date> {
        let end = Date()
        let start = items.map(\.lastCopiedAt).min() ?? Calendar.current.date(byAdding: .month, value: -1, to: end) ?? end
        return min(start, end)...max(start, end)
    }

    public func count(for category: ClipboardCategory) -> Int {
        items.filter { $0.category == category }.count
    }

    public var availableApps: [AppFilterOption] {
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
    public func addFromPasteboard(_ pasteboard: NSPasteboard) -> HistoryItem? {
        guard let snapshot = PasteboardSnapshot.capture(from: pasteboard) else { return nil }
        guard !IgnoreRules.shouldIgnore(pasteboard: pasteboard, plainText: snapshot.plainText) else { return nil }
        guard IgnoreRules.shouldSave(snapshot: snapshot) else { return nil }

        // Encode once and reuse for both the duplicate check and the stored
        // blob — encoding a multi-MB snapshot twice per copy (base64 of the
        // whole payload) stalled the main thread.
        let data = snapshot.encode() ?? Data()

        if let existing = findDuplicate(data: data, snapshot: snapshot) {
            existing.lastCopiedAt = .now
            existing.copyCount += 1
            recordEvent(.copied, on: existing)
            try? modelContext.save()
            refreshWithoutFetch()
            return existing
        }

        let category = ContentClassifier.classify(
            snapshot: snapshot,
            pasteboardTypes: snapshot.pasteboardTypes ?? [],
            hasColorOnPasteboard: snapshot.hasColorOnPasteboard ?? false
        )
        let metrics = snapshot.plainText.map { TextAnalytics.metrics(for: $0) }
        let item = HistoryItem(
            contentData: data,
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
        recordEvent(.copied, on: item)
        try? modelContext.save()
        let removed = prune()
        // No full `reload()` here: it re-fetches every row, re-materializing
        // multi-MB blobs on the main thread (a copied 10MB text froze the app
        // for ~2s per copy). Update the in-memory list instead.
        items.removeAll { removed.contains($0) }
        items.append(item)
        refreshWithoutFetch(removing: Set(removed.map(\.id)))
        scheduleCategoryBackfill()

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

    private func findDuplicate(data: Data, snapshot: PasteboardSnapshot) -> HistoryItem? {
        // Fast path: byte-identical contentData. Stable since we encode with
        // `.sortedKeys`; covers all newly captured items.
        if let match = items.first(where: { $0.contentData == data }) {
            return match
        }
        // Legacy fallback: pre-`.sortedKeys` contentData used a nondeterministic
        // key order, so identical content had different bytes. Compare the
        // stored columns directly (no blob decode).
        return items.first { item in
            item.contentType == snapshot.contentType
                && item.plainText == snapshot.plainText
                && item.pasteboardTypes == snapshot.pasteboardTypes
                && item.imageData == snapshot.imageData
        }
    }

    /// Removes items beyond the history-size cap. No-op when size is unlimited.
    /// Returns what was deleted so callers can drop them from the in-memory list
    /// without a full re-fetch.
    @discardableResult
    public func prune() -> [HistoryItem] {
        guard let limit = itemCap else { return [] }
        let removable = items
            .filter { !$0.isPinned }
            .sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        if removable.count > limit {
            let removed = Array(removable.dropFirst(limit))
            for item in removed {
                modelContext.delete(item)
            }
            try? modelContext.save()
            return removed
        }
        return []
    }

    /// Re-sorts and re-filters the in-memory list after a write without touching
    /// the store. Unlike `reload()`, this never re-materializes blob columns, so
    /// it stays fast even when huge payloads are in the database.
    ///
    /// Pass `removing` for deletes: SwiftData's `isDeleted` is often false after
    /// `save()`, so relying on it left the row in the UI until the next launch.
    private func refreshWithoutFetch(removing ids: Set<UUID> = []) {
        items = items.filter { item in
            !ids.contains(item.id)
        }
        switch Defaults[.sortOrder] {
        case .lastCopied:
            items.sort { $0.lastCopiedAt > $1.lastCopiedAt }
        case .firstCopied:
            items.sort { $0.firstCopiedAt > $1.firstCopiedAt }
        case .copyCount:
            items.sort { $0.copyCount > $1.copyCount }
        }
        applyFilters()
    }

    public func select(_ item: HistoryItem, paste: Bool, withoutFormatting: Bool = false) {
        guard let snapshot = PasteboardSnapshot.decode(from: item.contentData) else { return }
        let strip = withoutFormatting || Defaults[.pasteWithoutFormatting]
        // Clipword writes its own marker, but unformatted writes skip it —
        // ignore the next monitor tick so we don't double-count this copy.
        Defaults[.ignoreNextEvent] = true
        PasteService.copyToClipboard(snapshot: snapshot, withoutFormatting: strip)
        item.lastCopiedAt = .now
        item.copyCount += 1
        recordEvent(.copied, on: item)
        if paste {
            item.pasteCount += 1
            item.lastPastedAt = .now
            recordEvent(.pasted, on: item)
            try? modelContext.save()
            publishAction(.pasted, itemID: item.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                PasteService.paste(item: item)
            }
        } else {
            try? modelContext.save()
            publishAction(.copied, itemID: item.id)
        }
        refreshWithoutFetch()
    }

    private func recordEvent(_ kind: ClipboardEventKind, on item: HistoryItem) {
        let event = ClipboardEvent(
            kind: kind,
            applicationBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            item: item
        )
        modelContext.insert(event)
        if !item.events.contains(where: { $0.id == event.id }) {
            item.events.append(event)
        }
        let extras = item.events
            .sorted { $0.occurredAt > $1.occurredAt }
            .dropFirst(Self.maxEventsPerItem)
        for extra in extras {
            modelContext.delete(extra)
        }
    }

    public func updateContent(_ item: HistoryItem, content: String) {
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
        refreshWithoutFetch()
    }

    public func togglePin(_ item: HistoryItem) {
        item.isPinned.toggle()
        try? modelContext.save()
        publishAction(item.isPinned ? .pinned : .unpinned, itemID: item.id)
        refreshWithoutFetch()
    }

    public func toggleBookmark(_ item: HistoryItem) {
        if let existing = findBookmark(matching: item.contentData) {
            modelContext.delete(existing)
            item.isBookmarked = false
        } else {
            modelContext.insert(BookmarkItem(from: item))
            item.isBookmarked = true
        }
        try? modelContext.save()
        reloadBookmarks()
        reloadFolders()
        publishAction(item.isBookmarked ? .bookmarked : .unbookmarked, itemID: item.id)
        refreshWithoutFetch()
    }

    /// Bookmarks `item` and puts it in `folder` (or Unfiled when nil). If it is
    /// already bookmarked, only the folder assignment changes.
    public func bookmark(_ item: HistoryItem, in folder: BookmarkFolder?) {
        if let existing = findBookmark(matching: item.contentData) {
            existing.folder = folder
            item.isBookmarked = true
        } else {
            let bookmark = BookmarkItem(from: item)
            bookmark.folder = folder
            modelContext.insert(bookmark)
            item.isBookmarked = true
        }
        try? modelContext.save()
        reloadBookmarks()
        reloadFolders()
        publishAction(.bookmarked, itemID: item.id)
        refreshWithoutFetch()
    }

    public func folder(forHistoryItem item: HistoryItem) -> BookmarkFolder? {
        findBookmark(matching: item.contentData)?.folder
    }

    public func folder(id: UUID) -> BookmarkFolder? {
        folders.first { $0.id == id }
    }

    private func publishAction(_ kind: HistoryActionKind, itemID: UUID) {
        actionToken += 1
        lastAction = HistoryActionEvent(kind: kind, itemID: itemID, token: actionToken)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    public func isContentBookmarked(_ contentData: Data) -> Bool {
        bookmarks.contains { $0.contentData == contentData }
    }

    public private(set) var bookmarks: [BookmarkItem] = []
    public private(set) var folders: [BookmarkFolder] = []
    public var selectedBookmarkID: UUID?

    public func reloadBookmarks() {
        let descriptor = FetchDescriptor<BookmarkItem>(
            sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)]
        )
        bookmarks = (try? modelContext.fetch(descriptor)) ?? []
        migrateLegacyBookmarksIfNeeded()
        listRevision += 1
    }

    public func reloadFolders() {
        let descriptor = FetchDescriptor<BookmarkFolder>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt)]
        )
        folders = (try? modelContext.fetch(descriptor)) ?? []
        listRevision += 1
    }

    @discardableResult
    public func createFolder(named name: String) -> BookmarkFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextIndex = (folders.map(\.sortIndex).max() ?? -1) + 1
        let folder = BookmarkFolder(
            name: trimmed.isEmpty ? "Untitled" : trimmed,
            sortIndex: nextIndex
        )
        modelContext.insert(folder)
        try? modelContext.save()
        reloadFolders()
        return folder
    }

    public func renameFolder(_ folder: BookmarkFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? "Untitled" : trimmed
        try? modelContext.save()
        reloadFolders()
        reloadBookmarks()
    }

    public func deleteFolder(_ folder: BookmarkFolder) {
        modelContext.delete(folder)
        try? modelContext.save()
        reloadFolders()
        reloadBookmarks()
    }

    public func moveBookmark(_ item: BookmarkItem, to folder: BookmarkFolder?) {
        item.folder = folder
        try? modelContext.save()
        reloadBookmarks()
        reloadFolders()
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

    public func selectBookmark(_ item: BookmarkItem, paste: Bool, withoutFormatting: Bool = false) {
        guard let snapshot = PasteboardSnapshot.decode(from: item.contentData) else { return }
        let strip = withoutFormatting || Defaults[.pasteWithoutFormatting]
        PasteService.copyToClipboard(snapshot: snapshot, withoutFormatting: strip)
        if paste {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                PasteService.paste()
            }
        }
    }

    public func updateBookmarkContent(_ item: BookmarkItem, content: String) {
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

    public func deleteBookmark(_ item: BookmarkItem) {
        // Clear flag on any matching history item, but do not delete history.
        if let history = items.first(where: { $0.contentData == item.contentData }) {
            history.isBookmarked = false
        }
        let index = bookmarks.firstIndex(where: { $0.id == item.id })
        let wasSelected = selectedBookmarkID == item.id
        modelContext.delete(item)
        try? modelContext.save()
        reloadBookmarks()
        reloadFolders()
        refreshWithoutFetch()
        if wasSelected {
            selectedBookmarkID = Self.adjacentID(in: bookmarks, preferring: index)
        }
    }

    public var bookmarkedItems: [HistoryItem] {
        items.filter(\.isBookmarked).sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    public func delete(_ item: HistoryItem) {
        let id = item.id
        let index = displayedItems.firstIndex(where: { $0.id == id })
        let wasSelected = selectedItemID == id
        modelContext.delete(item)
        try? modelContext.save()
        refreshWithoutFetch(removing: [id])
        if wasSelected {
            selectedItemID = Self.adjacentID(in: displayedItems, preferring: index)
        }
    }

    /// After a delete, keep a neighbor highlighted so arrow keys and another
    /// Delete have a target. Prefers the item that slid into `index`.
    private static func adjacentID<T: Identifiable>(in items: [T], preferring index: Int?) -> T.ID? {
        guard !items.isEmpty else { return nil }
        guard let index else { return items.first?.id }
        return items[min(index, items.count - 1)].id
    }

    public func clear(unpinnedOnly: Bool) {
        let removed = items.filter { unpinnedOnly ? !$0.isPinned : true }
        let ids = Set(removed.map(\.id))
        for item in removed {
            modelContext.delete(item)
        }
        try? modelContext.save()
        refreshWithoutFetch(removing: ids)
    }

    public func addToPasteStack(_ item: HistoryItem) {
        if !pasteStack.contains(where: { $0.id == item.id }) {
            pasteStack.append(item)
        }
    }

    public func popPasteStack() -> HistoryItem? {
        guard !pasteStack.isEmpty else { return nil }
        return pasteStack.removeFirst()
    }

    public var databaseSize: String {
        let url = AppSupport.storeURL
        var bytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 {
                bytes += size
            }
        }
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
