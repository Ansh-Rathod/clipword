import Defaults
import SwiftUI

private enum StorageFocus: Hashable {
    case saveText, saveImages, saveFiles, loadLinkPreviews, clearCache
    case historySize, retention, sortOrder
}

struct StorageSettingsView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Default(.saveText) private var saveText
    @Default(.saveImages) private var saveImages
    @Default(.saveFiles) private var saveFiles
    @Default(.loadLinkPreviews) private var loadLinkPreviews
    @Default(.historySize) private var historySize
    @Default(.historyRetention) private var historyRetention
    @Default(.sortOrder) private var sortOrder
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @Environment(\.globalJumpToken) private var globalJumpToken
    @Environment(\.globalJumpDirection) private var globalJumpDirection
    @State private var previewCacheSize = LinkPreviewService.cacheSizeDescription
    @FocusState private var focus: StorageFocus?

    private let order: [StorageFocus] = [
        .saveText, .saveImages, .saveFiles, .loadLinkPreviews, .clearCache,
        .historySize, .retention, .sortOrder
    ]

    private var historySizeChoices: [Int] {
        var choices = HistorySize.presets
        if historySize > 0, !choices.contains(historySize) {
            choices.insert(historySize, at: 1)
        }
        return choices
    }

    /// Last focusable row of the preceding section — scroll anchor so a focused
    /// row lower in the Form is revealed when focus lands on it.
    private func sectionAnchor(for focus: StorageFocus) -> StorageFocus {
        switch focus {
        case .saveText, .saveImages, .saveFiles: return .saveText
        case .loadLinkPreviews, .clearCache: return .saveFiles
        case .historySize, .retention, .sortOrder: return .clearCache
        }
    }

    var body: some View {
        Form {
            Section("Content types") {
                Toggle("Save text", isOn: $saveText)
                    .arrowFocus($focus, equals: .saveText)
                    .id(StorageFocus.saveText)
                Toggle("Save images", isOn: $saveImages)
                    .arrowFocus($focus, equals: .saveImages)
                    .id(StorageFocus.saveImages)
                Toggle("Save files", isOn: $saveFiles)
                    .arrowFocus($focus, equals: .saveFiles)
                    .id(StorageFocus.saveFiles)
            }
            Section("Link previews") {
                Toggle("Load link previews", isOn: $loadLinkPreviews)
                    .arrowFocus($focus, equals: .loadLinkPreviews)
                    .id(StorageFocus.loadLinkPreviews)
                Text("When you view a copied link, Clipword fetches its title, description, and thumbnail. Previews are cached on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Preview cache", value: previewCacheSize)
                Button("Clear Preview Cache") { clearPreviewCache() }
                    .arrowFocus($focus, equals: .clearCache)
                    .id(StorageFocus.clearCache)
            }
            Section("History") {
                Picker("History size", selection: $historySize) {
                    ForEach(historySizeChoices, id: \.self) { size in
                        Text(HistorySize.label(size)).tag(size)
                    }
                }
                .arrowFocus($focus, equals: .historySize)
                .id(StorageFocus.historySize)
                Picker("Keep history for", selection: $historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.label).tag(retention)
                    }
                }
                .arrowFocus($focus, equals: .retention)
                .id(StorageFocus.retention)
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                .arrowFocus($focus, equals: .sortOrder)
                .id(StorageFocus.sortOrder)
                LabeledContent("Database size", value: historyStore.databaseSize)
                Text("History is stored on this Mac at ~/Library/Application Support/Clipword. Deleting the app does not delete it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .scrollToVisible(target: focus.map { sectionAnchor(for: $0) }, anchor: .center)
        .onAppear {
            previewCacheSize = LinkPreviewService.cacheSizeDescription
            if contentShouldTakeFocus { focus = order.first }
        }
        .onChange(of: historyRetention) { _, _ in
            historyStore.pruneByRetention()
            historyStore.reload()
        }
        .onChange(of: historySize) { _, _ in
            historyStore.prune()
            historyStore.reload()
        }
        .onChange(of: enterToken) { _, _ in focus = order.first }
        .onChange(of: globalJumpToken) { _, _ in applyGlobalJump(globalJumpDirection) }
        .onChange(of: contentShouldTakeFocus) { _, should in
            if should {
                if focus == nil { focus = order.first }
            } else {
                focus = nil
            }
        }
        .onKeyPress(.rightArrow) { move(1, vertical: false) }
        .onKeyPress(.leftArrow) { move(-1, vertical: false) }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            if press.modifiers.contains(.command) {
                applyGlobalJump(press.key == .upArrow ? .up : .down)
                return .handled
            }
            return move(press.key == .upArrow ? -1 : 1, vertical: true)
        }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.space) { activate() }
        .onKeyPress(.escape) { exitToSidebar() }
    }

    /// ⌘↑/⌘↓ jump the form to its top or bottom row (works even when no row is
    /// focused, e.g. right after leaving the page).
    private func applyGlobalJump(_ direction: SpatialDirection) {
        focus = direction == .up ? order.first : order.last
    }

    /// Single-column form: ↑/↓ walk the rows; → activates the focused row
    /// (same as Return — toggles, opens pickers); ← backs out to the sidebar.
    /// Reaching either end just eats the key — no ejection, no surprise jumps.
    private func move(_ delta: Int, vertical: Bool) -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        if !vertical {
            if delta > 0 { return activate() }
            arrowFocusExit?(.previous)
            return .handled
        }
        var current = focus
        if advanceArrowFocus(&current, order: order, delta: delta) {
            focus = current
        }
        return .handled
    }

    private func exitToSidebar() -> KeyPress.Result {
        arrowFocusExit?(.previous)
        return .handled
    }

    private func activate() -> KeyPress.Result {
        switch focus {
        case .saveText: saveText.toggle(); return .handled
        case .saveImages: saveImages.toggle(); return .handled
        case .saveFiles: saveFiles.toggle(); return .handled
        case .loadLinkPreviews: loadLinkPreviews.toggle(); return .handled
        case .clearCache:
            clearPreviewCache()
            return .handled
        case .historySize:
            KeyboardContextMenu.popChoices(
                title: { HistorySize.label($0) },
                current: historySize,
                choices: historySizeChoices
            ) { historySize = $0 }
            return .handled
        case .retention:
            KeyboardContextMenu.popChoices(
                title: { $0.label },
                current: historyRetention,
                choices: HistoryRetention.allCases
            ) { historyRetention = $0 }
            return .handled
        case .sortOrder:
            KeyboardContextMenu.popChoices(
                title: { $0.label },
                current: sortOrder,
                choices: SortOrder.allCases
            ) { sortOrder = $0 }
            return .handled
        default:
            return .ignored
        }
    }

    private func clearPreviewCache() {
        Task {
            await LinkPreviewService.shared.clearCache()
            previewCacheSize = LinkPreviewService.cacheSizeDescription
        }
    }
}
