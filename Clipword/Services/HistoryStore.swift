import AppKit
import Defaults
import Foundation
import Observation
import SwiftData

enum HistoryActionKind: Equatable {
    case copied, pasted, bookmarked, unbookmarked, pinned, unpinned
}

struct HistoryActionEvent: Equatable {
    let kind: HistoryActionKind
    let itemID: UUID
    let token: Int
}

@Observable
@MainActor
final class HistoryStore {
    let modelContext: ModelContext
    private(set) var items: [HistoryItem] = []
    var searchQuery = ""
    var selectedItemID: UUID?
    var pasteStack: [HistoryItem] = []
    var activeCategory: ClipboardCategory?
    var activeAppBundleId: String?
    var timeFilter: HistoryTimeFilter = .any

    // MARK: - Derived palette data
    //
    // Everything the palette needs per frame, rebuilt once per data change in
    // `rebuildDerivedData` (called from `applyFilters`). The views used to
    // recompute day-sections, flattened rows and index scans on every SwiftUI
    // body evaluation — ~5 O(n) passes with per-item `Calendar.startOfDay` and
    // UUID-string interpolation per arrow keypress at 1000+ entries.
    private(set) var paletteDaySections: [PaletteDaySection] = []
    private(set) var paletteRows: [PaletteRow] = []
    private(set) var paletteBookmarkSections: [PaletteBookmarkSection] = []
    private(set) var paletteIndexBySelection: [PaletteSelection: Int] = [:]
    private(set) var paletteTableRowBySelection: [PaletteSelection: Int] = [:]
    private(set) var itemsByID: [UUID: HistoryItem] = [:]
    private(set) var bookmarkItemsByID: [UUID: BookmarkItem] = [:]
    /// contentHash → bookmark for O(1) bookmark lookup. The previous
    /// `findBookmark` fell back to a full `FetchDescriptor` query per call —
    /// the palette's per-row context menu made that a SQLite fetch × every row
    /// × every body evaluation.
    private var bookmarkItemsByHash: [String: BookmarkItem] = [:]
    /// Bookmarks without a contentHash (legacy rows) — matched by blob compare.
    private var legacyBookmarkItems: [BookmarkItem] = []
    private(set) var foldersByID: [UUID: BookmarkFolder] = [:]
    private(set) var categoryCounts: [ClipboardCategory: Int] = [:]
    private(set) var appOptions: [AppFilterOption] = []
    private(set) var earliestLastCopiedAt: Date?
    /// Bumped whenever the visible row set changes; drives the list's
    /// `.animation`/`onChange` without rebuilding a 1000-string ID array per
    /// body evaluation.
    private(set) var paletteVersion = 0

    /// `startOfDay` per item, keyed to the `lastCopiedAt` it was computed from.
    /// Calendar calls dominated section building; entries only recompute when
    /// an item's timestamp actually changes.
    private var dayStartByID: [UUID: (stamp: Date, day: Date)] = [:]
    private var appNameCache: [String: String] = [:]
    private var lastPaletteRowIDs: [String] = []
    /// contentHash → item. O(1) duplicate lookup; only hash-bearing rows live
    /// here — legacy rows are skipped via `hasUnhashedItems`.
    private var itemsByHash: [String: HistoryItem] = [:]
    /// Rows without a `contentHash` — duplicate checks scan this small list
    /// instead of the whole history once hashes are backfilled.
    private var legacyItems: [HistoryItem] = []
    private var appCountByBundle: [String: Int] = [:]
    private var lastSearchService: SearchService?

