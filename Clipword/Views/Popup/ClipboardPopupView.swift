import AppKit
import Defaults
import SwiftUI

enum ClipboardFocus: Hashable {
    case typeFilter, appFilter, search, list, copy, paste, edit, bookmark, folder, pin
}

struct ClipboardPopupView: View {
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

    @State private var editingItem: HistoryItem?
    @State private var isNamingFolder = false
    @State private var folderNameDraft = ""
    @State private var assignHistoryItem: HistoryItem?
    @State private var forceSearch = false
    @State private var listScrollTarget: UUID?
    @State private var toast: HistoryActionEvent?
    @State private var toastHideTask: Task<Void, Never>?
    @State private var recentlyActedID: UUID?
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
        return [toolbar, [.list, .copy, .paste, .edit, .bookmark, .folder, .pin]]
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
                .overlay(alignment: .top) {
                    if let toast {
                        ActionFeedbackToast(kind: toast.kind)
                            .padding(.top, 14)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.36, dampingFraction: 0.78), value: toast?.token)
            }
        }
        .background(.background)
        .onChange(of: historyStore.lastAction?.token) { _, _ in
            presentActionFeedback()
        }
        .onDisappear { toastHideTask?.cancel() }
        .sheet(item: $editingItem) { item in
            EditContentSheet(item: item)
        }
        .folderNameAlert(
            isPresented: $isNamingFolder,
            title: "New Folder",
            name: $folderNameDraft,
            onConfirm: confirmNewFolder
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
        HStack(spacing: 12) {
            KeyboardMenuPicker(
                selection: Bindable(historyStore).activeCategory,
                options: [ClipboardCategory?.none] + ClipboardCategory.allCases.map { Optional($0) },
                title: { $0?.label ?? "All Types" }
            )
            .frame(maxWidth: 140)
            .arrowFocus($focus, equals: .typeFilter)
            .help("Filter by type")

            KeyboardMenuPicker(
                selection: Bindable(historyStore).activeAppBundleId,
                options: [String?.none] + historyStore.availableApps.map { Optional($0.bundleId) },
                title: { bundleId in
                    guard let bundleId else { return "All Apps" }
                    if let app = historyStore.availableApps.first(where: { $0.bundleId == bundleId }) {
                        return "\(app.name) (\(app.count))"
                    }
                    return bundleId
                }
            )
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
        List {
            ForEach(groupedItems, id: \.0) { section, items in
                Section {
                    ForEach(items) { item in
                        HistoryRowView(
                            item: item,
                            emphasized: historyStore.selectedItemID == item.id && focus == .list,
                            recentlyActed: recentlyActedID == item.id
                        )
                        .id(item.id)
                        .keyboardListRow(
                            selected: historyStore.selectedItemID == item.id,
                            listActive: focus == .list
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            historyStore.selectedItemID = item.id
                            searchFieldActive = false
                            focus = .list
                        }
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
        .arrowListFocus($focus, equals: .list)
        .scrollToVisible(target: listScrollTarget)
        .animation(.snappy(duration: 0.32), value: historyStore.displayedItems.map(\.id))
        .onDeleteCommand { deleteSelectedItem() }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            ClipboardDetailPane(
                item: item,
                focus: $focus,
                onEdit: { editingItem = item },
                onNewFolder: { beginNewFolder(assigning: item) }
            )
        } else {
            ContentUnavailableView("Select an item", systemImage: "doc.on.clipboard")
        }
    }

    private func prepareContent(takeFocus: Bool) {
        historyStore.applyFilters(using: searchService)
        if takeFocus {
            historyStore.selectedItemID = historyStore.displayedItems.first?.id
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
            if !historyStore.displayedItems.isEmpty {
                historyStore.selectedItemID = historyStore.displayedItems.first?.id
                focus = .list
                listScrollTarget = historyStore.selectedItemID
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
            // Stay on the page for → / ↓ at the edge.
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
        historyStore.delete(item)
        listScrollTarget = historyStore.selectedItemID
        if historyStore.displayedItems.isEmpty {
            focus = focusRows.first?.first ?? .typeFilter
        }
    }

    private func handleListJump(_ direction: SpatialDirection) -> KeyPress.Result {
        let items = historyStore.displayedItems
        guard let target = direction == .up ? items.first : items.last else { return .handled }
        historyStore.selectedItemID = target.id
        focus = .list
        listScrollTarget = target.id
        return .handled
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
                listScrollTarget = historyStore.selectedItemID
            }
        } else {
            let next = min(items.count - 1, index + 1)
            historyStore.selectedItemID = items[next].id
            listScrollTarget = historyStore.selectedItemID
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
        case .copy:
            if let item = selectedItem { historyStore.select(item, paste: false) }
        case .paste:
            if let item = selectedItem {
                historyStore.select(item, paste: true)
                appState.hideWindow()
            }
        case .edit:
            editingItem = selectedItem
        case .bookmark:
            if let item = selectedItem { historyStore.toggleBookmark(item) }
        case .folder:
            if let item = selectedItem { showFolderMenu(for: item) }
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
        Menu("Add to Folder") {
            BookmarkFolderPickerButtons(
                folders: historyStore.folders,
                currentFolderID: historyStore.folder(forHistoryItem: item)?.id,
                onPick: { folder in
                    if let folder { historyStore.bookmark(item, in: folder) }
                },
                onNew: { beginNewFolder(assigning: item) }
            )
        }
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
            folders: historyStore.folders.map { ($0.id, $0.name) },
            currentFolderID: historyStore.folder(forHistoryItem: item)?.id,
            addToFolder: { id in
                if let folder = historyStore.folder(id: id) {
                    historyStore.bookmark(item, in: folder)
                }
            },
            addToNewFolder: { beginNewFolder(assigning: item) },
            togglePin: { historyStore.togglePin(item) },
            pinTitle: item.isPinned ? "Unpin" : "Pin",
            delete: { historyStore.delete(item) }
        )
    }

    private func showFolderMenu(for item: HistoryItem) {
        KeyboardContextMenu.popFolderMenu(
            folders: historyStore.folders.map { ($0.id, $0.name) },
            currentFolderID: historyStore.folder(forHistoryItem: item)?.id,
            includeUnfiled: item.isBookmarked,
            select: { id in
                if let id, let folder = historyStore.folder(id: id) {
                    historyStore.bookmark(item, in: folder)
                } else {
                    historyStore.bookmark(item, in: nil)
                }
            },
            newFolder: { beginNewFolder(assigning: item) }
        )
    }

    private func beginNewFolder(assigning item: HistoryItem) {
        assignHistoryItem = item
        folderNameDraft = ""
        isNamingFolder = true
    }

    private func confirmNewFolder() {
        let folder = historyStore.createFolder(named: folderNameDraft)
        if let item = assignHistoryItem {
            historyStore.bookmark(item, in: folder)
            assignHistoryItem = nil
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

    private func presentActionFeedback() {
        guard let action = historyStore.lastAction else { return }
        toastHideTask?.cancel()
        toast = action
        recentlyActedID = action.itemID
        if action.kind == .copied {
            listScrollTarget = action.itemID
        }
        toastHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            toast = nil
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            if recentlyActedID == action.itemID {
                recentlyActedID = nil
            }
        }
    }
}

struct ClipboardDetailPane: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore
    let item: HistoryItem
    var focus: FocusState<ClipboardFocus?>.Binding
    var onEdit: () -> Void = {}
    var onNewFolder: () -> Void = {}

    @State private var copyFlash = false
    @State private var pasteFlash = false
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            contentPreview
                .frame(maxHeight: .infinity)

            Divider()

            informationSection
                .padding(20)
        }
        .onChange(of: historyStore.lastAction?.token) { _, _ in
            flashMatchingAction()
        }
        .onChange(of: item.id) { _, _ in
            copyFlash = false
            pasteFlash = false
            flashTask?.cancel()
        }
        .onDisappear { flashTask?.cancel() }
    }

    @ViewBuilder
    private var contentPreview: some View {
        if item.contentType == .image, let data = item.imageData {
            ScrollView {
                DetailImagePreview(id: item.id, data: data)
            }
        } else if let text = item.plainText, !text.isEmpty {
            TextPreviewPane(text: text, charCount: item.charCount)
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
            infoRow("Copies") {
                Text("\(item.copyCount)")
            }
            infoRow("Pastes") {
                Text("\(item.pasteCount)")
            }

            activitySection

            HStack(spacing: 8) {
                DetailIconButton(
                    systemName: "doc.on.doc",
                    help: "Copy",
                    tint: copyFlash ? .green : nil,
                    flashSuccess: copyFlash,
                    focus: focus,
                    focusValue: .copy
                ) {
                    historyStore.select(item, paste: false)
                }
                DetailIconButton(
                    systemName: "text.insert",
                    help: "Paste into focused field",
                    tint: pasteFlash ? .green : nil,
                    flashSuccess: pasteFlash,
                    focus: focus,
                    focusValue: .paste
                ) {
                    historyStore.select(item, paste: true)
                    appState.hideWindow()
                }
                DetailIconButton(
                    systemName: "pencil",
                    help: "Edit",
                    focus: focus,
                    focusValue: .edit,
                    action: onEdit
                )
                DetailIconButton(
                    systemName: item.isBookmarked ? "bookmark.fill" : "bookmark",
                    help: item.isBookmarked ? "Remove Bookmark" : "Bookmark",
                    tint: item.isBookmarked ? .accentColor : nil,
                    isActive: item.isBookmarked,
                    focus: focus,
                    focusValue: .bookmark
                ) {
                    historyStore.toggleBookmark(item)
                }
                DetailIconButton(
                    systemName: "folder.badge.plus",
                    help: folderButtonHelp,
                    tint: historyStore.folder(forHistoryItem: item) != nil ? .accentColor : nil,
                    isActive: historyStore.folder(forHistoryItem: item) != nil,
                    focus: focus,
                    focusValue: .folder
                ) {
                    showFolderMenu()
                }
                DetailIconButton(
                    systemName: item.isPinned ? "pin.fill" : "pin",
                    help: item.isPinned ? "Unpin" : "Pin",
                    tint: item.isPinned ? .orange : nil,
                    isActive: item.isPinned,
                    focus: focus,
                    focusValue: .pin
                ) {
                    historyStore.togglePin(item)
                }
                Spacer()
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var activitySection: some View {
        let events = item.activityTimeline
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if events.contains(where: \.isSynthesized), item.copyCount > events.filter({ $0.kind == .copied }).count {
                Text("Older copies were counted but not logged individually.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(events) { event in
                        HStack(spacing: 8) {
                            Image(systemName: event.kind.systemImage)
                                .frame(width: 14)
                                .foregroundStyle(.secondary)
                            Text(event.kind.label)
                            if let bundleId = event.applicationBundleId {
                                Text(appName(for: bundleId))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(copiedLabel(for: event.date))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(.top, 4)
    }

    private var folderButtonHelp: String {
        if let folder = historyStore.folder(forHistoryItem: item) {
            return "In “\(folder.name)” — move or add to another folder"
        }
        return "Add to folder"
    }

    private func showFolderMenu() {
        KeyboardContextMenu.popFolderMenu(
            folders: historyStore.folders.map { ($0.id, $0.name) },
            currentFolderID: historyStore.folder(forHistoryItem: item)?.id,
            includeUnfiled: item.isBookmarked,
            select: { id in
                if let id, let folder = historyStore.folder(id: id) {
                    historyStore.bookmark(item, in: folder)
                } else {
                    historyStore.bookmark(item, in: nil)
                }
            },
            newFolder: onNewFolder
        )
    }

    private func flashMatchingAction() {
        guard let action = historyStore.lastAction, action.itemID == item.id else { return }
        flashTask?.cancel()
        switch action.kind {
        case .copied:
            copyFlash = true
            pasteFlash = false
        case .pasted:
            pasteFlash = true
            copyFlash = false
        default:
            return
        }
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            copyFlash = false
            pasteFlash = false
        }
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
