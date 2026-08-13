import SwiftUI

struct StorageSettingsView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Default(.saveText) private var saveText
    @Default(.saveImages) private var saveImages
    @Default(.saveFiles) private var saveFiles
    @Default(.historySize) private var historySize
    @Default(.sortOrder) private var sortOrder

    var body: some View {
        Form {
            Section("Content types") {
                Toggle("Save text", isOn: $saveText)
                Toggle("Save images", isOn: $saveImages)
                Toggle("Save files", isOn: $saveFiles)
            }
            Section("History") {
                Stepper("History size: \(historySize)", value: $historySize, in: 1...999)
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                LabeledContent("Database size", value: historyStore.databaseSize)
            }
        }
        .formStyle(.grouped)
        .padding()
        .focusSection()
    }
}

import Defaults