    private(set) var lastAction: HistoryActionEvent?
    private var actionToken = 0

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

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        Perf.measure("store.init") {
            pruneByRetention()
            reload()
            reloadBookmarks()
            reloadFolders()
            reclassifyHTMLLinksIfNeeded()
            scheduleRetentionPrune()
            scheduleContentHashBackfill()
        }
    }

    func reload() {
        Perf.measure("store.reload") {
            let sort = sortDescriptor()
            var descriptor = FetchDescriptor<HistoryItem>(sortBy: [sort])
            if let cap = itemCap {
                descriptor.fetchLimit = cap
            }
            items = (try? modelContext.fetch(descriptor)) ?? []
            stableSortItems()
            scheduleCategoryBackfill()
            applyFilters()
        }
    }

    /// Total-order sort for `items`. The primary key alone ties on
    /// same-timestamp rows (bulk inserts, rapid copies), and Swift's sort is
    /// unstable — each rebuild could permute tied rows, shifting palette
    /// indices under the selection mid-navigation. uuidString breaks ties
    /// deterministically so row order is canonical for a given data set.
    private func stableSortItems() {
        switch Defaults[.sortOrder] {
        case .lastCopied:
            items.sort { ($0.lastCopiedAt, $0.id.uuidString) > ($1.lastCopiedAt, $1.id.uuidString) }
        case .firstCopied:
            items.sort { ($0.firstCopiedAt, $0.id.uuidString) > ($1.firstCopiedAt, $1.id.uuidString) }
        case .copyCount:
            items.sort { ($0.copyCount, $0.id.uuidString) > ($1.copyCount, $1.id.uuidString) }
        }
    }

    /// `nil` means keep every unpinned item (Settings → History size: Unlimited).
    private var itemCap: Int? {
        let size = Defaults[.historySize]
        return HistorySize.isUnlimited(size) ? nil : size
    }

    /// Deletes every unpinned item older than the retention cutoff (see
    /// `Defaults[.historyRetention]`). Uses its own fetch so items beyond the
    /// in-memory `historySize` cap are still pruned. No-op for unlimited.
    func pruneByRetention() {
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

    /// Items written before `contentHash` existed get hashed a chunk at a time
    /// so one upgrade doesn't decode every blob on the launch path. New copies
    /// are hashed at insert, so this only drains legacy rows.
    private func scheduleContentHashBackfill() {
        guard !Defaults[.didBackfillContentHashes] else { return }
        Task { @MainActor [weak self] in
            self?.backfillContentHashes()
        }
    }

    private static let hashBackfillBatch = 64

    private func backfillContentHashes() {
        guard !Defaults[.didBackfillContentHashes] else { return }
        var processed = 0
        for item in items where item.contentHash == nil {
            item.contentHash = ContentHasher.hex(item.contentData)
            processed += 1
            if processed >= Self.hashBackfillBatch {
                try? modelContext.save()
                scheduleContentHashBackfill()
                return
            }
        }
        for bookmark in bookmarks where bookmark.contentHash == nil {
            bookmark.contentHash = ContentHasher.hex(bookmark.contentData)
            processed += 1
            if processed >= Self.hashBackfillBatch {
                try? modelContext.save()
                scheduleContentHashBackfill()
                return
            }
        }
        try? modelContext.save()
        Defaults[.didBackfillContentHashes] = true
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
        Perf.measure("store.applyFilters") {
            if let searchService { lastSearchService = searchService }
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
            rebuildDerivedData()
        }
    }

    /// Rebuilds every derived structure the palette reads per frame, in one
    /// pass. Runs on data change only — keypresses and view evaluations read
    /// the results for free.
    private func rebuildDerivedData() {
        Perf.measure("store.rebuildDerivedData") {
            let calendar = Calendar.current

            itemsByID.removeAll(keepingCapacity: true)
            categoryCounts.removeAll(keepingCapacity: true)
            var appCounts: [String: Int] = [:]
            var earliest: Date?
            var dayStarts: [UUID: Date] = [:]
            dayStarts.reserveCapacity(items.count)
            itemsByID.reserveCapacity(items.count)
            itemsByHash.removeAll(keepingCapacity: true)
            var unhashed: [HistoryItem] = []
            for item in items {
                itemsByID[item.id] = item
                if let h = item.contentHash { itemsByHash[h] = item } else { unhashed.append(item) }
                categoryCounts[item.category, default: 0] += 1
                appCounts[item.applicationBundleId ?? "unknown", default: 0] += 1
                if earliest == nil || item.lastCopiedAt < earliest! { earliest = item.lastCopiedAt }
                if let cached = dayStartByID[item.id], cached.stamp == item.lastCopiedAt {
                    dayStarts[item.id] = cached.day
                } else {
                    let day = calendar.startOfDay(for: item.lastCopiedAt)
                    dayStarts[item.id] = day
                    dayStartByID[item.id] = (item.lastCopiedAt, day)
                }
            }
            legacyItems = unhashed
            earliestLastCopiedAt = earliest
            appCountByBundle = appCounts
            rebuildAppOptions()

            rebuildBookmarkSections()
            rebuildHistorySections(dayStarts: dayStarts, calendar: calendar)
            #if DEBUG
            DebugTools.benchMark("derived")
            #endif

            bookmarkItemsByID = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id, $0) })
            foldersByID = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            bookmarkItemsByHash = Dictionary(
                bookmarks.compactMap { bookmark in
                    bookmark.contentHash.map { ($0, bookmark) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            legacyBookmarkItems = bookmarks.filter { $0.contentHash == nil }
        }
    }

    private func rebuildHistorySections(dayStarts: [UUID: Date], calendar: Calendar) {
        let extractPins = !timeFilter.isActive
        var pinned: [HistoryItem] = []
        var buckets: [Date: [HistoryItem]] = [:]

        for item in filteredItems {
            if extractPins && item.isPinned {
                pinned.append(item)
                continue
            }
            let day = dayStarts[item.id] ?? calendar.startOfDay(for: item.lastCopiedAt)
            buckets[day, default: []].append(item)
        }

        var sections: [PaletteDaySection] = []

        if extractPins, Defaults[.pinPosition] == .top, !pinned.isEmpty {
            sections.append(PaletteDaySection(id: "pinned", title: "Pinned", items: pinned))
        }
        for day in buckets.keys.sorted(by: >) {
            sections.append(
                PaletteDaySection(
                    id: "day-\(Int(day.timeIntervalSince1970))",
                    title: HistoryTimeFilter.sectionTitle(for: day, calendar: calendar),
                    items: buckets[day] ?? []
                )
            )
        }
        if extractPins, Defaults[.pinPosition] == .bottom, !pinned.isEmpty {
            sections.append(PaletteDaySection(id: "pinned", title: "Pinned", items: pinned))
        }

        paletteDaySections = sections
        rebuildRowsAndIndexMaps()
        updatePaletteRowIDs()
    }

    /// Rebuilds `paletteRows` + both selection→index maps from
    /// `paletteDaySections`. One O(sections+rows) pass — used by the full
    /// rebuild and by the incremental copy path, so both produce identical
    /// structures.
    private func rebuildRowsAndIndexMaps() {
        var rows: [PaletteRow] = []
        var indexBySelection: [PaletteSelection: Int] = [:]
        var tableRowBySelection: [PaletteSelection: Int] = [:]
        rows.reserveCapacity(filteredItems.count)
        indexBySelection.reserveCapacity(filteredItems.count)
        tableRowBySelection.reserveCapacity(filteredItems.count)
        var tableRow = 0
        for section in paletteDaySections {
            tableRow += 1 // the section header is one table row
            for item in section.items {
                indexBySelection[.history(item.id)] = rows.count
                tableRowBySelection[.history(item.id)] = tableRow
                rows.append(.history(item))
                tableRow += 1
            }
        }
        paletteRows = rows
        paletteIndexBySelection = indexBySelection
        paletteTableRowBySelection = tableRowBySelection
    }

    /// Recomputes `lastPaletteRowIDs`/`paletteVersion` from current rows.
    private func updatePaletteRowIDs() {
        var ids = paletteRows.map(\.id)
        for section in paletteBookmarkSections {
            if let folder = section.folder { ids.append("f-\(folder.id.uuidString)") }
            for item in section.items { ids.append("b-\(item.id.uuidString)") }
        }
        if ids != lastPaletteRowIDs {
            lastPaletteRowIDs = ids
            paletteVersion += 1
        }
    }

    private func rebuildBookmarkSections() {
        var result = bookmarks
        if let activeCategory {
            result = result.filter { $0.category == activeCategory }
        }
        if let activeAppBundleId {
            result = result.filter { $0.applicationBundleId == activeAppBundleId }
        }
        if !searchQuery.isEmpty {
            if let service = lastSearchService {
                result = service.searchBookmarks(query: searchQuery, in: result)
            } else {
                result = result.filter { Self.bookmarkMatches($0, query: searchQuery) }
            }
        }

        let isFiltering = activeCategory != nil || activeAppBundleId != nil || !searchQuery.isEmpty
        if folders.isEmpty {
            paletteBookmarkSections = result.isEmpty
                ? []
                : [PaletteBookmarkSection(id: "bookmarks", title: "Bookmarks", folder: nil, items: result)]
            return
        }

        var sections: [PaletteBookmarkSection] = []
        for folder in folders {
            let folderItems = result.filter { $0.folder?.id == folder.id }
            if folderItems.isEmpty && isFiltering { continue }
            sections.append(
                PaletteBookmarkSection(
                    id: folder.id.uuidString,
                    title: folder.name,
                    folder: folder,
                    items: folderItems
                )
            )
        }
        let unfiled = result.filter { $0.folder == nil }
        if !unfiled.isEmpty {
            sections.append(PaletteBookmarkSection(id: "unfiled", title: "Unfiled", folder: nil, items: unfiled))
        }
        paletteBookmarkSections = sections
    }

    private static func bookmarkMatches(_ item: BookmarkItem, query: String) -> Bool {
        (item.plainText?.localizedCaseInsensitiveContains(query) ?? false)
            || (item.title?.localizedCaseInsensitiveContains(query) ?? false)
    }

    /// Shared bundle-ID → display-name lookup. `NSWorkspace.urlForApplication`
    /// is ~50–100µs a call; every row in the app-filter menu and every detail
    /// pane used to pay it on each evaluation.
    func appDisplayName(for bundleId: String?) -> String {
        guard let bundleId, bundleId != "unknown" else { return "Unknown" }
        if let cached = appNameCache[bundleId] { return cached }
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            name = FileManager.default.displayName(atPath: url.path)
        } else {
            name = bundleId
        }
        appNameCache[bundleId] = name
        return name
    }

    func setCategoryFilter(_ category: ClipboardCategory?) {
        activeCategory = category
        applyFilters()
    }

    func setAppFilter(_ bundleId: String?) {
        activeAppBundleId = bundleId
        applyFilters()
    }

    func setTimeFilter(_ filter: HistoryTimeFilter) {
        timeFilter = filter
        applyFilters()
    }

    /// Bounds the jump-to-day calendar to history that actually exists.
    var selectableDateRange: ClosedRange<Date> {
        let end = Date()
        let start = earliestLastCopiedAt
            ?? Calendar.current.date(byAdding: .month, value: -1, to: end)
            ?? end
        return min(start, end)...max(start, end)
    }

    func count(for category: ClipboardCategory) -> Int {
        categoryCounts[category] ?? 0
    }

    var availableApps: [AppFilterOption] {
        appOptions
    }

    @discardableResult
    func addFromPasteboard(_ pasteboard: NSPasteboard) -> HistoryItem? {
        Perf.measure("store.addFromPasteboard") {
            guard let snapshot = PasteboardSnapshot.capture(from: pasteboard) else { return nil }
            guard !IgnoreRules.shouldIgnore(pasteboard: pasteboard, plainText: snapshot.plainText) else { return nil }
            guard IgnoreRules.shouldSave(snapshot: snapshot) else { return nil }
            return addSnapshot(snapshot)
        }
    }

    /// Stores a captured snapshot: dedupe by content hash, classify, insert,
    /// prune. Split from `addFromPasteboard` so tests and the debug seeder can
    /// drive it without a live pasteboard.
    ///
    /// `deferRefresh` skips the post-insert sort/filter/derived-rebuild — for
    /// bulk inserts (seeder, tests) that call `refreshWithoutFetch()` once at
    /// the end instead of paying an O(n) rebuild per row.
    @discardableResult
    func addSnapshot(_ snapshot: PasteboardSnapshot, deferRefresh: Bool = false) -> HistoryItem? {
        #if DEBUG
        DebugTools.benchBegin()
        #endif
        // Encode once and reuse for both the duplicate check and the stored
        // blob — encoding a multi-MB snapshot twice per copy (base64 of the
        // whole payload) stalled the main thread.
        guard let data = Perf.measure("snapshot.encode", { snapshot.encode() }) else { return nil }
        #if DEBUG
        DebugTools.benchMark("encode")
        #endif
        let hash = Perf.measure("snapshot.hash") { ContentHasher.hex(data) }
        #if DEBUG
        DebugTools.benchMark("hash")
        #endif

        if let existing = Perf.measure("store.findDuplicate", {
            findDuplicate(data: data, hash: hash, snapshot: snapshot)
        }) {
            #if DEBUG
            DebugTools.benchMark("dupScan")
            #endif
            let oldDay = dayStartByID[existing.id]?.day
                ?? Calendar.current.startOfDay(for: existing.lastCopiedAt)
            let wasEarliest = earliestLastCopiedAt == existing.lastCopiedAt
            existing.lastCopiedAt = .now
            existing.copyCount += 1
            recordEvent(.copied, on: existing)
            #if DEBUG
            DebugTools.benchMark("dupRecord")
            #endif
            try? modelContext.save()
            #if DEBUG
            DebugTools.benchMark("dupSave")
            #endif
            if !deferRefresh {
                if !recordCopyIncremental(existing, oldDay: oldDay, wasEarliest: wasEarliest, isNew: false) {
                    refreshWithoutFetch()
                }
            }
            #if DEBUG
            DebugTools.benchMark("dupRefresh")
            #endif
            return existing
        }
        #if DEBUG
        DebugTools.benchMark("dupScan")
        #endif

        let category = Perf.measure("snapshot.classify") {
            ContentClassifier.classify(
                snapshot: snapshot,
                pasteboardTypes: snapshot.pasteboardTypes ?? [],
                hasColorOnPasteboard: snapshot.hasColorOnPasteboard ?? false
            )
        }
        #if DEBUG
        DebugTools.benchMark("classify")
        #endif
        let metrics = snapshot.plainText.map { TextAnalytics.metrics(for: $0) }
        let item = HistoryItem(
            contentData: data,
            contentHash: hash,
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
        #if DEBUG
        DebugTools.benchMark("makeItem")
        #endif
        try? modelContext.save()
        #if DEBUG
        DebugTools.benchMark("save")
        #endif
        let removed = prune()
        #if DEBUG
        DebugTools.benchMark("prune")
        #endif
        // No full `reload()` here: it re-fetches every row, re-materializing
        // multi-MB blobs on the main thread (a copied 10MB text froze the app
        // for ~2s per copy). Update the in-memory list instead — incrementally
        // when possible, full sort/filter/derived rebuild otherwise.
        if !deferRefresh, removed.isEmpty,
           recordCopyIncremental(item, oldDay: nil, wasEarliest: false, isNew: true) {
            // applied incrementally
        } else {
            items.removeAll { removed.contains($0) }
            items.append(item)
            if !deferRefresh {
                refreshWithoutFetch(removing: Set(removed.map(\.id)))
            }
        }
        #if DEBUG
        DebugTools.benchMark("refresh")
        #endif
        scheduleCategoryBackfill()

        if snapshot.contentType == .image, let imageData = snapshot.imageData {
            Task {
                if let text = await OCRService.recognizeText(from: imageData) {
                    item.title = boundedTitle(text)
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

    private func findDuplicate(data: Data, hash: String, snapshot: PasteboardSnapshot) -> HistoryItem? {
        // Hash match first — a 64-char string compare per row. `contentData` is
        // only read for the hash hit, so `.externalStorage` blobs are never
        // faulted for non-matching rows.
        if let match = itemsByHash[hash], match.contentData == data {
            return match
        }
        // Legacy rows (no hash yet) are matched without touching `contentData`
        // — the old byte-compare materialized every blob on every copy.
        return legacyItems.first { item in
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
    func prune() -> [HistoryItem] {
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
    /// Internal (not private) so bulk inserters can refresh once at the end.
    func refreshWithoutFetch(removing ids: Set<UUID> = []) {
        items = items.filter { item in
            !ids.contains(item.id)
        }
        #if DEBUG
        DebugTools.benchMark("rwf.filter")
        #endif
        stableSortItems()
        #if DEBUG
        DebugTools.benchMark("rwf.sort")
        #endif
        applyFilters()
        #if DEBUG
        DebugTools.benchMark("rwf.applyFilters")
        #endif
    }

    private func rebuildAppOptions() {
        appOptions = appCountByBundle
            .map { AppFilterOption(bundleId: $0.key, name: appDisplayName(for: $0.key), count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Incremental copy path

    /// True when every item is displayed — no search/category/app/time filter.
    /// Only then is `filteredItems` a pure pin-partition of `items`, which the
    /// incremental updater relies on.
    private var filtersInactive: Bool {
        searchQuery.isEmpty && activeCategory == nil && activeAppBundleId == nil && !timeFilter.isActive
    }

    /// The comparator `stableSortItems` uses — descending by the sort key.
    private func outranks(_ a: HistoryItem, _ b: HistoryItem) -> Bool {
        switch Defaults[.sortOrder] {
        case .lastCopied:
            (a.lastCopiedAt, a.id.uuidString) > (b.lastCopiedAt, b.id.uuidString)
        case .firstCopied:
            (a.firstCopiedAt, a.id.uuidString) > (b.firstCopiedAt, b.id.uuidString)
        case .copyCount:
            (a.copyCount, a.id.uuidString) > (b.copyCount, b.id.uuidString)
        }
    }

    /// First index in `range` whose element does not outrank `item`.
    private func insertionIndex(of item: HistoryItem, in arr: [HistoryItem], range: Range<Int>) -> Int {
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi {
            let mid = (lo + hi) / 2
            if outranks(arr[mid], item) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Range inside `filteredItems` that unpinned items occupy.
    private var unpinnedRange: Range<Int> {
        switch Defaults[.pinPosition] {
        case .top:
            let lo = filteredItems.firstIndex(where: { !$0.isPinned }) ?? filteredItems.count
            return lo..<filteredItems.count
        case .bottom:
            let hi = filteredItems.firstIndex(where: { $0.isPinned }) ?? filteredItems.count
            return 0..<hi
        }
    }

    /// In-memory update for the hot copy path: one item inserted or bumped to
    /// a newer `lastCopiedAt`. Applies a targeted insertion + section surgery
    /// + one light reindex instead of the full sort/filter/derived rebuild.
    /// Returns false when a precondition doesn't hold and the caller must
    /// fall back to `refreshWithoutFetch()`.
    private func recordCopyIncremental(_ item: HistoryItem, oldDay: Date?, wasEarliest: Bool, isNew: Bool) -> Bool {
        guard filtersInactive, !item.isPinned else { return false }
        let calendar = Calendar.current

        // items[] — sort-key order, no pin partition
        if !isNew, let i = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: i)
        }
        items.insert(item, at: insertionIndex(of: item, in: items, range: items.indices))

        // filteredItems[] — pin-partitioned; an unpinned item lives in the
        // unpinned region
        if !isNew, let i = filteredItems.firstIndex(where: { $0.id == item.id }) {
            filteredItems.remove(at: i)
        }
        filteredItems.insert(item, at: insertionIndex(of: item, in: filteredItems, range: unpinnedRange))

        // scalar derived state
        itemsByID[item.id] = item
        if isNew {
            if let h = item.contentHash { itemsByHash[h] = item } else { legacyItems.append(item) }
            categoryCounts[item.category, default: 0] += 1
            appCountByBundle[item.applicationBundleId ?? "unknown", default: 0] += 1
            rebuildAppOptions()
            if earliestLastCopiedAt == nil || item.lastCopiedAt < earliestLastCopiedAt! {
                earliestLastCopiedAt = item.lastCopiedAt
            }
        } else if wasEarliest {
            // The earliest item just got newer — the min moved. Recompute;
            // rare (only when re-copying the single oldest row).
            earliestLastCopiedAt = items.map(\.lastCopiedAt).min()
        }
        let day = calendar.startOfDay(for: item.lastCopiedAt)
        dayStartByID[item.id] = (item.lastCopiedAt, day)

        // sections: move out of the old day bucket (dup path), then into the
        // current one — creating or deleting buckets as needed. A re-copy that
        // lands back in its exact slot leaves rows/maps/ids untouched.
        let from = isNew ? nil : removeFromDaySection(item, day: oldDay)
        let to = insertIntoDaySection(item, day: day, calendar: calendar)
        if isNew || from?.sec != to.sec || from?.idx != to.idx {
            rebuildRowsAndIndexMaps()
            updatePaletteRowIDs()
        }
        return true
    }

    /// Removes `item` from its day section; returns (sectionIndex, itemIndex)
    /// it occupied, or nil when it wasn't found there.
    private func removeFromDaySection(_ item: HistoryItem, day: Date?) -> (sec: Int, idx: Int)? {
        guard let day else { return nil }
        let secID = "day-\(Int(day.timeIntervalSince1970))"
        guard let s = paletteDaySections.firstIndex(where: { $0.id == secID }) else { return nil }
        var items = paletteDaySections[s].items
        guard let j = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        items.remove(at: j)
        if items.isEmpty {
            paletteDaySections.remove(at: s)
        } else {
            let old = paletteDaySections[s]
            paletteDaySections[s] = PaletteDaySection(id: old.id, title: old.title, items: items)
        }
        return (s, j)
    }

    /// Inserts `item` into its day section at sorted position; returns the
    /// (sectionIndex, itemIndex) it now occupies.
    private func insertIntoDaySection(_ item: HistoryItem, day: Date, calendar: Calendar) -> (sec: Int, idx: Int) {
        let secID = "day-\(Int(day.timeIntervalSince1970))"
        if let s = paletteDaySections.firstIndex(where: { $0.id == secID }) {
            var items = paletteDaySections[s].items
            let idx = insertionIndex(of: item, in: items, range: items.indices)
            items.insert(item, at: idx)
            let old = paletteDaySections[s]
            paletteDaySections[s] = PaletteDaySection(id: old.id, title: old.title, items: items)
            return (s, idx)
        }
        // New day bucket — sections stay sorted by day descending; the pinned
        // section is never a day section.
        let section = PaletteDaySection(
            id: secID,
            title: HistoryTimeFilter.sectionTitle(for: day, calendar: calendar),
            items: [item]
        )
        var insertAt = paletteDaySections.count
        for (i, s) in paletteDaySections.enumerated() {
            if s.id == "pinned" {
                if Defaults[.pinPosition] == .bottom { insertAt = i }
                continue
            }
            guard let ts = Int(s.id.dropFirst(4)) else { continue }
            if Date(timeIntervalSince1970: TimeInterval(ts)) < day { insertAt = i; break }
        }
        insertAt = min(insertAt, paletteDaySections.count)
        paletteDaySections.insert(section, at: insertAt)
        return (insertAt, 0)
    }

    func select(_ item: HistoryItem, paste: Bool, withoutFormatting: Bool = false) {
        Perf.measure("store.select") {
            selectImpl(item, paste: paste, withoutFormatting: withoutFormatting)
        }
    }

    private func selectImpl(_ item: HistoryItem, paste: Bool, withoutFormatting: Bool) {
        guard let snapshot = PasteboardSnapshot.decode(from: item.contentData) else { return }
        let strip = withoutFormatting || Defaults[.pasteWithoutFormatting]
        // Clipword writes its own marker, but unformatted writes skip it —
        // ignore the next monitor tick so we don't double-count this copy.
        Defaults[.ignoreNextEvent] = true
        PasteService.copyToClipboard(snapshot: snapshot, withoutFormatting: strip)
        let oldDay = dayStartByID[item.id]?.day
            ?? Calendar.current.startOfDay(for: item.lastCopiedAt)
        let wasEarliest = earliestLastCopiedAt == item.lastCopiedAt
        item.lastCopiedAt = .now
        item.copyCount += 1
        recordEvent(.copied, on: item)
        let shouldPaste = paste || Defaults[.pasteAutomatically]
        if shouldPaste {
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
        if !recordCopyIncremental(item, oldDay: oldDay, wasEarliest: wasEarliest, isNew: false) {
            refreshWithoutFetch()
        }
    }

    private func recordEvent(_ kind: ClipboardEventKind, on item: HistoryItem) {
        let event = ClipboardEvent(
            kind: kind,
            applicationBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            item: item
        )
        modelContext.insert(event)
        // Drop invalidated refs first — touching `id`/`occurredAt` on a model
        // whose backing is gone (deleted + saved elsewhere) fatals.
        item.events.removeAll { $0.modelContext == nil }
        if !item.events.contains(where: { $0.id == event.id }) {
            item.events.append(event)
        }
        let extras = item.events
            .sorted { $0.occurredAt > $1.occurredAt }
            .dropFirst(Self.maxEventsPerItem)
        for extra in extras {
            modelContext.delete(extra)
        }
        // `context.delete` only marks for deletion — the objects stay in the
        // materialized `events` array and fatal on next property access. Drop
        // the references so in-memory readers never see invalidated models.
        if !extras.isEmpty {
            let trimmed = Set(extras.map(\.id))
            item.events.removeAll { trimmed.contains($0.id) }
        }
    }

    func updateContent(_ item: HistoryItem, content: String) {
        if var snapshot = PasteboardSnapshot.decode(from: item.contentData) {
            snapshot.plainText = content
            if let encoded = snapshot.encode() {
                item.contentData = encoded
                item.contentHash = ContentHasher.hex(encoded)
            }
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

    func togglePin(_ item: HistoryItem) {
        item.isPinned.toggle()
        try? modelContext.save()
        publishAction(item.isPinned ? .pinned : .unpinned, itemID: item.id)
        refreshWithoutFetch()
    }

    func toggleBookmark(_ item: HistoryItem) {
        if let existing = findBookmark(matching: item) {
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
    func bookmark(_ item: HistoryItem, in folder: BookmarkFolder?) {
        if let existing = findBookmark(matching: item) {
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

    func folder(forHistoryItem item: HistoryItem) -> BookmarkFolder? {
        findBookmark(matching: item)?.folder
    }

    func folder(id: UUID) -> BookmarkFolder? {
        foldersByID[id] ?? folders.first { $0.id == id }
    }

    private func publishAction(_ kind: HistoryActionKind, itemID: UUID) {
        actionToken += 1
        lastAction = HistoryActionEvent(kind: kind, itemID: itemID, token: actionToken)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    func isContentBookmarked(_ contentData: Data) -> Bool {
        let hash = ContentHasher.hex(contentData)
        return bookmarkItemsByHash[hash] != nil
            || legacyBookmarkItems.contains { $0.contentData == contentData }
    }

    private(set) var bookmarks: [BookmarkItem] = []
    private(set) var folders: [BookmarkFolder] = []
    var selectedBookmarkID: UUID?

    func reloadBookmarks() {
        let descriptor = FetchDescriptor<BookmarkItem>(
            sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)]
        )
        bookmarks = (try? modelContext.fetch(descriptor)) ?? []
        migrateLegacyBookmarksIfNeeded()
        rebuildDerivedData()
    }

    func reloadFolders() {
        let descriptor = FetchDescriptor<BookmarkFolder>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.createdAt)]
        )
        folders = (try? modelContext.fetch(descriptor)) ?? []
        rebuildDerivedData()
    }

    @discardableResult
    func createFolder(named name: String) -> BookmarkFolder {
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

    func renameFolder(_ folder: BookmarkFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? "Untitled" : trimmed
        try? modelContext.save()
        reloadFolders()
        reloadBookmarks()
    }

    func deleteFolder(_ folder: BookmarkFolder) {
        modelContext.delete(folder)
        try? modelContext.save()
        reloadFolders()
        reloadBookmarks()
    }

    func moveBookmark(_ item: BookmarkItem, to folder: BookmarkFolder?) {
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
            // `bookmarks` was just fetched — scan it directly; the hash maps
            // lag one rebuild while migration inserts are in flight.
            let hash = item.contentHash ?? ContentHasher.hex(item.contentData)
            let exists = bookmarks.contains {
                ($0.contentHash == hash && $0.contentData == item.contentData)
                    || ($0.contentHash == nil && $0.contentData == item.contentData)
            }
            if !exists {
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

    private func findBookmark(matching item: HistoryItem) -> BookmarkItem? {
        guard !bookmarks.isEmpty else { return nil }
        if let hash = item.contentHash,
           let match = bookmarkItemsByHash[hash],
           match.contentData == item.contentData {
            return match
        }
        // Only legacy rows (either side missing a hash) need blob compares —
        // and only then is `contentData` faulted at all.
        if item.contentHash == nil || !legacyBookmarkItems.isEmpty {
            let data = item.contentData
            if let match = bookmarkItemsByHash[item.contentHash ?? ContentHasher.hex(data)],
               match.contentData == data {
                return match
            }
            return legacyBookmarkItems.first { $0.contentData == data }
        }
        return nil
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
            if let encoded = snapshot.encode() {
                item.contentData = encoded
                item.contentHash = ContentHasher.hex(encoded)
            }
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
        if let hash = item.contentHash,
           let history = items.first(where: { $0.contentHash == hash }) {
            history.isBookmarked = false
        } else if let history = items.first(where: {
            $0.contentHash == nil && $0.contentData == item.contentData
        }) {
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

    var bookmarkedItems: [HistoryItem] {
        items.filter(\.isBookmarked).sorted { $0.lastCopiedAt > $1.lastCopiedAt }
    }

    func delete(_ item: HistoryItem) {
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

    func clear(unpinnedOnly: Bool) {
        let removed = items.filter { unpinnedOnly ? !$0.isPinned : true }
        let ids = Set(removed.map(\.id))
        for item in removed {
            modelContext.delete(item)
        }
        try? modelContext.save()
        refreshWithoutFetch(removing: ids)
    }

    #if DEBUG
    /// Bulk delete for the DEBUG seeder — one save + one derived rebuild for
    /// the whole batch instead of one per row.
    @discardableResult
    func deleteItems(matching predicate: (HistoryItem) -> Bool) -> Int {
        let doomed = items.filter(predicate)
        let ids = Set(doomed.map(\.id))
        for item in doomed {
            modelContext.delete(item)
        }
        try? modelContext.save()
        refreshWithoutFetch(removing: ids)
        return doomed.count
    }
    #endif

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

import AppKit
