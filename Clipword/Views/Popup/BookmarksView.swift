import AppKit
import Defaults
import SwiftUI

enum BookmarkFocus: Hashable {
    case typeFilter, appFilter, search, newFolder, list, edit, remove, moveFolder
}

private struct BookmarkListSection: Identifiable {
    let id: String
    let title: String
    let folder: BookmarkFolder?
    let items: [BookmarkItem]
}

struct BookmarksView: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore
    @Environment(SearchService.self) private var searchService
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.arrowFocusEnterTarget) private var enterTarget
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @Environment(\.sidebarOpenForFocus) private var sidebarOpenForFocus
    @Environment(\.globalJumpToken) private var globalJumpToken
    @Environment(\.globalJumpDirection) private var globalJumpDirection
    @Default(.showSearchField) private var showSearchField

    @State private var searchQuery = ""
    @State private var activeCategory: ClipboardCategory?
    @State private var activeAppBundleId: String?
    @State private var editingItem: BookmarkItem?
    @State private var forceSearch = false
    @State private var listScrollTarget: UUID?
    @State private var isNamingFolder = false
    @State private var folderNameDraft = ""
    @State private var renameTarget: BookmarkFolder?
    @State private var assignBookmarkItem: BookmarkItem?
    @State private var collapsedFolderIDs: Set<UUID> = []
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
        toolbar.append(.newFolder)
        if navigableBookmarks.isEmpty {
            return [toolbar]
        }
        return [toolbar, [.list, .edit, .remove, .moveFolder]]
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

    private var isFiltering: Bool {
        activeCategory != nil || activeAppBundleId != nil || !searchQuery.isEmpty
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

    private var listSections: [BookmarkListSection] {
        if historyStore.folders.isEmpty {
            return groupedItems.map {
                BookmarkListSection(id: $0.0, title: $0.0, folder: nil, items: $0.1)
            }
        }

        let items = filteredBookmarks
        var sections: [BookmarkListSection] = []
        for folder in historyStore.folders {
            let folderItems = items.filter { $0.folder?.id == folder.id }
            if folderItems.isEmpty && isFiltering { continue }
            sections.append(
                BookmarkListSection(
                    id: folder.id.uuidString,
                    title: folder.name,
                    folder: folder,
                    items: folderItems
                )
            )
        }
        let unfiled = items.filter { $0.folder == nil }
        if !unfiled.isEmpty {
            sections.append(
                BookmarkListSection(id: "unfiled", title: "Unfiled", folder: nil, items: unfiled)
            )
        }
        return sections
    }

    private var navigableBookmarks: [BookmarkItem] {
        listSections.flatMap { section in
            if let folder = section.folder, collapsedFolderIDs.contains(folder.id) {
                return [BookmarkItem]()
            }
            return section.items
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if listSections.isEmpty {
                ContentUnavailableView(
                    historyStore.bookmarks.isEmpty && historyStore.folders.isEmpty
                        ? "No bookmarks"
                        : "No bookmarks match this filter",
                    systemImage: "bookmark",
                    description: Text(historyStore.bookmarks.isEmpty && historyStore.folders.isEmpty
                        ? "Bookmark clipboard entries, or create a folder to organize them"
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
        .clipwordPanelBackground()
        .sheet(item: $editingItem) { item in
            EditBookmarkSheet(item: item)
        }
        .folderNameAlert(
            isPresented: $isNamingFolder,
            title: renameTarget == nil ? "New Folder" : "Rename Folder",
            name: $folderNameDraft,
            confirmTitle: renameTarget == nil ? "Create" : "Rename",
            onConfirm: confirmFolderName
        )
        .onKeyPress(.rightArrow) { handleArrow(.right) }
        .onKeyPress(.leftArrow) { handleArrow(.left) }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            handleArrow(press.key == .upArrow ? .up : .down, modifiers: press.modifiers)
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in handleDelete() }
        .keyboardDeleteFallback(enabled: focus == .list && !searchFieldActive, action: deleteSelectedItem)
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
            takeKeyboardFocus(target: enterTarget)
        }
        .onChange(of: globalJumpToken) { _, _ in
            applyGlobalJump(globalJumpDirection)
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
        LiquidGlassGroup(spacing: 12) {
        HStack(spacing: 12) {
            KeyboardMenuPicker(
                selection: $activeCategory,
                options: [ClipboardCategory?.none] + ClipboardCategory.allCases.map { Optional($0) },
                title: { $0?.label ?? "All Types" }
            )
            .frame(maxWidth: 140)
            .arrowFocus($focus, equals: .typeFilter)

            KeyboardMenuPicker(
                selection: $activeAppBundleId,
                options: [String?.none] + availableApps.map { Optional($0.bundleId) },
                title: { bundleId in
                    guard let bundleId else { return "All Apps" }
                    if let app = availableApps.first(where: { $0.bundleId == bundleId }) {
                        return "\(app.name) (\(app.count))"
                    }
                    return bundleId
                }
            )
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
                .padding(.horizontal, LiquidGlassMetrics.pillPaddingH)
                .padding(.vertical, LiquidGlassMetrics.pillPaddingV)
                .liquidGlass(
                    .interactive,
                    in: Capsule(),
                    fallback: Color.primary.opacity(0.10)
                )
                .focusable(!searchFieldActive)
                .focused($focus, equals: .search)
                .modifier(ArrowFocusRingModifier(forced: focus == .search && !searchFieldActive))
            }

            Spacer()

            Button {
                beginNewFolder()
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .labelStyle(.iconOnly)
                    .frame(width: LiquidGlassMetrics.iconButtonSize, height: LiquidGlassMetrics.iconButtonSize)
                    .contentShape(RoundedRectangle(cornerRadius: LiquidGlassMetrics.iconRadius, style: .continuous))
            }
            .buttonStyle(.borderless)
            .liquidGlass(
                .interactive,
                in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.iconRadius, style: .continuous),
                fallback: Color.primary.opacity(0.10)
            )
            .arrowFocus($focus, equals: .newFolder)
        }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bookmarksList: some View {
        List {
            ForEach(listSections) { section in
                Section {
                    let collapsed = section.folder.map { collapsedFolderIDs.contains($0.id) } ?? false
                    if !collapsed {
                        if section.items.isEmpty {
                            Text("Empty folder")
                                .foregroundStyle(.tertiary)
                                .font(.callout)
                        } else {
                            ForEach(section.items) { item in
                                BookmarkRowView(
                                    item: item,
                                    emphasized: historyStore.selectedBookmarkID == item.id && focus == .list,
                                    folderName: isFiltering ? item.folder?.name : nil
                                )
                                .id(item.id)
                                .keyboardListRow(
                                    selected: historyStore.selectedBookmarkID == item.id,
                                    listActive: focus == .list
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    historyStore.selectedBookmarkID = item.id
                                    focus = .list
                                    searchFieldActive = false
                                }
                                .onTapGesture(count: 2) {
                                    historyStore.selectBookmark(item, paste: NSEvent.modifierFlags.contains(.option))
                                    appState.hideWindow()
                                }
                                .contextMenu { bookmarkContextMenu(for: item) }
                            }
                        }
                    }
                } header: {
                    bookmarkSectionHeader(section)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.clear)
        .arrowListFocus($focus, equals: .list)
        .scrollToVisible(target: listScrollTarget)
        .onDeleteCommand { deleteSelectedItem() }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            BookmarkDetailPane(
                item: item,
                onEdit: { editingItem = item },
                onMoveFolder: { showFolderMenu(for: item) }
            )
        } else {
            ContentUnavailableView("Select a bookmark", systemImage: "bookmark")
        }
    }

    private func prepareContent(takeFocus: Bool) {
        historyStore.reloadBookmarks()
        historyStore.reloadFolders()
        if takeFocus {
            historyStore.selectedBookmarkID = navigableBookmarks.first?.id
            takeKeyboardFocus(target: .listPreferred)
        } else {
            focus = nil
            searchFieldActive = false
        }
    }

    private func takeKeyboardFocus(target: ArrowFocusEnterTarget) {
        let toolbar = focusRows.first ?? [.typeFilter]
        switch target {
        case .listPreferred:
            if !navigableBookmarks.isEmpty {
                historyStore.selectedBookmarkID = navigableBookmarks.first?.id
                focus = .list
                listScrollTarget = historyStore.selectedBookmarkID
            } else {
                focus = toolbar.first
            }
        case .toolbarLeading:
            focus = toolbar.first
        case .toolbarTrailing:
            focus = toolbar.last
        }
        searchFieldActive = false
    }

    /// Applies a ⌘↑/⌘↓ jump requested from the root (e.g. while the sidebar or
    /// chrome bar holds focus). No-op while editing the search field.
    private func applyGlobalJump(_ direction: SpatialDirection) {
        guard !(focus == .search && searchFieldActive) else { return }
        _ = handleListJump(direction)
    }

    private func handleArrow(_ direction: SpatialDirection, modifiers: EventModifiers = []) -> KeyPress.Result {
        // ⌘↑/⌘↓ jump to the top/bottom item from anywhere in the view (unless
        // the search field is being edited, where they're text-navigation).
        if (direction == .up || direction == .down), modifiers.contains(.command),
           !(focus == .search && searchFieldActive) {
            return handleListJump(direction)
        }

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
            searchFieldActive = false
            applyArrowEdgeExit(
                direction: direction,
                currentIsLeading: current == .typeFilter || current == .list,
                sidebarOpen: sidebarOpenForFocus,
                exit: arrowFocusExit
            )
            return .handled
        case .exitNext:
            return .handled
        }
    }

    private func handleDelete() -> KeyPress.Result {
        guard focus == .list, !searchFieldActive else { return .ignored }
        deleteSelectedItem()
        return .handled
    }

    private func deleteSelectedItem() {
        guard let item = selectedItem else { return }
        let items = navigableBookmarks
        let index = items.firstIndex(where: { $0.id == item.id })
        historyStore.deleteBookmark(item)
        let remaining = navigableBookmarks
        if remaining.isEmpty {
            historyStore.selectedBookmarkID = nil
            focus = focusRows.first?.first ?? .typeFilter
        } else if let index {
            historyStore.selectedBookmarkID = remaining[min(index, remaining.count - 1)].id
        }
        listScrollTarget = historyStore.selectedBookmarkID
    }

    private func handleListJump(_ direction: SpatialDirection) -> KeyPress.Result {
        let items = navigableBookmarks
        guard let target = direction == .up ? items.first : items.last else { return .handled }
        historyStore.selectedBookmarkID = target.id
        focus = .list
        listScrollTarget = target.id
        return .handled
    }

    private func handleListVertical(_ direction: SpatialDirection) -> KeyPress.Result {
        let items = navigableBookmarks
        guard !items.isEmpty else { return .handled }
        let index = historyStore.selectedBookmarkID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0
        if direction == .up {
            if index <= 0 {
                searchFieldActive = false
                focus = focusRows.first?.first ?? .typeFilter
            } else {
                historyStore.selectedBookmarkID = items[index - 1].id
                listScrollTarget = historyStore.selectedBookmarkID
            }
        } else {
            let next = min(items.count - 1, index + 1)
            historyStore.selectedBookmarkID = items[next].id
            listScrollTarget = historyStore.selectedBookmarkID
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
        case .newFolder:
            beginNewFolder()
        case .moveFolder:
            if let item = selectedItem { showFolderMenu(for: item) }
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
            folders: historyStore.folders.map { ($0.id, $0.name) },
            currentFolderID: item.folder?.id,
            moveToFolder: { id in
                historyStore.moveBookmark(item, to: id.flatMap { historyStore.folder(id: $0) })
            },
            moveToNewFolder: { beginNewFolder(assigning: item) },
            remove: { historyStore.deleteBookmark(item) }
        )
    }

    @ViewBuilder
    private func bookmarkSectionHeader(_ section: BookmarkListSection) -> some View {
        if let folder = section.folder {
            Button {
                collapsedFolderIDs.formSymmetricDifference([folder.id])
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedFolderIDs.contains(folder.id) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10)
                    Image(systemName: "folder.fill")
                    Text(section.title)
                    Spacer(minLength: 0)
                    Text("\(section.items.count)")
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .contextMenu {
                Button("Rename…") { beginRename(folder) }
                Button("Delete Folder", role: .destructive) {
                    historyStore.deleteFolder(folder)
                    collapsedFolderIDs.remove(folder.id)
                }
            }
        } else {
            Text(section.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    @ViewBuilder
    private func bookmarkContextMenu(for item: BookmarkItem) -> some View {
        Button("Copy") { historyStore.selectBookmark(item, paste: false) }
            .keyboardShortcut("c")
        Button("Paste") {
            historyStore.selectBookmark(item, paste: true)
            appState.hideWindow()
        }
        Divider()
        Button("Edit…") { editingItem = item }
            .keyboardShortcut("e")
        Menu("Move to Folder") {
            BookmarkFolderPickerButtons(
                folders: historyStore.folders,
                currentFolderID: item.folder?.id,
                allowUnfiled: true,
                onPick: { historyStore.moveBookmark(item, to: $0) },
                onNew: { beginNewFolder(assigning: item) }
            )
        }
        Divider()
        Button("Remove Bookmark", role: .destructive) {
            historyStore.deleteBookmark(item)
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }

    private func showFolderMenu(for item: BookmarkItem) {
        KeyboardContextMenu.popFolderMenu(
            folders: historyStore.folders.map { ($0.id, $0.name) },
            currentFolderID: item.folder?.id,
            includeUnfiled: true,
            select: { id in
                historyStore.moveBookmark(item, to: id.flatMap { historyStore.folder(id: $0) })
            },
            newFolder: { beginNewFolder(assigning: item) }
        )
    }

    private func beginNewFolder(assigning item: BookmarkItem? = nil) {
        renameTarget = nil
        assignBookmarkItem = item
        folderNameDraft = ""
        isNamingFolder = true
    }

    private func beginRename(_ folder: BookmarkFolder) {
        renameTarget = folder
        assignBookmarkItem = nil
        folderNameDraft = folder.name
        isNamingFolder = true
    }

    private func confirmFolderName() {
        if let renameTarget {
            historyStore.renameFolder(renameTarget, to: folderNameDraft)
            self.renameTarget = nil
        } else {
            let folder = historyStore.createFolder(named: folderNameDraft)
            if let item = assignBookmarkItem {
                historyStore.moveBookmark(item, to: folder)
                assignBookmarkItem = nil
            }
        }
        folderNameDraft = ""
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
    var emphasized: Bool = false
    var folderName: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: rowIcon)
                .font(.body)
                .frame(width: 18)

            Text(item.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if let folderName, !folderName.isEmpty {
                Text(folderName)
                    .font(.caption2)
                    .foregroundStyle(emphasized ? Color.white.opacity(0.75) : Color.secondary)
                    .lineLimit(1)
            }

            Image(systemName: "bookmark.fill")
                .font(.caption2)
                .foregroundStyle(emphasized ? Color.white.opacity(0.95) : Color.blue)
        }
        .foregroundStyle(emphasized ? Color.white : Color.primary)
        .padding(.vertical, 2)
    }

    private var rowIcon: String {
        if item.contentType == .image { return "photo" }
        if item.contentType == .file { return "doc" }
        return item.category.systemImage
    }
}

struct BookmarkDetailPane: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore
    let item: BookmarkItem
    var onEdit: () -> Void = {}
    var onMoveFolder: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            contentPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            Divider()

            ScrollView {
                informationSection
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .persistScrollOffset(
                store: appState.scrollStore,
                key: PaletteScrollKey.info(item.id),
                restoreToken: appState.windowPresentationToken
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // actionButtons
            //     .padding(.horizontal, 20)
            //     .padding(.bottom, 16)
            //     .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var contentPreview: some View {
        if item.contentType == .image, let data = item.imageData {
            ScrollView {
                DetailImagePreview(id: item.id, data: data)
            }
            .persistScrollOffset(
                store: appState.scrollStore,
                key: PaletteScrollKey.preview(item.id),
                restoreToken: appState.windowPresentationToken
            )
        } else if let url = ContentClassifier.linkPreviewURL(from: item.plainText) {
            LinkPreviewCard(
                url: url,
                fallbackText: item.plainText ?? url.absoluteString,
                charCount: item.charCount,
                scrollStore: appState.scrollStore,
                scrollKey: PaletteScrollKey.preview(item.id),
                restoreToken: appState.windowPresentationToken
            )
        } else if let text = item.plainText, !text.isEmpty {
            TextPreviewPane(
                text: text,
                charCount: item.charCount,
                scrollStore: appState.scrollStore,
                scrollKey: PaletteScrollKey.preview(item.id),
                restoreToken: appState.windowPresentationToken
            )
        } else {
            ScrollView {
                Text(item.displayTitle)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .persistScrollOffset(
                store: appState.scrollStore,
                key: PaletteScrollKey.preview(item.id),
                restoreToken: appState.windowPresentationToken
            )
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
            if let url = ContentClassifier.linkPreviewURL(from: item.plainText) {
                infoRow("Address") {
                    Button(url.absoluteString) {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help("Open in Browser")
                }
            }
            infoRow("Characters") {
                Text("\(item.charCount)")
            }
            infoRow("Words") {
                Text("\(item.wordCount)")
            }
            infoRow("Folder") {
                Text(item.folder?.name ?? "Unfiled")
            }
            infoRow("Bookmarked") {
                Text(dateLabel(for: item.bookmarkedAt))
            }
            infoRow("Copied") {
                Text(dateLabel(for: item.sourceCopiedAt))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /*
    private var actionButtons: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                DetailIconButton(systemName: "doc.on.doc", help: "Copy") {
                    historyStore.selectBookmark(item, paste: false)
                }
                DetailIconButton(systemName: "text.insert", help: "Paste into focused field") {
                    historyStore.selectBookmark(item, paste: true)
                    appState.hideWindow()
                }
                DetailIconButton(systemName: "pencil", help: "Edit", action: onEdit)
                DetailIconButton(systemName: "folder", help: "Move to Folder", action: onMoveFolder)
                DetailIconButton(systemName: "bookmark.slash", help: "Remove Bookmark") {
                    historyStore.deleteBookmark(item)
                }
                Spacer()
            }
        }
    }
    */

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
        if item.category == .link || ContentClassifier.isLinkText(item.plainText) { return "Link" }
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
