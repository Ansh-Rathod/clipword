import Defaults
import SwiftUI

private enum StorageFocus: Hashable {
    case saveText, saveImages, saveFiles, historySize, sortOrder
}

struct StorageSettingsView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @Default(.saveText) private var saveText
    @Default(.saveImages) private var saveImages
    @Default(.saveFiles) private var saveFiles
    @Default(.historySize) private var historySize
    @Default(.sortOrder) private var sortOrder
    @FocusState private var focus: StorageFocus?

    private let order: [StorageFocus] = [
        .saveText, .saveImages, .saveFiles, .historySize, .sortOrder
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
        .onAppear { if contentShouldTakeFocus { focus = order.first } }
        .onChange(of: enterToken) { _, _ in focus = order.first }
        .onChange(of: contentShouldTakeFocus) { _, should in if !should { focus = nil } }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.space) { activate() }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        var current = focus
        if advanceArrowFocus(&current, order: order, delta: delta) {
            focus = current
            return .handled
        }
        focus = nil
        arrowFocusExit?(delta < 0 ? .previous : .next)
        return .handled
    }

    private func activate() -> KeyPress.Result {
        switch focus {
        case .saveText: saveText.toggle(); return .handled
        case .saveImages: saveImages.toggle(); return .handled
        case .saveFiles: saveFiles.toggle(); return .handled
        default: return .ignored
        }
    }
}
