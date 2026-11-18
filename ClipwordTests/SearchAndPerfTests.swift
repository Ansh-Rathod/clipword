import Defaults
import SwiftData
import XCTest

/// Bounded-search correctness + performance measurements for the large-history
/// paths. `measure` blocks print timings in the test log — the same numbers
/// `PERFORMANCE.md` asks you to record before/after a refactor.
@MainActor
final class SearchAndPerfTests: XCTestCase {
    private var container: ModelContainer!
    private var store: HistoryStore!
    private var savedSearchMode: SearchMode = .mixed
    private var savedSortOrder: SortOrder = .lastCopied
    private var savedHistorySize = 0
    private var savedRetention: HistoryRetention = .unlimited
    private var savedBackfillCats = false
    private var savedBackfillHashes = false
    private var savedReclassify = false

    override func setUp() {
        super.setUp()
        savedSearchMode = Defaults[.searchMode]
        savedSortOrder = Defaults[.sortOrder]
        savedHistorySize = Defaults[.historySize]
        savedRetention = Defaults[.historyRetention]
        savedBackfillCats = Defaults[.didBackfillCategories]
        savedBackfillHashes = Defaults[.didBackfillContentHashes]
        savedReclassify = Defaults[.didReclassifyHTMLLinks]

        Defaults[.historySize] = HistorySize.unlimited
        Defaults[.historyRetention] = .unlimited
        Defaults[.didBackfillCategories] = true
        Defaults[.didBackfillContentHashes] = true
        Defaults[.didReclassifyHTMLLinks] = true
        Defaults[.sortOrder] = .lastCopied

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
        Defaults[.searchMode] = savedSearchMode
        Defaults[.sortOrder] = savedSortOrder
        Defaults[.historySize] = savedHistorySize
        Defaults[.historyRetention] = savedRetention
        Defaults[.didBackfillCategories] = savedBackfillCats
        Defaults[.didBackfillContentHashes] = savedBackfillHashes
        Defaults[.didReclassifyHTMLLinks] = savedReclassify
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

    /// Bulk-seed without the per-row derived rebuild — the thing under test
    /// is the measured block, not the fixture setup.
    private func seedRows(_ count: Int, prefix: String = "row") {
        for i in 0..<count {
            store.addSnapshot(snapshot("\(prefix) \(i)"), deferRefresh: true)
        }
        store.refreshWithoutFetch()
    }

    // MARK: - Bounded search

    func testSearchMatchesInsideBound() {
        let service = SearchService()
        Defaults[.searchMode] = .exact
        let head = "needle-here " + String(repeating: "x", count: SearchService.searchableTextLimit)
        store.addSnapshot(snapshot(head))
        XCTAssertEqual(service.search(query: "needle-here", in: store.items).count, 1)
    }

    func testSearchIgnoresBeyondBound() {
        let service = SearchService()
        Defaults[.searchMode] = .exact
        // Needle sits past the searchable head — must not match.
        let text = String(repeating: "x", count: SearchService.searchableTextLimit + 100) + "beyond-bound"
        store.addSnapshot(snapshot(text))
        XCTAssertTrue(service.search(query: "beyond-bound", in: store.items).isEmpty)
    }

    func testTitleStillSearchableWhenTextBounded() {
        let service = SearchService()
        Defaults[.searchMode] = .exact
        let text = String(repeating: "x", count: SearchService.searchableTextLimit + 500) + "beyond-bound"
        let item = store.addSnapshot(snapshot(text))!
        item.title = "distinctive-title"
        XCTAssertEqual(service.search(query: "distinctive-title", in: store.items).count, 1)
    }

    // MARK: - Performance measurements

    /// 1,500 inserts through the real copy pipeline (encode → hash → dedupe →
    /// classify → insert → rebuild). Per-insert cost is O(n) today — watch
    /// this number; if it grows super-linearly the dedupe path regressed.
    func testPerfBulkInsert() {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            for i in 0..<1500 {
                store.addSnapshot(snapshot("perf row \(i)"))
            }
        }
    }

    /// Rebuilds every derived structure — the cost paid once per data change,
    /// not per keypress. Baseline target: well under 100ms at 1,500 items.
    func testPerfApplyFiltersOn1500() {
        seedRows(1500, prefix: "filter row")
        let search = SearchService()
        measure(metrics: [XCTClockMetric()]) {
            store.applyFilters(using: search)
        }
    }

    /// The arrow-key path: selection→index→row. This is what runs on every
    /// arrow keypress; it must stay O(1)-ish regardless of history size.
    func testPerfSelectionLookups() {
        seedRows(1500, prefix: "nav row")
        let rows = store.paletteRows
        measure(metrics: [XCTClockMetric()]) {
            var checksum = 0
            for i in 0..<10_000 {
                let row = rows[i % rows.count]
                if let index = store.paletteIndexBySelection[row.selection] {
                    checksum &+= index
                }
            }
            XCTAssertGreaterThan(checksum, 0)
        }
    }

    /// Reload is the launch-path fetch. External-storage blobs keep it cheap
    /// even with large payloads on disk.
    func testPerfReload() {
        seedRows(500, prefix: "reload row")
        measure(metrics: [XCTClockMetric()]) {
            store.reload()
        }
    }

    /// Dedupe on a full store: a duplicate copy should cost a hash lookup, not
    /// a blob comparison of every row.
    func testPerfDuplicateLookup() {
        seedRows(1500, prefix: "dup row")
        let existing = snapshot("dup row 0")
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<50 {
                store.addSnapshot(existing)
            }
        }
        XCTAssertEqual(store.items.count, 1500)
    }
}
