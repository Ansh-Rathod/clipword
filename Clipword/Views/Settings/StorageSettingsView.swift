import Defaults
import SwiftUI

private enum StorageFocus: Hashable {
    case saveText, saveImages, saveFiles, historySize, retention, sortOrder
}

struct StorageSettingsView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @Environment(\.sidebarOpenForFocus) private var sidebarOpenForFocus
    @Default(.saveText) private var saveText
    @Default(.saveImages) private var saveImages
    @Default(.saveFiles) private var saveFiles
    @Default(.historySize) private var historySize
    @Default(.historyRetention) private var historyRetention
    @Default(.sortOrder) private var sortOrder
    @FocusState private var focus: StorageFocus?

    private let order: [StorageFocus] = [
        .saveText, .saveImages, .saveFiles, .historySize, .retention, .sortOrder
    ]

    var body: some View {
        Form {
            Section("Content types") {
                Toggle("Save text", isOn: $saveText)
                    .arrowFocus($focus, equals: .saveText)
                Toggle("Save images", isOn: $saveImages)
                    .arrowFocus($focus, equals: .saveImages)
                Toggle("Save files", isOn: $saveFiles)
                    .arrowFocus($focus, equals: .saveFiles)
            }
            Section("History") {
                Stepper("History size: \(historySize)", value: $historySize, in: 1...999)
                    .arrowFocus($focus, equals: .historySize)
                Picker("Keep history for", selection: $historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.label).tag(retention)
                    }
                }
                .arrowFocus($focus, equals: .retention)
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                .arrowFocus($focus, equals: .sortOrder)
                LabeledContent("Database size", value: historyStore.databaseSize)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: historyRetention) { _, _ in
            historyStore.reload()
        }
        .onAppear { if contentShouldTakeFocus { focus = order.first } }
        .onChange(of: enterToken) { _, _ in focus = order.first }
        .onChange(of: contentShouldTakeFocus) { _, should in if !should { focus = nil } }
        .onKeyPress(.rightArrow) { move(1, vertical: false) }
        .onKeyPress(.leftArrow) { move(-1, vertical: false) }
        .onKeyPress(.downArrow) { move(1, vertical: true) }
        .onKeyPress(.upArrow) { move(-1, vertical: true) }
        .onKeyPress(.return) { activate(delta: 1) }
        .onKeyPress(.space) { activate(delta: -1) }
        .onKeyPress(.escape) { exitToSidebar() }
    }

    private func move(_ delta: Int, vertical: Bool) -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        var current = focus
        if advanceArrowFocus(&current, order: order, delta: delta) {
            focus = current
            return .handled
        }
        if vertical, delta < 0 {
            arrowFocusExit?(.chromeLeading)
        } else if !vertical, delta < 0, sidebarOpenForFocus {
            arrowFocusExit?(.previous)
        }
        return .handled
    }

    private func exitToSidebar() -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        arrowFocusExit?(.previous)
        return .handled
    }

    private func activate(delta: Int) -> KeyPress.Result {
        switch focus {
        case .saveText: saveText.toggle(); return .handled
        case .saveImages: saveImages.toggle(); return .handled
        case .saveFiles: saveFiles.toggle(); return .handled
        case .historySize:
            historySize = min(999, max(1, historySize + delta))
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
}
