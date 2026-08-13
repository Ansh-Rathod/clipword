import AppKit
import Defaults
import SwiftUI

enum ClipboardFocus: Hashable {
    case typeFilter, appFilter, search, list, edit, bookmark, pin
}

struct ClipboardPopupView: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore
    @Environment(SearchService.self) private var searchService
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @Environment(\.sidebarOpenForFocus) private var sidebarOpenForFocus
    @Default(.showSearchField) private var showSearchField

    @State private var editingItem: HistoryItem?
    @State private var forceSearch = false
    @FocusState private var focus: ClipboardFocus?
    @FocusState private var searchFieldActive: Bool

    private var selectedItem: HistoryItem? {
        guard let id = historyStore.selectedItemID else { return nil }
        return historyStore.displayedItems.first { $0.id == id }
    }

    private var showSearch: Bool {
        showSearchField || forceSearch || !historyStore.searchQuery.isEmpty
    }

    private var focusRows: [[ClipboardFocus]] {
        var toolbar: [ClipboardFocus] = [.typeFilter, .appFilter]
        if showSearch { toolbar.append(.search) }
        if historyStore.displayedItems.isEmpty {
            return [toolbar]
        }
        return [toolbar, [.list, .edit, .bookmark, .pin]]
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
        .onKeyPress(.rightArrow) { handleArrow(.right) }
        .onKeyPress(.leftArrow) { handleArrow(.left) }
        .onKeyPress(.downArrow) { handleArrow(.down) }
        .onKeyPress(.upArrow) { handleArrow(.up) }
        .onKeyPress(.return) { activateFocused() }
        .onKeyPress(.space) { activateFocused(allowListPaste: false) }
        .onKeyPress(.escape) {
            if searchFieldActive {
                if !historyStore.searchQuery.isEmpty {
                    historyStore.searchQuery = ""
                    historyStore.applyFilters(using: searchService)
                    return .handled
                }
                searchFieldActive = false
                focus = .search
                return .handled
            }
            // Esc from any highlighted control → back to the sidebar.
            guard focus != nil else { return .ignored }
            searchFieldActive = false
            arrowFocusExit?(.previous)
            return .handled
        }
        .onKeyPress(keys: ["k"]) { press in
            guard press.modifiers.contains(.command), let item = selectedItem else { return .ignored }
            showItemMenu(item)
            return .handled
        }
        .onAppear { prepareContent(takeFocus: contentShouldTakeFocus) }
        .onChange(of: enterToken) { _, _ in
            takeKeyboardFocus(preferList: true)
        }
        .onChange(of: contentShouldTakeFocus) { _, should in
            if !should {
                searchFieldActive = false
                focus = nil
            }
        }
        .onChange(of: appState.searchFocusToken) { _, _ in
            forceSearch = true
            DispatchQueue.main.async {
                focus = .search
                searchFieldActive = true
            }
        }
        .onChange(of: focus) { _, newValue in
            if newValue != .search { searchFieldActive = false }
            appState.isSearchFocused = searchFieldActive
        }
        .onChange(of: searchFieldActive) { _, active in
            appState.isSearchFocused = active
        }
        .onDisappear {
            appState.isSearchFocused = false
            searchFieldActive = false
        }
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
            .arrowFocus($focus, equals: .typeFilter)
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
            .arrowFocus($focus, equals: .appFilter)
            .help("Filter by app")

            if showSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: Bindable(historyStore).searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFieldActive)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .focusable(!searchFieldActive)
                .focused($focus, equals: .search)
                .modifier(ArrowFocusRingModifier(forced: focus == .search && !searchFieldActive))
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
        .arrowFocus($focus, equals: .list)
        .onDeleteCommand {
            guard let item = selectedItem else { return }
            historyStore.delete(item)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            ClipboardDetailPane(
                item: item,
                focus: $focus,
                onEdit: { editingItem = item }
            )
        } else {
            ContentUnavailableView("Select an item", systemImage: "doc.on.clipboard")
        }
    }

    private func prepareContent(takeFocus: Bool) {
        historyStore.applyFilters(using: searchService)
        if historyStore.selectedItemID == nil {
            historyStore.selectedItemID = historyStore.displayedItems.first?.id
        }
        if takeFocus {
            takeKeyboardFocus(preferList: true)
        } else {
            focus = nil
            searchFieldActive = false
        }
    }

    private func takeKeyboardFocus(preferList: Bool) {
        if preferList, !historyStore.displayedItems.isEmpty {
            if historyStore.selectedItemID == nil {
                historyStore.selectedItemID = historyStore.displayedItems.first?.id
            }
            focus = .list
        } else {
            focus = focusRows.first?.first
        }
        searchFieldActive = false
    }

    private func handleArrow(_ direction: SpatialDirection) -> KeyPress.Result {
        guard let current = focus else { return .ignored }

        if current == .search, searchFieldActive {
            if direction == .left || direction == .right { return .ignored }
            searchFieldActive = false
        }

        if current == .list, direction == .up || direction == .down {
            return handleListVertical(direction)
        }

        let result = moveSpatialFocus(
            from: current,
            direction: direction,
            rows: focusRows,
            listIDs: []
        )
        switch result {
        case .moved(let next):
            searchFieldActive = false
            focus = next
            return .handled
        case .listMove:
            return .handled
        case .exitPrevious:
            if direction == .up {
                searchFieldActive = false
                arrowFocusExit?(current == .typeFilter ? .chromeLeading : .chromeTrailing)
            } else if direction == .left, sidebarOpenForFocus {
                searchFieldActive = false
                arrowFocusExit?(.previous)
            }
            return .handled
        case .exitNext:
            // Stay on the page for → / ↓ at the edge.
            return .handled
        }
    }

    private func handleListVertical(_ direction: SpatialDirection) -> KeyPress.Result {
        let items = historyStore.displayedItems
        guard !items.isEmpty else { return .handled }
        let index = historyStore.selectedItemID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0
        if direction == .up {
            if index <= 0 {
                searchFieldActive = false
                focus = focusRows.first?.first ?? .typeFilter
            } else {
                historyStore.selectedItemID = items[index - 1].id
            }
        } else {
            let next = min(items.count - 1, index + 1)
            historyStore.selectedItemID = items[next].id
        }
        return .handled
    }

    private func activateFocused(allowListPaste: Bool = true) -> KeyPress.Result {
        guard let focus else { return .ignored }
        switch focus {
        case .search:
            searchFieldActive = true
            return .handled
        case .list:
            guard allowListPaste, let item = selectedItem else { return .ignored }
            let paste = NSEvent.modifierFlags.contains(.option)
            let strip = NSEvent.modifierFlags.contains(.shift)
            historyStore.select(item, paste: paste, withoutFormatting: strip)
            appState.hideWindow()
        case .edit:
            editingItem = selectedItem
        case .bookmark:
            if let item = selectedItem { historyStore.toggleBookmark(item) }
        case .pin:
            if let item = selectedItem { historyStore.togglePin(item) }
        case .typeFilter:
            KeyboardContextMenu.popCategoryFilter(current: historyStore.activeCategory) { category in
                historyStore.activeCategory = category
                historyStore.applyFilters(using: searchService)
            }
        case .appFilter:
            KeyboardContextMenu.popAppFilter(
                apps: historyStore.availableApps,
                current: historyStore.activeAppBundleId
            ) { bundleId in
                historyStore.activeAppBundleId = bundleId
                historyStore.applyFilters(using: searchService)
            }
        }
        return .handled
    }

    @ViewBuilder
    private func itemContextMenu(for item: HistoryItem) -> some View {
        Button("Copy") { historyStore.select(item, paste: false) }
            .keyboardShortcut("c")
        Button("Paste") {
            historyStore.select(item, paste: true)
            appState.hideWindow()
        }
        Button("Add to Paste Stack") { historyStore.addToPasteStack(item) }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        Divider()
        Button("Edit…") { editingItem = item }
            .keyboardShortcut("e")
        Button(item.isBookmarked ? "Remove Bookmark" : "Bookmark") {
            historyStore.toggleBookmark(item)
        }
        .keyboardShortcut("b", modifiers: .option)
        Button(item.isPinned ? "Unpin" : "Pin") { historyStore.togglePin(item) }
            .keyboardShortcut("p", modifiers: .option)
        Divider()
        Button("Delete", role: .destructive) { historyStore.delete(item) }
            .keyboardShortcut(.delete, modifiers: .command)
    }

    private func showItemMenu(_ item: HistoryItem) {
        KeyboardContextMenu.popHistory(
            copy: { historyStore.select(item, paste: false) },
            paste: {
                historyStore.select(item, paste: true)
                appState.hideWindow()
            },
            addToStack: { historyStore.addToPasteStack(item) },
            edit: { editingItem = item },
            toggleBookmark: { historyStore.toggleBookmark(item) },
            bookmarkTitle: item.isBookmarked ? "Remove Bookmark" : "Bookmark",
            togglePin: { historyStore.togglePin(item) },
            pinTitle: item.isPinned ? "Unpin" : "Pin",
            delete: { historyStore.delete(item) }
        )
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
    var focus: FocusState<ClipboardFocus?>.Binding
    var onEdit: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            contentPreview
                .frame(maxHeight: .infinity)

            Divider()

            informationSection
                .padding(20)
        }
    }

    @ViewBuilder
    private var contentPreview: some View {
        if item.contentType == .image, let data = item.imageData, let image = NSImage(data: data) {
            ScrollView {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        } else if let text = item.plainText, !text.isEmpty {
            ReadOnlyTextView(text: text)
        } else {
            ScrollView {
                Text(item.displayTitle)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
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
                    .buttonStyle(.borderless)
                    .arrowFocus(focus, equals: .edit)
                Button(item.isBookmarked ? "Remove Bookmark" : "Bookmark") {
                    historyStore.toggleBookmark(item)
                }
                .buttonStyle(.borderless)
                .arrowFocus(focus, equals: .bookmark)
                Button(item.isPinned ? "Unpin" : "Pin") {
                    historyStore.togglePin(item)
                }
                .buttonStyle(.borderless)
                .arrowFocus(focus, equals: .pin)
                Spacer()
            }
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
