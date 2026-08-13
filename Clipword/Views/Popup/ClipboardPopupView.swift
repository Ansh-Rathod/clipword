import AppKit
import Defaults
import SwiftUI

struct ClipboardPopupView: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore
    @Environment(SearchService.self) private var searchService
    @Environment(\.sidebarFocused) private var sidebarFocused
    @Default(.showSearchField) private var showSearchField

    @State private var editingItem: HistoryItem?
    @State private var forceSearch = false
    @FocusState private var field: ContentFocus?

    private var selectedItem: HistoryItem? {
        guard let id = historyStore.selectedItemID else { return nil }
        return historyStore.displayedItems.first { $0.id == id }
    }

    private var groupedItems: [(String, [HistoryItem])] {
        let items = historyStore.displayedItems
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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if historyStore.displayedItems.isEmpty {
                ContentUnavailableView(
                    historyStore.items.isEmpty ? "No clipboard history" : "No items match this filter",
                    systemImage: historyStore.items.isEmpty ? "doc.on.clipboard" : "line.3.horizontal.decrease.circle",
                    description: Text(historyStore.items.isEmpty ? "Copy something to get started" : "Try a different filter or search term")
                )
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    historyList
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                    Divider()
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(.background)
        .sheet(item: $editingItem) { item in
            EditContentSheet(item: item)
        }
        .background { itemKeys }
        .onKeyPress(.upArrow) {
            guard !sidebarFocused else { return .ignored }
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !sidebarFocused else { return .ignored }
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.return) {
            guard !sidebarFocused else { return .ignored }
            if field == .list || field == .search, let item = selectedItem {
                let paste = NSEvent.modifierFlags.contains(.option)
                let strip = NSEvent.modifierFlags.contains(.shift)
                historyStore.select(item, paste: paste, withoutFormatting: strip)
                appState.hideWindow()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            if field == .search {
                if !historyStore.searchQuery.isEmpty {
                    historyStore.searchQuery = ""
                    historyStore.applyFilters(using: searchService)
                    return .handled
                }
                field = .list
                return .handled
            }
            return .ignored
        }
        .onKeyPress(keys: ["1", "2", "3", "4", "5", "6", "7", "8", "9"]) { press in
            guard press.modifiers.contains(.control),
                  !press.modifiers.contains(.command),
                  let char = press.characters.first,
                  let index = Int(String(char)), index >= 1, index <= 9 else { return .ignored }
            let items = historyStore.displayedItems
            guard items.count >= index else { return .ignored }
            historyStore.selectedItemID = items[index - 1].id
            return .handled
        }
        .onKeyPress(keys: ["c"]) { press in
            guard press.modifiers.contains(.command), field != .search, let item = selectedItem else { return .ignored }
            historyStore.select(item, paste: false)
            return .handled
        }
        .onAppear {
            historyStore.applyFilters(using: searchService)
            if historyStore.selectedItemID == nil {
                historyStore.selectedItemID = historyStore.displayedItems.first?.id
            }
            field = .list
        }
        .onChange(of: appState.searchFocusToken) { _, _ in
            forceSearch = true
            DispatchQueue.main.async { field = .search }
        }
        .onChange(of: field) { _, newValue in
            appState.isSearchFocused = newValue == .search
        }
        .onDisappear { appState.isSearchFocused = false }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Type", selection: Bindable(historyStore).activeCategory) {
                Text("All Types").tag(ClipboardCategory?.none)
                ForEach(ClipboardCategory.allCases) { category in
                    Text(category.label).tag(Optional(category))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 140)
            .help("Filter by type")

            Picker("App", selection: Bindable(historyStore).activeAppBundleId) {
                Text("All Apps").tag(String?.none)
                ForEach(historyStore.availableApps) { app in
                    Text("\(app.name) (\(app.count))").tag(Optional(app.bundleId))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 160)
            .help("Filter by app")

            if showSearchField || forceSearch || !historyStore.searchQuery.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: Bindable(historyStore).searchQuery)
                        .textFieldStyle(.plain)
                        .focused($field, equals: .search)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: historyStore.searchQuery) { _, _ in
                    historyStore.applyFilters(using: searchService)
                    if let first = historyStore.displayedItems.first {
                        historyStore.selectedItemID = first.id
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: historyStore.activeCategory) { _, _ in
            historyStore.applyFilters(using: searchService)
        }
        .onChange(of: historyStore.activeAppBundleId) { _, _ in
            historyStore.applyFilters(using: searchService)
        }
    }

    private var historyList: some View {
        List(selection: Bindable(historyStore).selectedItemID) {
            ForEach(groupedItems, id: \.0) { section, items in
                Section {
                    ForEach(items) { item in
                        HistoryRowView(item: item)
                            .tag(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                historyStore.select(item, paste: NSEvent.modifierFlags.contains(.option))
                                appState.hideWindow()
                            }
                            .contextMenu { itemContextMenu(for: item) }
                    }
                } header: {
                    Text(section)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .focused($field, equals: .list)
        .onDeleteCommand {
            guard let item = selectedItem else { return }
            historyStore.delete(item)
        }
    }

    private var itemKeys: some View {
        Group {
            Button("Paste") {
                guard let item = selectedItem else { return }
                historyStore.select(item, paste: true)
                appState.hideWindow()
            }
            .keyboardShortcut(.return, modifiers: .command)
            Button("Edit…") { editingItem = selectedItem }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(selectedItem == nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            ClipboardDetailPane(item: item) {
                editingItem = item
            }
        } else {
            ContentUnavailableView("Select an item", systemImage: "doc.on.clipboard")
        }
    }

    @ViewBuilder
    private func itemContextMenu(for item: HistoryItem) -> some View {
                Button("Copy") { historyStore.select(item, paste: false) }
                Button("Paste") {
                    historyStore.select(item, paste: true)
                    appState.hideWindow()
                }
                Button("Add to Paste Stack") { historyStore.addToPasteStack(item) }
                Divider()
                Button("Edit…") { editingItem = item }
                Button(item.isBookmarked ? "Remove Bookmark" : "Bookmark") {
                    historyStore.toggleBookmark(item)
                }
                Button(item.isPinned ? "Unpin" : "Pin") { historyStore.togglePin(item) }
                Divider()
                Button("Delete", role: .destructive) { historyStore.delete(item) }
    }

    private func moveSelection(_ delta: Int) {
        let items = historyStore.displayedItems
        guard !items.isEmpty else { return }
        guard let currentID = historyStore.selectedItemID,
              let index = items.firstIndex(where: { $0.id == currentID }) else {
            historyStore.selectedItemID = items.first?.id
            return
        }
        let newIndex = max(0, min(items.count - 1, index + delta))
        historyStore.selectedItemID = items[newIndex].id
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

struct ClipboardDetailPane: View {
    @Environment(HistoryStore.self) private var historyStore
    let item: HistoryItem
    var onEdit: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                contentPreview
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .frame(maxHeight: .infinity)

            Divider()

            informationSection
                .padding(20)
        }
    }

    @ViewBuilder
    private var contentPreview: some View {
        if item.contentType == .image, let data = item.imageData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 480)
        } else if let text = item.plainText {
            Text(text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(item.displayTitle)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var informationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Information")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            infoRow("Source") {
                HStack(spacing: 6) {
                    AppIconView(bundleId: item.applicationBundleId, size: 14)
                    Text(appName(for: item.applicationBundleId))
                }
            }
            infoRow("Content type") {
                Text(contentTypeLabel)
            }
            infoRow("Characters") {
                Text("\(item.charCount)")
            }
            infoRow("Words") {
                Text("\(item.wordCount)")
            }
            infoRow("Copied") {
                Text(copiedLabel(for: item.lastCopiedAt))
            }
            if let pasted = item.lastPastedAt {
                infoRow("Pasted") {
                    Text(copiedLabel(for: pasted))
                }
            }

            HStack(spacing: 12) {
                Button("Edit…", action: onEdit)
                Button(item.isBookmarked ? "Remove Bookmark" : "Bookmark") {
                    historyStore.toggleBookmark(item)
                }
                Button(item.isPinned ? "Unpin" : "Pin") {
                    historyStore.togglePin(item)
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
        .font(.body)
    }

    private var contentTypeLabel: String {
        switch item.contentType {
        case .text: return item.category == .styledText ? "Text (Formatted)" : "Text"
        case .rtf: return "Text (Formatted)"
        case .html: return "HTML"
        case .image: return "Image"
        case .file: return "File"
        }
    }

    private func copiedLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .standard)
        if calendar.isDateInToday(date) {
            return "Today at \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday at \(time)"
        }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func appName(for bundleId: String?) -> String {
        guard let bundleId, bundleId != "unknown" else { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId
    }
}

struct EditContentSheet: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    let item: HistoryItem
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Content")
                .font(.headline)
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .frame(minWidth: 420, minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    historyStore.updateContent(item, content: draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .onAppear { draft = item.plainText ?? "" }
    }
}
