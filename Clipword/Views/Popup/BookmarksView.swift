import AppKit
import Defaults
import SwiftUI

enum BookmarkFocus: Hashable {
    case typeFilter, appFilter, search, list, edit, remove
}

struct BookmarksView: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore
    @Environment(SearchService.self) private var searchService
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @Environment(\.sidebarOpenForFocus) private var sidebarOpenForFocus
    @Default(.showSearchField) private var showSearchField

    @State private var searchQuery = ""
    @State private var activeCategory: ClipboardCategory?
    @State private var activeAppBundleId: String?
    @State private var editingItem: BookmarkItem?
    @State private var forceSearch = false
    @FocusState private var focus: BookmarkFocus?
    @FocusState private var searchFieldActive: Bool

    private var selectedItem: BookmarkItem? {
        guard let id = historyStore.selectedBookmarkID else { return nil }
        return filteredBookmarks.first { $0.id == id }
    }

    private var showSearch: Bool {
        showSearchField || forceSearch || !searchQuery.isEmpty
    }

    private var focusRows: [[BookmarkFocus]] {
        var toolbar: [BookmarkFocus] = [.typeFilter, .appFilter]
        if showSearch { toolbar.append(.search) }
        if filteredBookmarks.isEmpty {
            return [toolbar]
        }
        return [toolbar, [.list, .edit, .remove]]
    }

    private var availableApps: [AppFilterOption] {
        var counts: [String: Int] = [:]
        for item in historyStore.bookmarks {
            let key = item.applicationBundleId ?? "unknown"
            counts[key, default: 0] += 1
        }
        return counts.map { bundleId, count in
            let name: String
            if bundleId == "unknown" {
                name = "Unknown"
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                name = FileManager.default.displayName(atPath: url.path)
            } else {
                name = bundleId
            }
            return AppFilterOption(bundleId: bundleId, name: name, count: count)
        }
        .sorted { $0.count > $1.count }
    }

    private var filteredBookmarks: [BookmarkItem] {
        var result = historyStore.bookmarks
        if let activeCategory {
            result = result.filter { $0.category == activeCategory }
        }
        if let activeAppBundleId {
            result = result.filter { $0.applicationBundleId == activeAppBundleId }
        }
        if !searchQuery.isEmpty {
            result = searchService.searchBookmarks(query: searchQuery, in: result)
        }
        return result
    }

    private var groupedItems: [(String, [BookmarkItem])] {
        let items = filteredBookmarks
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { item -> String in
            timelineSection(for: item.bookmarkedAt, calendar: calendar)
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

            if filteredBookmarks.isEmpty {
                ContentUnavailableView(
                    historyStore.bookmarks.isEmpty ? "No bookmarks" : "No bookmarks match this filter",
                    systemImage: "bookmark",
                    description: Text(historyStore.bookmarks.isEmpty
                        ? "Bookmark clipboard entries to keep them here"
                        : "Try a different filter or search term")
                )
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    bookmarksList
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                    Divider()
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(.background)
        .sheet(item: $editingItem) { item in
            EditBookmarkSheet(item: item)
        }
        .onKeyPress(.rightArrow) { handleArrow(.right) }
        .onKeyPress(.leftArrow) { handleArrow(.left) }
        .onKeyPress(.downArrow) { handleArrow(.down) }
        .onKeyPress(.upArrow) { handleArrow(.up) }
        .onKeyPress(.return) { activateFocused() }
        .onKeyPress(.space) { activateFocused(allowListPaste: false) }
        .onKeyPress(.escape) {
            if searchFieldActive {
                if !searchQuery.isEmpty {
                    searchQuery = ""
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
            Picker("Type", selection: $activeCategory) {
                Text("All Types").tag(ClipboardCategory?.none)
                ForEach(ClipboardCategory.allCases) { category in
                    Text(category.label).tag(Optional(category))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 140)
            .arrowFocus($focus, equals: .typeFilter)

            Picker("App", selection: $activeAppBundleId) {
                Text("All Apps").tag(String?.none)
                ForEach(availableApps) { app in
                    Text("\(app.name) (\(app.count))").tag(Optional(app.bundleId))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 160)
            .arrowFocus($focus, equals: .appFilter)

            if showSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFieldActive)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .focusable(!searchFieldActive)
                .focused($focus, equals: .search)
                .modifier(ArrowFocusRingModifier(forced: focus == .search && !searchFieldActive))
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bookmarksList: some View {
        List(selection: Bindable(historyStore).selectedBookmarkID) {
            ForEach(groupedItems, id: \.0) { section, items in
                Section {
                    ForEach(items) { item in
                        BookmarkRowView(item: item)
                            .tag(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                historyStore.selectBookmark(item, paste: NSEvent.modifierFlags.contains(.option))
                                appState.hideWindow()
                            }
                            .contextMenu {
                                Button("Copy") { historyStore.selectBookmark(item, paste: false) }
                                    .keyboardShortcut("c")
                                Button("Paste") {
                                    historyStore.selectBookmark(item, paste: true)
                                    appState.hideWindow()
                                }
                                Divider()
                                Button("Edit…") { editingItem = item }
                                    .keyboardShortcut("e")
                                Button("Remove Bookmark", role: .destructive) {
                                    historyStore.deleteBookmark(item)
                                }
                                .keyboardShortcut(.delete, modifiers: .command)
                            }
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
            historyStore.deleteBookmark(item)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            BookmarkDetailPane(
                item: item,
                focus: $focus,
                onEdit: { editingItem = item }
            )
        } else {
            ContentUnavailableView("Select a bookmark", systemImage: "bookmark")
        }
    }

    private func prepareContent(takeFocus: Bool) {
        historyStore.reloadBookmarks()
        if historyStore.selectedBookmarkID == nil {
            historyStore.selectedBookmarkID = filteredBookmarks.first?.id
        }
        if takeFocus {
            takeKeyboardFocus(preferList: true)
        } else {
            focus = nil
            searchFieldActive = false
        }
    }

    private func takeKeyboardFocus(preferList: Bool) {
        if preferList, !filteredBookmarks.isEmpty {
            if historyStore.selectedBookmarkID == nil {
                historyStore.selectedBookmarkID = filteredBookmarks.first?.id
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
            return .handled
        }
    }

    private func handleListVertical(_ direction: SpatialDirection) -> KeyPress.Result {
        let items = filteredBookmarks
        guard !items.isEmpty else { return .handled }
        let index = historyStore.selectedBookmarkID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0
        if direction == .up {
            if index <= 0 {
                searchFieldActive = false
                focus = focusRows.first?.first ?? .typeFilter
            } else {
                historyStore.selectedBookmarkID = items[index - 1].id
            }
        } else {
            let next = min(items.count - 1, index + 1)
            historyStore.selectedBookmarkID = items[next].id
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
            historyStore.selectBookmark(item, paste: paste, withoutFormatting: strip)
            appState.hideWindow()
        case .edit:
            editingItem = selectedItem
        case .remove:
            if let item = selectedItem { historyStore.deleteBookmark(item) }
        case .typeFilter:
            KeyboardContextMenu.popCategoryFilter(current: activeCategory) { category in
                activeCategory = category
            }
        case .appFilter:
            KeyboardContextMenu.popAppFilter(
                apps: availableApps,
                current: activeAppBundleId
            ) { bundleId in
                activeAppBundleId = bundleId
            }
        }
        return .handled
    }

    private func showItemMenu(_ item: BookmarkItem) {
        KeyboardContextMenu.popBookmark(
            copy: { historyStore.selectBookmark(item, paste: false) },
            paste: {
                historyStore.selectBookmark(item, paste: true)
                appState.hideWindow()
            },
            edit: { editingItem = item },
            remove: { historyStore.deleteBookmark(item) }
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

struct BookmarkRowView: View {
    let item: BookmarkItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: rowIcon)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 18)

            Text(item.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Image(systemName: "bookmark.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
        }
        .padding(.vertical, 2)
    }

    private var rowIcon: String {
        if item.contentType == .image { return "photo" }
        if item.contentType == .file { return "doc" }
        return item.category.systemImage
    }
}

struct BookmarkDetailPane: View {
    @Environment(HistoryStore.self) private var historyStore
    let item: BookmarkItem
    var focus: FocusState<BookmarkFocus?>.Binding
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
            infoRow("Bookmarked") {
                Text(dateLabel(for: item.bookmarkedAt))
            }
            infoRow("Copied") {
                Text(dateLabel(for: item.sourceCopiedAt))
            }

            HStack(spacing: 12) {
                Button("Edit…", action: onEdit)
                    .buttonStyle(.borderless)
                    .arrowFocus(focus, equals: .edit)
                Button("Remove Bookmark", role: .destructive) {
                    historyStore.deleteBookmark(item)
                }
                .buttonStyle(.borderless)
                .arrowFocus(focus, equals: .remove)
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

    private func dateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .standard)
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
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

struct EditBookmarkSheet: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    let item: BookmarkItem
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Bookmark")
                .font(.headline)
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .frame(minWidth: 420, minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    historyStore.updateBookmarkContent(item, content: draft)
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
