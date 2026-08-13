import SwiftUI

struct HistoryTimelineView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(AppState.self) private var appState
    @Environment(SearchService.self) private var searchService

    @State private var searchText = ""

    private var groupedItems: [(String, [HistoryItem])] {
        let items = filteredItems.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { item -> String in
            timelineSection(for: item.lastCopiedAt, calendar: calendar)
        }
        let order = ["Today", "Yesterday", "This Week", "This Month", "Older"]
        return order.compactMap { key in
            guard let group = grouped[key], !group.isEmpty else { return nil }
            return (key, group)
        }
    }

    private var filteredItems: [HistoryItem] {
        guard !searchText.isEmpty else { return historyStore.items }
        return searchService.search(query: searchText, in: historyStore.items)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search history", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()

            if groupedItems.isEmpty {
                ContentUnavailableView(
                    "No history",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Copied items will appear here on a timeline")
                )
            } else {
                List {
                    ForEach(groupedItems, id: \.0) { section, items in
                        Section(section) {
                            ForEach(items) { item in
                                TimelineRowView(item: item) {
                                    historyStore.select(item, paste: false)
                                } onPaste: {
                                    historyStore.select(item, paste: true)
                                } onDelete: {
                                    historyStore.delete(item)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { historyStore.reload() }
    }

    private func timelineSection(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now),
           date >= weekAgo { return "This Week" }
        if let monthAgo = calendar.date(byAdding: .day, value: -30, to: .now),
           date >= monthAgo { return "This Month" }
        return "Older"
    }
}

struct TimelineRowView: View {
    let item: HistoryItem
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Circle()
                    .fill(.tint)
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 2)
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.lastCopiedAt, style: .time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: item.category.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    AppIconView(bundleId: item.applicationBundleId, size: 16)
                }

                Text(item.displayTitle)
                    .lineLimit(3)
                    .font(.body)

                HStack(spacing: 8) {
                    if item.wordCount > 0 {
                        Label("\(item.wordCount) words", systemImage: "text.word.spacing")
                    }
                    if item.copyCount > 1 {
                        Label("×\(item.copyCount)", systemImage: "doc.on.doc")
                    }
                    if item.pasteCount > 0 {
                        Label("\(item.pasteCount) pastes", systemImage: "arrow.uturn.backward")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button("Copy", action: onCopy)
                        .buttonStyle(.borderless)
                    Button("Paste", action: onPaste)
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy", action: onCopy)
                .keyboardShortcut("c")
            Button("Paste", action: onPaste)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }
}
