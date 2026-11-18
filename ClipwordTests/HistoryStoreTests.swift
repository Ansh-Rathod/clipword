import Defaults
import SwiftData
import XCTest

/// Correctness for the large-history refactor: hash dedupe, >1000-entry stores,
/// cached derived structures, and bounded search. Runs against an in-memory
/// SwiftData container — never touches the on-disk store.
@MainActor
final class HistoryStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: HistoryStore!

    private var savedHistorySize = 0
    private var savedRetention: HistoryRetention = .unlimited
    private var savedBackfillCats = false
    private var savedBackfillHashes = false
    private var savedReclassify = false
    private var savedSortOrder: SortOrder = .lastCopied
    private var savedPinPosition: PinPosition = .top
    private var savedSearchMode: SearchMode = .mixed

    override func setUp() {
        super.setUp()
        // Stub every Defaults key the store reads so the user's real prefs
        // (history cap, retention, backfill flags) can't leak into the test.
        savedHistorySize = Defaults[.historySize]
        savedRetention = Defaults[.historyRetention]
        savedBackfillCats = Defaults[.didBackfillCategories]
        savedBackfillHashes = Defaults[.didBackfillContentHashes]
        savedReclassify = Defaults[.didReclassifyHTMLLinks]
        savedSortOrder = Defaults[.sortOrder]
        savedPinPosition = Defaults[.pinPosition]
        savedSearchMode = Defaults[.searchMode]

        Defaults[.historySize] = HistorySize.unlimited
        Defaults[.historyRetention] = .unlimited
        Defaults[.didBackfillCategories] = true
        Defaults[.didBackfillContentHashes] = true
        Defaults[.didReclassifyHTMLLinks] = true
        Defaults[.sortOrder] = .lastCopied
        Defaults[.pinPosition] = .top

        let schema = Schema([
            HistoryItem.self,
            ClipboardEvent.self,
            WordFrequency.self,
            DailyStats.self,
            BookmarkItem.self,
            BookmarkFolder.self,
        ])
        container = try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = HistoryStore(modelContext: container.mainContext)
    }

    override func tearDown() {
        store = nil
        container = nil
        Defaults[.historySize] = savedHistorySize
        Defaults[.historyRetention] = savedRetention
        Defaults[.didBackfillCategories] = savedBackfillCats
        Defaults[.didBackfillContentHashes] = savedBackfillHashes
        Defaults[.didReclassifyHTMLLinks] = savedReclassify
        Defaults[.sortOrder] = savedSortOrder
        Defaults[.pinPosition] = savedPinPosition
        Defaults[.searchMode] = savedSearchMode
        super.tearDown()
    }

    private func snapshot(_ text: String) -> PasteboardSnapshot {
        PasteboardSnapshot(
            plainText: text,
            contentType: .text,
            pasteboardTypes: ["public.utf8-plain-text"],
            hasColorOnPasteboard: false
        )
    }

    // MARK: - Dedupe

    func testInsertSetsContentHash() {
        let item = store.addSnapshot(snapshot("hello world"))
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.contentHash, ContentHasher.hex(item!.contentData))
    }

    func testDuplicateCopyBumpsCountNotRows() {
        let first = store.addSnapshot(snapshot("repeat me"))
        let second = store.addSnapshot(snapshot("repeat me"))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(second?.copyCount, 2)
    }

    func testDistinctCopiesAreNotDeduped() {
        store.addSnapshot(snapshot("one"))
        store.addSnapshot(snapshot("two"))
        XCTAssertEqual(store.items.count, 2)
    }

    // MARK: - Derived data

    func testDerivedStructuresMatchRows() {
        for i in 0..<50 {
            store.addSnapshot(snapshot("item \(i)"))
        }
        XCTAssertEqual(store.items.count, 50)
        XCTAssertEqual(store.paletteRows.count, store.displayedItems.count)
        XCTAssertFalse(store.paletteDaySections.isEmpty)

        // Selection→index map is the exact inverse of the row list.
        for (index, row) in store.paletteRows.enumerated() {
            XCTAssertEqual(store.paletteIndexBySelection[row.selection], index)
        }
        // Table-row map: values strictly increasing, within section+row count.
        var previous = -1
        for row in store.paletteRows {
            guard let tableRow = store.paletteTableRowBySelection[row.selection] else {
                XCTFail("missing table row for \(row.id)")
                return
            }
            XCTAssertGreaterThan(tableRow, previous)
            previous = tableRow
        }
    }

    func testPinnedItemsGetPinnedSection() {
        let item = store.addSnapshot(snapshot("pinned item"))
        store.addSnapshot(snapshot("normal item"))
        store.togglePin(item!)
        XCTAssertEqual(store.paletteDaySections.first?.id, "pinned")
        XCTAssertEqual(store.paletteDaySections.first?.items.first?.id, item?.id)
    }

    func testCategoryAndAppCounts() {
        store.addSnapshot(snapshot("https://example.com/x"))
        store.addSnapshot(snapshot("just text"))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.categoryCounts.values.reduce(0, +), 2)
        XCTAssertEqual(store.appOptions.count, 1) // nil bundle id → "unknown"
    }

    func testDeleteKeepsDerivedDataConsistent() {
        var ids: [UUID] = []
        for i in 0..<10 {
            ids.append(store.addSnapshot(snapshot("row \(i)"))!.id)
        }
        let victim = store.items.first { $0.id == ids[5] }!
        store.delete(victim)
        XCTAssertEqual(store.items.count, 9)
        XCTAssertNil(store.itemsByID[victim.id])
        XCTAssertNil(store.paletteIndexBySelection[.history(victim.id)])
        XCTAssertEqual(store.paletteRows.count, 9)
    }

    // MARK: - Filters

    func testSearchFiltersRows() {
        store.addSnapshot(snapshot("findable needle"))
        store.addSnapshot(snapshot("haystack only"))
        store.searchQuery = "needle"
        store.applyFilters(using: SearchService())
        XCTAssertEqual(store.displayedItems.count, 1)
        XCTAssertEqual(store.paletteRows.count, 1)
    }

    // MARK: - Scale

    func testMoreThanThousandEntries() {
        for i in 0..<1500 {
            store.addSnapshot(snapshot("bulk row \(i)"), deferRefresh: true)
        }
        store.refreshWithoutFetch()
        XCTAssertEqual(store.items.count, 1500)
        XCTAssertEqual(store.paletteRows.count, 1500)
        XCTAssertEqual(store.paletteIndexBySelection.count, 1500)
        XCTAssertEqual(store.itemsByID.count, 1500)

        // Random-access correctness across the whole map.
        for index in [0, 1, 499, 750, 1499] {
            let row = store.paletteRows[index]
            XCTAssertEqual(store.paletteIndexBySelection[row.selection], index)
        }
    }

    /// Same-timestamp rows must keep a canonical order across rebuilds.
    /// Swift's sort is unstable on ties — without a tie-break, a rebuild could
    /// permute tied rows and shift palette indices under the selection.
    func testSameTimestampOrderIsStableAcrossRebuilds() {
        let stamp = Date(timeIntervalSinceNow: -3600)
        for i in 0..<40 {
            if let item = store.addSnapshot(snapshot("tied row \(i)"), deferRefresh: true) {
                item.firstCopiedAt = stamp
                item.lastCopiedAt = stamp
            }
        }
        try? store.modelContext.save()
        store.refreshWithoutFetch()
        let firstOrder = store.paletteRows.map(\.id)
        store.reload()
        XCTAssertEqual(store.paletteRows.map(\.id), firstOrder)
        store.refreshWithoutFetch()
        XCTAssertEqual(store.paletteRows.map(\.id), firstOrder)
    }

    // MARK: - Bookmarks

    func testBookmarkCopyGetsHash() {
        let item = store.addSnapshot(snapshot("bookmark me"))!
        store.toggleBookmark(item)
        XCTAssertTrue(item.isBookmarked)
        XCTAssertEqual(store.bookmarks.count, 1)
        XCTAssertEqual(store.bookmarks.first?.contentHash, item.contentHash)
    }

    func testToggleBookmarkOffClearsFlag() {
        let item = store.addSnapshot(snapshot("toggle me"))!
        store.toggleBookmark(item)
        store.toggleBookmark(item)
        XCTAssertFalse(item.isBookmarked)
        XCTAssertTrue(store.bookmarks.isEmpty)
    }
}
