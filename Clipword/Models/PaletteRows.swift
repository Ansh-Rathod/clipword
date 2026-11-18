import AppKit
import Foundation
import Observation

/// One day-grouped section of the history palette. Built once per data change
/// inside `HistoryStore.applyFilters` — not per view evaluation — so arrow-key
/// navigation and row updates stay O(1)-ish on huge histories.
struct PaletteDaySection: Identifiable {
    let id: String
    let title: String
    let items: [HistoryItem]
}

struct PaletteBookmarkSection: Identifiable {
    let id: String
    let title: String
    let folder: BookmarkFolder?
    let items: [BookmarkItem]
}

/// A selectable row in the palette list. `id` is precomputed at build time:
/// deriving `"h-\(uuid.uuidString)"` per access multiplied string interpolation
/// by every view evaluation on large histories.
struct PaletteRow: Identifiable, Hashable {
    enum Content: Hashable {
        case history(HistoryItem)
        case bookmark(BookmarkItem)
        case folder(BookmarkFolder, count: Int)
    }

    let id: String
    let content: Content

    var selection: PaletteSelection {
        switch content {
        case .history(let item): .history(item.id)
        case .bookmark(let item): .bookmark(item.id)
        case .folder(let folder, _): .folder(folder.id)
        }
    }

    var historyItem: HistoryItem? {
        if case .history(let item) = content { return item }
        return nil
    }

    static func history(_ item: HistoryItem) -> PaletteRow {
        PaletteRow(id: historyID(item.id), content: .history(item))
    }

    static func bookmark(_ item: BookmarkItem) -> PaletteRow {
        PaletteRow(id: "b-\(item.id.uuidString)", content: .bookmark(item))
    }

    static func folder(_ folder: BookmarkFolder, count: Int) -> PaletteRow {
        PaletteRow(id: "f-\(folder.id.uuidString)", content: .folder(folder, count: count))
    }

    static func historyID(_ id: UUID) -> String {
        "h-\(id.uuidString)"
    }

    static func bookmarkID(_ id: UUID) -> String {
        "b-\(id.uuidString)"
    }

    static func folderID(_ id: UUID) -> String {
        "f-\(id.uuidString)"
    }
}

extension PaletteSelection {
    /// The `PaletteRow.id` this selection corresponds to — the same key the
    /// row views and the selection registry use.
    var rowID: String {
        switch self {
        case .history(let id): PaletteRow.historyID(id)
        case .bookmark(let id): PaletteRow.bookmarkID(id)
        case .folder(let id): PaletteRow.folderID(id)
        }
    }
}

/// Per-row selection state. Each list row subscribes to its own tiny object,
/// so a selection change invalidates only the two rows that flipped — the
/// palette's `ForEach` is never reconstructed for a click or arrow move.
/// (Reading `appState.paletteSelection` inside the parent body makes every
/// row depend on it: ~1,600 row constructions ≈ 110ms per click.)
@Observable
final class PaletteRowSelection {
    var isSelected = false
    /// Selected *and* the list holds keyboard focus — drives the accent
    /// (vs. inactive gray) chrome, same as the old `selected && listFocused`.
    var isActive = false
}

@MainActor
final class PaletteSelectionRegistry {
    static let shared = PaletteSelectionRegistry()
    private var states: [String: PaletteRowSelection] = [:]
    private var selectedRowID: String?
    private var active = false

    /// Maps a selection to its `NSTableView` row — installed by the palette so
    /// `apply` can paint AppKit's native row highlight synchronously. The
    /// table's own selection draw is immediate; SwiftUI cell updates arrive
    /// ~55ms later (List batches cell passes), which is what made clicks lag.
    var tableRowProvider: ((PaletteSelection?) -> Int?)?

    /// Row-state lookup during `ForEach` construction — a plain dictionary
    /// read, *not* an observed dependency, so parents stay selection-free.
    func state(for rowID: String) -> PaletteRowSelection {
        if let state = states[rowID] { return state }
        let state = PaletteRowSelection()
        state.isSelected = rowID == selectedRowID
        state.isActive = state.isSelected && active
        states[rowID] = state
        return state
    }

    /// `listFocused` mirror — only the selected row's `isActive` changes.
    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if let id = selectedRowID { states[id]?.isActive = active }
    }

    /// Mirrors `paletteSelection` into the per-row states. Called from
    /// `AppState.paletteSelection.didSet` — synchronous and post-commit, so
    /// `selection` is always the new value. (An earlier version observed via
    /// `withObservationTracking`, whose onChange fires during willSet and
    /// reads the *old* value — that's what made the highlight lag one click.)
    func apply(selection: PaletteSelection?) {
        let newID = selection?.rowID
        guard newID != selectedRowID else { return }
        if let old = selectedRowID, let s = states[old] {
            s.isSelected = false
            s.isActive = false
        }
        selectedRowID = newID
        if let newID, let s = states[newID] {
            s.isSelected = true
            s.isActive = active
        }
        // Instant visual: the table draws its own selection rect this frame —
        // no waiting on the deferred List cell pass for the custom chrome.
        if let table = TableContextMenuView.currentTable {
            if let row = tableRowProvider?(selection), row >= 0, row < table.numberOfRows {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }
        #if DEBUG
        DebugTools.clickMark("applied")
        #endif
    }
}
