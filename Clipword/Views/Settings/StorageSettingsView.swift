import Defaults
import SwiftUI

struct StorageSettingsView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Default(.saveText) private var saveText
    @Default(.saveImages) private var saveImages
    @Default(.saveFiles) private var saveFiles
    @Default(.loadLinkPreviews) private var loadLinkPreviews
    @Default(.historySize) private var historySize
    @Default(.historyRetention) private var historyRetention
    @Default(.sortOrder) private var sortOrder
    @State private var previewCacheSize = LinkPreviewService.cacheSizeDescription

    private var historySizeChoices: [Int] {
        var choices = HistorySize.presets
        if historySize > 0, !choices.contains(historySize) {
            choices.insert(historySize, at: 1)
        }
        return choices
    }

    var body: some View {
        Form {
            Section("Content types") {
                Toggle("Save text", isOn: $saveText)
                Toggle("Save images", isOn: $saveImages)
                Toggle("Save files", isOn: $saveFiles)
            }
            Section("Link previews") {
                Toggle("Load link previews", isOn: $loadLinkPreviews)
                Text("When you view a copied link, Clipword fetches its title, description, and thumbnail. Previews are cached on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Preview cache", value: previewCacheSize)
                Button("Clear Preview Cache") {
                    Task {
                        await LinkPreviewService.shared.clearCache()
                        previewCacheSize = LinkPreviewService.cacheSizeDescription
                    }
                }
            }
            Section("History") {
                Picker("History size", selection: $historySize) {
                    ForEach(historySizeChoices, id: \.self) { size in
                        Text(HistorySize.label(size)).tag(size)
                    }
                }
                Picker("Keep history for", selection: $historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.label).tag(retention)
                    }
                }
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                LabeledContent("Database size", value: historyStore.databaseSize)
                Text("History is stored on this Mac at ~/Library/Application Support/Clipword. Deleting the app does not delete it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            previewCacheSize = LinkPreviewService.cacheSizeDescription
        }
        .onChange(of: historyRetention) { _, _ in
            historyStore.pruneByRetention()
            historyStore.reload()
        }
        .onChange(of: historySize) { _, _ in
            historyStore.prune()
            historyStore.reload()
        }
    }
}
