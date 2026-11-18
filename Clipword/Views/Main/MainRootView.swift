import AppKit
import Defaults
import SwiftUI

struct MainRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore
    @Environment(SearchService.self) private var searchService

    @State private var editingHistoryItem: HistoryItem?
    @State private var editingBookmarkItem: BookmarkItem?
    @State private var isNamingFolder = false
    @State private var folderNameDraft = ""
    @State private var assignHistoryItem: HistoryItem?
    @State private var assignBookmarkItem: BookmarkItem?
    @State private var renameTarget: BookmarkFolder?
    @State private var listScrollTarget: String?
    /// Table row for programmatic reveals — stored at reveal time so the List
    /// subtree never has to read `paletteSelection` to find it.
    @State private var programmaticTableRow: Int?
    @State private var listRevealToken = 0
    @State private var toast: HistoryActionEvent?
    @State private var toastHideTask: Task<Void, Never>?
    @State private var recentlyActedID: UUID?
    @State private var listFocusedState = false
    /// Writes mirror into `PaletteSelectionRegistry` so only the selected
    /// row's `isActive` flips — reading paletteSelection/listFocused in this
    /// body would reconstruct all 1,600+ rows per change.
    private var listFocused: Bool {
        get { listFocusedState }
        nonmutating set {
            listFocusedState = newValue
            PaletteSelectionRegistry.shared.setActive(newValue)
        }
    }
    @State private var showingTimeFilter = false
    @FocusState private var searchFieldActive: Bool
    @FocusState private var backButtonFocused: Bool
    @Default(.pasteAutomatically) private var pasteAutomatically

    private var selectedHistoryItem: HistoryItem? {
        guard case .history(let id) = appState.paletteSelection else { return nil }
        return historyStore.itemsByID[id]
    }

    private var selectedBookmarkItem: BookmarkItem? {
        guard case .bookmark(let id) = appState.paletteSelection else { return nil }
        return historyStore.bookmarkItemsByID[id]
    }

    private var selectedFolder: BookmarkFolder? {
        guard case .folder(let id) = appState.paletteSelection else { return nil }
        return historyStore.foldersByID[id]
    }

    /// History rows/sections/indices are precomputed in `HistoryStore` once per
    /// data change. Bookmark sections come back precomputed too; only the
    /// collapse-aware flattening stays here (bookmarks are few).
    private var bookmarkSections: [PaletteBookmarkSection] {
        guard appState.paletteSource == .bookmarks else { return [] }
        return historyStore.paletteBookmarkSections
    }

    private var historySections: [PaletteDaySection] {
        guard appState.paletteSource == .history else { return [] }
        return historyStore.paletteDaySections
    }

    private var flattenedRows: [PaletteRow] {
        switch appState.paletteSource {
        case .history:
            return historyStore.paletteRows
        case .bookmarks:
            return bookmarkSections.flatMap { section -> [PaletteRow] in
                if let folder = section.folder {
                    var rows: [PaletteRow] = [.folder(folder, count: section.items.count)]
                    if !isCollapsed(folder) {
                        rows.append(contentsOf: section.items.map { .bookmark($0) })
                    }
                    return rows
                }
                return section.items.map { .bookmark($0) }
            }
        }
    }

    /// Triggers list refresh animations and re-selection, replacing the old
    /// `flattenedRows.map(\.id)` diff (which rebuilt a 1000-string array on
    /// every body evaluation).
    private var rowSetKey: RowSetKey {
        RowSetKey(
            version: historyStore.paletteVersion,
            collapsed: appState.collapsedFolderIDs
        )
    }

    private var isEmpty: Bool {
        switch appState.paletteSource {
        case .history:
            return historyStore.paletteRows.isEmpty
        case .bookmarks:
            return bookmarkSections.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            if isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    resultsList
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)
                    Divider()
                    PalettePreviewPane(
                        appState: appState,
                        historyStore: historyStore,
                        isCollapsed: isCollapsed,
                        onEditHistory: { editingHistoryItem = $0 },
                        onEditBookmark: { editingBookmarkItem = $0 },
                        onNewFolder: { beginNewFolder(assigningHistory: $0) },
                        onMoveBookmark: { showBookmarkFolderMenu(for: $0) }
                    )
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
            Divider()
            actionBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.listRevealToken, listRevealToken)
        .clipwordPanelBackground()
        .sheet(item: $editingHistoryItem) { item in
            EditContentSheet(item: item)
        }
        .sheet(item: $editingBookmarkItem) { item in
            EditBookmarkSheet(item: item)
        }
        .folderNameAlert(
            isPresented: $isNamingFolder,
            title: renameTarget == nil ? "New Folder" : "Rename Folder",
            name: $folderNameDraft,
            confirmTitle: renameTarget == nil ? "Create" : "Rename",
            onConfirm: confirmFolderName
        )
        .onAppear {
            let registry = PaletteSelectionRegistry.shared
            // Same math as `tableRow(for:)` — can't capture `self` (View is a
            // value type); the provider only needs the observable stores.
            registry.tableRowProvider = { [appState, historyStore] selection in
                guard let selection else { return nil }
                switch appState.paletteSource {
                case .history:
                    return historyStore.paletteTableRowBySelection[selection]
                case .bookmarks:
                    var row = 0
                    for section in historyStore.paletteBookmarkSections {
                        if let folder = section.folder {
                            if selection == .folder(folder.id) { return row }
                            row += 1
                            let collapsed = !historyStore.searchQuery.isEmpty
                                ? false
                                : appState.collapsedFolderIDs.contains(folder.id)
                            guard !collapsed else { continue }
                            if section.items.isEmpty { row += 1; continue }
                            for item in section.items {
                                if selection == .bookmark(item.id) { return row }
                                row += 1
                            }
                        } else {
                            for item in section.items {
                                if selection == .bookmark(item.id) { return row }
                                row += 1
                            }
                        }
                    }
                    return nil
                }
            }
            prepareForWindowPresentation()
        }
        .onChange(of: appState.windowPresentationToken) { _, _ in
            prepareForWindowPresentation()
        }
        .onChange(of: appState.searchFocusToken) { _, _ in
            listFocused = false
            focusSearch()
        }
        .onChange(of: searchFieldActive) { _, active in
            appState.isSearchFocused = active
            if active { backButtonFocused = false }
        }
        .onChange(of: backButtonFocused) { _, focused in
            if focused {
                listFocused = false
                searchFieldActive = false
                appState.isSearchFocused = false
            }
        }
        .onChange(of: historyStore.searchQuery) { _, _ in
            historyStore.applyFilters(using: searchService)
            selectFirstRow(preferExisting: false)
        }
        .onChange(of: historyStore.activeCategory) { _, _ in
            historyStore.applyFilters(using: searchService)
            listFocused = false
            selectFirstRow(preferExisting: false)
            focusSearch()
        }
        .onChange(of: historyStore.activeAppBundleId) { _, _ in
            historyStore.applyFilters(using: searchService)
            listFocused = false
            selectFirstRow(preferExisting: false)
            focusSearch()
        }
        .onChange(of: historyStore.timeFilter) { _, _ in
            historyStore.applyFilters(using: searchService)
            appState.scrollStore.setOffset(.zero, for: PaletteScrollKey.list(.history))
            listFocused = false
            selectFirstRow(preferExisting: false)
            if !showingTimeFilter {
                focusSearch()
            }
        }
        .onChange(of: showingTimeFilter) { _, visible in
            if !visible { focusSearch() }
        }
        .onChange(of: appState.paletteSource) { _, source in
            if source == .bookmarks {
                collapseAllFolders()
            }
            appState.scrollStore.setOffset(.zero, for: PaletteScrollKey.list(source))
            listFocused = false
            backButtonFocused = false
            selectFirstRow(preferExisting: false)
            focusSearch()
        }
        .onChange(of: rowSetKey) { _, _ in
            selectFirstRow(preferExisting: true)
        }
        .onChange(of: historyStore.lastAction?.token) { _, _ in
            presentActionFeedback()
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            if press.modifiers.contains(.command) {
                return jumpSelection(press.key == .upArrow ? -1 : 1)
            }
            return moveSelection(press.key == .upArrow ? -1 : 1)
        }
        .onKeyPress(.return) { handleReturn() }
        .onKeyPress(.escape) { handleEscape() }
        .onKeyPress(keys: ["k"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            listFocused = true
            showSelectedItemMenu()
            return .handled
        }
        .background {
            Button("Quit Clipword") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            Button("Settings") { appState.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            Button("Toggle bookmarks") { togglePaletteSource() }
                .keyboardShortcut("b", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            Button("Close") { appState.hideWindow() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .onDisappear {
            appState.isSearchFocused = false
            toastHideTask?.cancel()
        }
    }

    private var searchRow: some View {
        LiquidGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                searchLeadingIcon

            TextField(
                appState.paletteSource == .bookmarks ? "Search bookmarks" : "Search clips",
                text: Bindable(historyStore).searchQuery
            )
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .regular))
                .focused($searchFieldActive)
                .layoutPriority(1)
                .simultaneousGesture(TapGesture().onEnded {
                    listFocused = false
                    backButtonFocused = false
                })
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    if press.modifiers.contains(.command) {
                        return jumpSelection(press.key == .upArrow ? -1 : 1)
                    }
                    return moveSelection(press.key == .upArrow ? -1 : 1)
                }
                .onKeyPress(.return) { handleReturn() }
                .onKeyPress(.escape) { handleEscape() }

            if appState.paletteSource == .history {
                timeFilterChip
            }

            combinedFilter

            Button {
                appState.showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: LiquidGlassMetrics.iconFont, weight: .semibold))
                    .frame(width: LiquidGlassMetrics.iconButtonSize, height: LiquidGlassMetrics.iconButtonSize)
                    .contentShape(RoundedRectangle(cornerRadius: LiquidGlassMetrics.iconRadius, style: .continuous))
            }
            .buttonStyle(.borderless)
            .liquidGlass(
                .interactive,
                in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.iconRadius, style: .continuous),
                fallback: Color.primary.opacity(0.10)
            )
            .focusable(false)
            .pointingHandCursor()
            }
        }
        .zIndex(40)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .clipwordChromeBackground()
    }

    @ViewBuilder
    private var searchLeadingIcon: some View {
        if appState.paletteSource == .bookmarks {
            Button {
                goBackToRecents()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: LiquidGlassMetrics.iconFont, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: LiquidGlassMetrics.iconButtonSize, height: LiquidGlassMetrics.iconButtonSize)
                    .contentShape(RoundedRectangle(cornerRadius: LiquidGlassMetrics.iconRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($backButtonFocused)
            .focusEffectDisabled()
            .modifier(ArrowFocusRingModifier(forced: backButtonFocused))
            .liquidGlass(
                .interactive,
                in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.iconRadius, style: .continuous),
                fallback: Color.primary.opacity(0.10)
            )
            .pointingHandCursor()
            .accessibilityLabel("Back to Recents")
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                if press.modifiers.contains(.command) {
                    return jumpSelection(press.key == .upArrow ? -1 : 1)
                }
                return moveSelection(press.key == .upArrow ? -1 : 1)
            }
            .onKeyPress(.return) { handleReturn() }
            .onKeyPress(.delete) { handleBackspace() }
            .onKeyPress(.escape) { handleEscape() }
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            footerPill {
                Button(action: togglePaletteSource) {
                    HStack(spacing: 6) {
                        Text(appState.paletteSource == .bookmarks ? "Recents" : "Bookmarks")
                        PaletteKeycap(text: "⌘")
                        PaletteKeycap(text: "B")
                    }
                }
                .buttonStyle(.plain)
                .focusable(false)
                .pointingHandCursor()
            }

            Spacer(minLength: 8)

            PaletteActionCapsule(
                appState: appState,
                historyStore: historyStore,
                pasteAutomatically: pasteAutomatically,
                isCollapsed: isCollapsed,
                onPrimary: { _ = pasteSelected() },
                onActions: {
                    listFocused = true
                    showSelectedItemMenu()
                }
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .clipwordChromeBackground()
    }

    private func footerPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, LiquidGlassMetrics.pillPaddingH)
            .padding(.vertical, LiquidGlassMetrics.pillPaddingV)
            .contentShape(Capsule())
            .liquidGlass(.interactive, in: Capsule(), fallback: Color.primary.opacity(0.10))
    }

    private func togglePaletteSource() {
        appState.paletteSource = appState.paletteSource == .bookmarks ? .history : .bookmarks
    }

    private var timeFilterChip: some View {
        Button {
            showingTimeFilter.toggle()
        } label: {
            filterChip(
                icon: "calendar",
                title: historyStore.timeFilter.chipTitle,
                emphasized: historyStore.timeFilter.isActive
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingTimeFilter, arrowEdge: .bottom) {
            TimeFilterPopover(
                filter: Bindable(historyStore).timeFilter,
                dateRange: historyStore.selectableDateRange
            )
        }
        .fixedSize()
        .focusable(false)
        .pointingHandCursor()
        .accessibilityLabel("Jump to day")
    }

    private var combinedFilter: some View {
        let hasFilter = historyStore.activeCategory != nil || historyStore.activeAppBundleId != nil
        return Menu {
            if hasFilter {
                Button("Clear Filters") {
                    historyStore.activeCategory = nil
                    historyStore.activeAppBundleId = nil
                }
                Divider()
            }
            Section("Type") {
                filterMenuButton(
                    title: "All Types",
                    selected: historyStore.activeCategory == nil
                ) {
                    historyStore.activeCategory = nil
                }
                ForEach(ClipboardCategory.allCases) { category in
                    filterMenuButton(
                        title: category.label,
                        selected: historyStore.activeCategory == category
                    ) {
                        historyStore.activeCategory = category
                    }
                }
            }
            Section("App") {
                filterMenuButton(
                    title: "All Apps",
                    selected: historyStore.activeAppBundleId == nil
                ) {
                    historyStore.activeAppBundleId = nil
                }
                ForEach(filterApps) { app in
                    filterMenuButton(
                        title: "\(app.name) (\(app.count))",
                        selected: historyStore.activeAppBundleId == app.bundleId
                    ) {
                        historyStore.activeAppBundleId = app.bundleId
                    }
                }
            }
        } label: {
            filterChip(
                icon: combinedFilterIcon,
                title: combinedFilterTitle,
                emphasized: hasFilter
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .focusable(false)
    }

    private func filterMenuButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var combinedFilterIcon: String {
        if let category = historyStore.activeCategory {
            return category.systemImage
        }
        if historyStore.activeAppBundleId != nil {
            return "app.badge"
        }
        return "line.3.horizontal.decrease"
    }

    private var combinedFilterTitle: String {
        let type = historyStore.activeCategory?.label
        let app = selectedAppTitle
        switch (type, app) {
        case (nil, nil):
            return "Filter"
        case (let type?, nil):
            return type
        case (nil, let app?):
            return app
        case (let type?, let app?):
            return "\(type) · \(app)"
        }
    }

    private var selectedAppTitle: String? {
        guard let bundleId = historyStore.activeAppBundleId else { return nil }
        return filterApps.first { $0.bundleId == bundleId }?.name ?? bundleId
    }

    private var filterApps: [AppFilterOption] {
        if appState.paletteSource == .history {
            return historyStore.availableApps
        }
        var counts: [String: Int] = [:]
        for item in historyStore.bookmarks {
            counts[item.applicationBundleId ?? "unknown", default: 0] += 1
        }
        return counts.map { bundleId, count in
            AppFilterOption(
                bundleId: bundleId,
                name: historyStore.appDisplayName(for: bundleId),
                count: count
            )
        }
        .sorted { $0.count > $1.count }
    }

    private func filterChip(icon: String, title: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(emphasized ? Color.accentColor.opacity(0.8) : Color.secondary)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, LiquidGlassMetrics.pillPaddingH)
        .padding(.vertical, LiquidGlassMetrics.pillPaddingV)
        .liquidGlass(
            .interactive,
            in: Capsule(),
            fallback: emphasized ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.10)
        )
        .foregroundStyle(emphasized ? Color.accentColor : Color.primary)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            emptyTitle,
            systemImage: emptyIcon,
            description: Text(emptyDescription)
        )
        .frame(maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch appState.paletteSource {
        case .history:
            return historyStore.items.isEmpty ? "No clipboard history" : "No items match"
        case .bookmarks:
            return historyStore.bookmarks.isEmpty && historyStore.folders.isEmpty
                ? "No bookmarks"
                : "No bookmarks match"
        }
    }

    private var emptyIcon: String {
        switch appState.paletteSource {
        case .history:
            return historyStore.items.isEmpty ? "doc.on.clipboard" : "line.3.horizontal.decrease.circle"
        case .bookmarks:
            return "bookmark"
        }
    }

    private var emptyDescription: String {
        switch appState.paletteSource {
        case .history:
            return historyStore.items.isEmpty
                ? "Copy something to get started"
                : historyStore.timeFilter.isActive
                    ? "Try a different day or search term"
                    : "Try a different filter or search term"
        case .bookmarks:
            return historyStore.bookmarks.isEmpty && historyStore.folders.isEmpty
                ? "Bookmark a clip from Recent, or create a folder"
                : "Try a different filter or search term"
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        switch appState.paletteSource {
        case .history:
            List {
                ForEach(historySections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            historyRow(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .pointerStyle(.default)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .background(RefuseListFirstResponder().frame(width: 0, height: 0))
            .background(
                TableContextMenuInstaller(
                    menu: { tableRow in tableContextMenu(forTableRow: tableRow) },
                    click: { row, count in handleTableClick(row, clickCount: count) }
                )
                .frame(width: 0, height: 0)
            )
            .scrollToVisible(target: listScrollTarget, tableRow: programmaticTableRow)
            .persistScrollOffset(
                store: appState.scrollStore,
                key: PaletteScrollKey.list(.history),
                restoreToken: appState.windowPresentationToken
            )
            .animation(.snappy(duration: 0.32), value: rowSetKey)
        case .bookmarks:
            List {
                ForEach(bookmarkSections) { section in
                    if let folder = section.folder {
                        folderRow(folder, count: section.items.count)
                        if !isCollapsed(folder) {
                            if section.items.isEmpty {
                                Text("Empty folder")
                                    .foregroundStyle(.tertiary)
                                    .font(.callout)
                                    .padding(.leading, 22)
                            } else {
                                ForEach(section.items) { item in
                                    bookmarkRow(item)
                                        .padding(.leading, 16)
                                }
                            }
                        }
                    } else {
                        ForEach(section.items) { item in
                            bookmarkRow(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .pointerStyle(.default)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .background(RefuseListFirstResponder().frame(width: 0, height: 0))
            .background(
                TableContextMenuInstaller(
                    menu: { tableRow in tableContextMenu(forTableRow: tableRow) },
                    click: { row, count in handleTableClick(row, clickCount: count) }
                )
                .frame(width: 0, height: 0)
            )
            .scrollToVisible(target: listScrollTarget, tableRow: programmaticTableRow)
            .persistScrollOffset(
                store: appState.scrollStore,
                key: PaletteScrollKey.list(.bookmarks),
                restoreToken: appState.windowPresentationToken
            )
            .animation(.snappy(duration: 0.32), value: rowSetKey)
        }
    }

    private func historyRow(_ item: HistoryItem) -> some View {
        PaletteHistoryRow(
            item: item,
            sel: PaletteSelectionRegistry.shared.state(for: PaletteRow.historyID(item.id)),
            recentlyActed: recentlyActedID == item.id
        )
    }

    private func folderRow(_ folder: BookmarkFolder, count: Int) -> some View {
        PaletteFolderRow(
            folder: folder,
            count: count,
            collapsed: isCollapsed(folder),
            sel: PaletteSelectionRegistry.shared.state(for: PaletteRow.folderID(folder.id))
        )
    }

    private func bookmarkRow(_ item: BookmarkItem, showFolderName: Bool = false) -> some View {
        PaletteBookmarkRow(
            item: item,
            showFolderName: showFolderName,
            sel: PaletteSelectionRegistry.shared.state(for: PaletteRow.bookmarkID(item.id))
        )
    }

    private func prepareForWindowPresentation() {
        historyStore.reloadBookmarks()
        historyStore.reloadFolders()
        listFocused = false
        backButtonFocused = false
        restoreSelectionIfNeeded()
        focusSearch()
    }

    private func collapseAllFolders() {
        appState.collapsedFolderIDs = Set(historyStore.folders.map(\.id))
    }

    private func isCollapsed(_ folder: BookmarkFolder) -> Bool {
        if !historyStore.searchQuery.isEmpty { return false }
        return appState.collapsedFolderIDs.contains(folder.id)
    }

    private func focusSearch() {
        DispatchQueue.main.async {
            backButtonFocused = false
            searchFieldActive = true
            appState.isSearchFocused = true
        }
    }

    private func focusBackButton() {
        guard appState.paletteSource == .bookmarks else { return }
        listFocused = false
        searchFieldActive = false
        appState.isSearchFocused = false
        DispatchQueue.main.async {
            backButtonFocused = true
        }
    }

    private func goBackToRecents() {
        backButtonFocused = false
        appState.paletteSource = .history
    }

    private func restoreSelectionIfNeeded() {
        selectFirstRow(preferExisting: true)
    }

    private func selectFirstRow(preferExisting: Bool = false) {
        let rows = flattenedRows
        if preferExisting, let current = appState.paletteSelection {
            switch appState.paletteSource {
            case .history where historyStore.paletteIndexBySelection[current] != nil:
                return
            case .bookmarks where rows.contains(where: { $0.selection == current }):
                return
            default:
                break
            }
        }
        if let first = rows.first {
            applySelection(first, reveal: false)
        } else {
            appState.paletteSelection = nil
            historyStore.selectedItemID = nil
            historyStore.selectedBookmarkID = nil
        }
    }

    private func tableRow(for selection: PaletteSelection?) -> Int? {
        guard let selection else { return nil }
        switch appState.paletteSource {
        case .history:
            return historyStore.paletteTableRowBySelection[selection]
        case .bookmarks:
            var row = 0
            for section in bookmarkSections {
                if let folder = section.folder {
                    if selection == .folder(folder.id) { return row }
                    row += 1
                    guard !isCollapsed(folder) else { continue }
                    if section.items.isEmpty {
                        row += 1
                        continue
                    }
                    for item in section.items {
                        if selection == .bookmark(item.id) { return row }
                        row += 1
                    }
                } else {
                    for item in section.items {
                        if selection == .bookmark(item.id) { return row }
                        row += 1
                    }
                }
            }
            return nil
        }
    }

    private func applySelection(_ row: PaletteRow, reveal: Bool = true) {
        appState.paletteSelection = row.selection
        switch row.content {
        case .history(let item):
            historyStore.selectedItemID = item.id
            historyStore.selectedBookmarkID = nil
        case .bookmark(let item):
            historyStore.selectedBookmarkID = item.id
            historyStore.selectedItemID = nil
        case .folder:
            historyStore.selectedItemID = nil
            historyStore.selectedBookmarkID = nil
        }
        if reveal {
            revealSelection(row)
        }
    }

    private func revealSelection(_ row: PaletteRow) {
        listScrollTarget = row.id
        programmaticTableRow = tableRow(for: row.selection)
        listRevealToken += 1
    }

    private func toggleFolder(_ folder: BookmarkFolder) {
        appState.collapsedFolderIDs.formSymmetricDifference([folder.id])
        let count = historyStore.paletteBookmarkSections
            .first { $0.folder?.id == folder.id }?.items.count ?? 0
        applySelection(.folder(folder, count: count))
        focusSearch()
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        Perf.event("palette.moveSelection", "delta=\(delta)")
        if backButtonFocused {
            if delta > 0 {
                focusSearch()
            }
            return .handled
        }

        let rows = flattenedRows

        if !listFocused {
            if delta > 0 {
                guard !rows.isEmpty else { return .handled }
                enterListFocus(rows: rows)
            } else if appState.paletteSource == .bookmarks {
                focusBackButton()
            }
            return .handled
        }

        guard !rows.isEmpty else { return .handled }

        let current: Int
        if let selection = appState.paletteSelection {
            switch appState.paletteSource {
            case .history:
                current = historyStore.paletteIndexBySelection[selection] ?? 0
            case .bookmarks:
                current = rows.firstIndex { $0.selection == selection } ?? 0
            }
        } else {
            current = 0
        }

        if delta < 0 && current <= 0 {
            listFocused = false
            if appState.paletteSource == .bookmarks {
                focusBackButton()
            }
            return .handled
        }

        let next = min(rows.count - 1, max(0, current + delta))
        #if DEBUG
        if DebugTools.navTestActive {
            DebugTools.navLog("[mv] delta=\(delta) cur=\(current) next=\(next) focused=\(listFocused)")
        }
        #endif
        applySelection(rows[next])
        return .handled
    }

    private func jumpSelection(_ delta: Int) -> KeyPress.Result {
        let rows = flattenedRows
        guard let target = delta < 0 ? rows.first : rows.last else { return .handled }
        backButtonFocused = false
        listFocused = true
        applySelection(target)
        return .handled
    }

    private func enterListFocus(rows: [PaletteRow]) {
        listFocused = true
        if let current = appState.paletteSelection,
           let match = rows.first(where: { $0.selection == current }) {
            revealSelection(match)
            return
        }
        applySelection(rows[0])
    }

    private func handleReturn() -> KeyPress.Result {
        if backButtonFocused {
            goBackToRecents()
            return .handled
        }
        return pasteSelected()
    }

    private func handleBackspace() -> KeyPress.Result {
        guard backButtonFocused else { return .ignored }
        goBackToRecents()
        return .handled
    }

    private func pasteSelected() -> KeyPress.Result {
        if let folder = selectedFolder {
            toggleFolder(folder)
            return .handled
        }
        let paste = NSEvent.modifierFlags.contains(.option)
        let strip = NSEvent.modifierFlags.contains(.shift)
        if let item = selectedHistoryItem {
            historyStore.select(item, paste: paste, withoutFormatting: strip)
            appState.hideWindow()
            return .handled
        }
        if let item = selectedBookmarkItem {
            historyStore.selectBookmark(item, paste: paste, withoutFormatting: strip)
            appState.hideWindow()
            return .handled
        }
        return .handled
    }

    private func handleEscape() -> KeyPress.Result {
        if !historyStore.searchQuery.isEmpty {
            historyStore.searchQuery = ""
            historyStore.applyFilters(using: searchService)
            selectFirstRow()
            return .handled
        }
        if historyStore.timeFilter.isActive {
            historyStore.timeFilter = .any
            historyStore.applyFilters(using: searchService)
            selectFirstRow()
            return .handled
        }
        appState.hideWindow()
        return .handled
    }

    private func showSelectedItemMenu() {
        if let item = selectedHistoryItem {
            showHistoryMenu(item)
        } else if let item = selectedBookmarkItem {
            showBookmarkMenu(item)
        }
    }

    /// Left-click on the list's `NSTableView` (single = clickCount 1, double =
    /// 2 — the second click of a double arrives as count 2 with no added
    /// delay). Mirrors what the old per-row tap gestures did: single-click
    /// selects + focuses, double-click acts (paste/expand). Returns false for
    /// section headers so their clicks fall through.
    private func handleTableClick(_ tableRow: Int, clickCount: Int) -> Bool {
        #if DEBUG
        DebugTools.clickMark("tap")
        #endif
        switch appState.paletteSource {
        case .history:
            var index = tableRow
            for section in historyStore.paletteDaySections {
                index -= 1 // section header occupies one table row
                if index < 0 { return false }
                if index < section.items.count {
                    let item = section.items[index]
                    if clickCount >= 2 {
                        historyStore.select(item, paste: NSEvent.modifierFlags.contains(.option))
                        appState.hideWindow()
                    } else {
                        appState.paletteSelection = .history(item.id)
                        historyStore.selectedItemID = item.id
                        listFocused = true
                        focusSearch()
                        #if DEBUG
                        DebugTools.clickMark("sel-written")
                        #endif
                    }
                    return true
                }
                index -= section.items.count
            }
            return false
        case .bookmarks:
            guard flattenedRows.indices.contains(tableRow) else { return false }
            switch flattenedRows[tableRow].content {
            case .bookmark(let item):
                if clickCount >= 2 {
                    historyStore.selectBookmark(item, paste: NSEvent.modifierFlags.contains(.option))
                    appState.hideWindow()
                } else {
                    appState.paletteSelection = .bookmark(item.id)
                    historyStore.selectedBookmarkID = item.id
                    listFocused = true
                    focusSearch()
                }
                return true
            case .folder(let folder, let count):
                if clickCount >= 2 {
                    toggleFolder(folder)
                } else {
                    applySelection(.folder(folder, count: count), reveal: false)
                    listFocused = true
                    focusSearch()
                }
                return true
            case .history:
                return false
            }
        }
    }

    /// Right-click menus come from one `NSMenu` installed on the list's
    /// `NSTableView` (`TableContextMenuInstaller`) — SwiftUI `.contextMenu`
    /// modifiers would be evaluated for every row on every body pass.
    private func tableContextMenu(forTableRow tableRow: Int) -> NSMenu? {
        let menu = buildTableContextMenu(forTableRow: tableRow)
        #if DEBUG
        if DebugTools.navTestActive {
            DebugTools.navLog("[menu] row=\(tableRow) items=\(menu?.numberOfItems ?? 0)")
        }
        #endif
        return menu
    }

    private func buildTableContextMenu(forTableRow tableRow: Int) -> NSMenu? {
        switch appState.paletteSource {
        case .history:
            var index = tableRow
            for section in historyStore.paletteDaySections {
                index -= 1 // each section header occupies one table row
                if index < 0 { return nil }
                if index < section.items.count {
                    return historyItemMenu(section.items[index])
                }
                index -= section.items.count
            }
            return nil
        case .bookmarks:
            guard flattenedRows.indices.contains(tableRow) else { return nil }
            switch flattenedRows[tableRow].content {
            case .bookmark(let item): return bookmarkItemMenu(item)
            case .folder(let folder, _): return folderItemMenu(folder)
            case .history: return nil
            }
        }
    }

    private func historyItemMenu(_ item: HistoryItem) -> NSMenu {
        KeyboardContextMenu.historyMenu(
            copy: { historyStore.select(item, paste: false) },
            paste: {
                historyStore.select(item, paste: true)
                appState.hideWindow()
            },
            addToStack: { historyStore.addToPasteStack(item) },
            edit: { editingHistoryItem = item },
            toggleBookmark: { historyStore.toggleBookmark(item) },
            bookmarkTitle: item.isBookmarked ? "Remove Bookmark" : "Bookmark",
            folders: historyStore.folders.map { ($0.id, $0.name) },
            currentFolderID: historyStore.folder(forHistoryItem: item)?.id,
            addToFolder: { id in
                if let folder = historyStore.folder(id: id) {
                    historyStore.bookmark(item, in: folder)
                }
            },
            addToNewFolder: { beginNewFolder(assigningHistory: item) },
            togglePin: { historyStore.togglePin(item) },
            pinTitle: item.isPinned ? "Unpin" : "Pin",
            delete: { historyStore.delete(item) }
        )
    }

    private func bookmarkItemMenu(_ item: BookmarkItem) -> NSMenu {
        KeyboardContextMenu.bookmarkMenu(
            copy: { historyStore.selectBookmark(item, paste: false) },
            paste: {
                historyStore.selectBookmark(item, paste: true)
                appState.hideWindow()
            },
            edit: { editingBookmarkItem = item },
            folders: historyStore.folders.map { ($0.id, $0.name) },
            currentFolderID: item.folder?.id,
            moveToFolder: { id in
                historyStore.moveBookmark(item, to: id.flatMap { historyStore.folder(id: $0) })
            },
            moveToNewFolder: { beginNewFolder(assigningBookmark: item) },
            remove: { historyStore.deleteBookmark(item) }
        )
    }

    private func folderItemMenu(_ folder: BookmarkFolder) -> NSMenu {
        KeyboardContextMenu.folderMenu(
            collapsed: isCollapsed(folder),
            toggle: { toggleFolder(folder) },
            rename: { beginRename(folder) },
            delete: {
                historyStore.deleteFolder(folder)
                appState.collapsedFolderIDs.remove(folder.id)
            }
        )
    }

    private func showHistoryMenu(_ item: HistoryItem) {
        KeyboardContextMenu.pop(historyItemMenu(item))
    }

    private func showBookmarkMenu(_ item: BookmarkItem) {
        KeyboardContextMenu.pop(bookmarkItemMenu(item))
    }

    private func showBookmarkFolderMenu(for item: BookmarkItem) {
        KeyboardContextMenu.popFolderMenu(
            folders: historyStore.folders.map { ($0.id, $0.name) },
            currentFolderID: item.folder?.id,
            includeUnfiled: true,
            select: { id in
                historyStore.moveBookmark(item, to: id.flatMap { historyStore.folder(id: $0) })
            },
            newFolder: { beginNewFolder(assigningBookmark: item) }
        )
    }

    private func beginNewFolder(assigningHistory item: HistoryItem) {
        renameTarget = nil
        assignHistoryItem = item
        assignBookmarkItem = nil
        folderNameDraft = ""
        isNamingFolder = true
    }

    private func beginNewFolder(assigningBookmark item: BookmarkItem) {
        renameTarget = nil
        assignBookmarkItem = item
        assignHistoryItem = nil
        folderNameDraft = ""
        isNamingFolder = true
    }

    private func beginRename(_ folder: BookmarkFolder) {
        renameTarget = folder
        assignHistoryItem = nil
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
            let assigned = assignHistoryItem != nil || assignBookmarkItem != nil
            if assigned {
                appState.collapsedFolderIDs.remove(folder.id)
            } else {
                appState.collapsedFolderIDs.insert(folder.id)
            }
            if let item = assignHistoryItem {
                historyStore.bookmark(item, in: folder)
                assignHistoryItem = nil
            }
            if let item = assignBookmarkItem {
                historyStore.moveBookmark(item, to: folder)
                assignBookmarkItem = nil
            }
        }
        folderNameDraft = ""
    }

    private func presentActionFeedback() {
        guard let action = historyStore.lastAction else { return }
        toastHideTask?.cancel()
        toast = action
        recentlyActedID = action.itemID
        if action.kind == .copied {
            listScrollTarget = PaletteRow.historyID(action.itemID)
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

private struct PaletteKeycap: View {
    var text: String? = nil
    var systemImage: String? = nil

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
            } else if let text {
                Text(text)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.secondary)
        .frame(minWidth: 18, minHeight: 18)
        .padding(.horizontal, 4)
        .background(
            Color.primary.opacity(LiquidGlassMetrics.controlFillOpacity),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
    }
}

private struct TimeFilterPopover: View {
    @Binding var filter: HistoryTimeFilter
    let dateRange: ClosedRange<Date>
    @Environment(\.dismiss) private var dismiss

    @State private var pickedDay = Date()
    @State private var rangeStart = Date()
    @State private var rangeEnd = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jump to a day")
                .font(.headline)

            presetGrid

            DatePicker(
                "Day",
                selection: pickedDayBinding,
                in: dateRange,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 8) {
                Text("Custom range")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    DatePicker(
                        "From",
                        selection: rangeStartBinding,
                        in: dateRange,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    DatePicker(
                        "To",
                        selection: rangeEndBinding,
                        in: dateRange,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                }
            }
        }
        .padding(16)
        .frame(width: 292)
        .onAppear(perform: syncFromFilter)
    }

    private var pickedDayBinding: Binding<Date> {
        Binding(
            get: { pickedDay },
            set: { newValue in
                pickedDay = newValue
                jumpToDay(newValue)
            }
        )
    }

    private var rangeStartBinding: Binding<Date> {
        Binding(
            get: { rangeStart },
            set: { newValue in
                rangeStart = newValue
                applyCustomRange()
            }
        )
    }

    private var rangeEndBinding: Binding<Date> {
        Binding(
            get: { rangeEnd },
            set: { newValue in
                rangeEnd = newValue
                applyCustomRange()
            }
        )
    }

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                preset("Any time", selected: !filter.isActive) {
                    applyPreset(.any)
                }
                preset("Today", selected: filter == .today) {
                    applyPreset(.today)
                }
                preset("Yesterday", selected: filter == .yesterday) {
                    applyPreset(.yesterday)
                }
            }
            HStack(spacing: 8) {
                preset("Last 7 days", selected: filter == .last7Days) {
                    applyPreset(.last7Days)
                }
                preset("This month", selected: filter == .thisMonth) {
                    applyPreset(.thisMonth)
                }
            }
        }
    }

    private func preset(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.08),
                    in: Capsule()
                )
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func applyPreset(_ next: HistoryTimeFilter) {
        filter = next
        dismiss()
    }

    private func jumpToDay(_ date: Date) {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            filter = .today
        } else if calendar.isDateInYesterday(date) {
            filter = .yesterday
        } else {
            filter = HistoryTimeFilter.spanning(date, to: date)
        }
        dismiss()
    }

    private func applyCustomRange() {
        filter = HistoryTimeFilter.spanning(rangeStart, to: rangeEnd)
    }

    private func syncFromFilter() {
        let calendar = Calendar.current
        let now = Date()
        switch filter {
        case .any, .today, .last7Days, .thisMonth:
            pickedDay = now
            rangeEnd = calendar.startOfDay(for: now)
            if case .last7Days = filter {
                rangeStart = calendar.date(byAdding: .day, value: -6, to: rangeEnd) ?? rangeEnd
            } else if case .thisMonth = filter {
                rangeStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? rangeEnd
            } else {
                rangeStart = rangeEnd
            }
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            pickedDay = yesterday
            rangeStart = calendar.startOfDay(for: yesterday)
            rangeEnd = rangeStart
        case .days(let from, let to):
            pickedDay = to
            rangeStart = calendar.startOfDay(for: from)
            rangeEnd = calendar.startOfDay(for: to)
        }
        rangeStart = clamped(rangeStart)
        rangeEnd = clamped(rangeEnd)
        pickedDay = clamped(pickedDay)
    }

    private func clamped(_ date: Date) -> Date {
        min(max(date, dateRange.lowerBound), dateRange.upperBound)
    }
}

/// Value key driving the palette list's `.animation`/`onChange`. Compared per
/// body evaluation — the old code diffed a fresh 1000-entry array of UUID
/// strings instead.
private struct RowSetKey: Equatable {
    let version: Int
    let collapsed: Set<UUID>
}

// MARK: - Selection-isolated palette rows
//
// The palette body must never read `appState.paletteSelection`: one read makes
// the whole `ForEach` rebuild on every click (~1,600 row constructions ≈
// 110ms). Each row subscribes to its own `PaletteRowSelection` instead — a
// selection move invalidates only the two rows that changed.

/// History row — reads its own selection state, applies `keyboardListRow`
/// internally. Clicks are handled by the table-level monitor
/// (`TableContextMenuInstaller`), so no gestures/contentShape live here.
private struct PaletteHistoryRow: View {
    let item: HistoryItem
    let sel: PaletteRowSelection
    let recentlyActed: Bool

    var body: some View {
        let selected = sel.isSelected
        HistoryRowView(
            item: item,
            emphasized: selected && sel.isActive,
            recentlyActed: recentlyActed
        )
        .equatable()
        .id(PaletteRow.historyID(item.id))
        .keyboardListRow(selected: selected, listActive: sel.isActive)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PaletteBookmarkRow: View {
    let item: BookmarkItem
    let showFolderName: Bool
    let sel: PaletteRowSelection

    var body: some View {
        let selected = sel.isSelected
        BookmarkRowView(
            item: item,
            emphasized: selected && sel.isActive,
            folderName: showFolderName ? item.folder?.name : nil
        )
        .equatable()
        .id(PaletteRow.bookmarkID(item.id))
        .keyboardListRow(selected: selected, listActive: sel.isActive)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PaletteFolderRow: View {
    let folder: BookmarkFolder
    let count: Int
    let collapsed: Bool
    let sel: PaletteRowSelection

    var body: some View {
        let emphasized = sel.isSelected && sel.isActive
        HStack(spacing: 10) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.caption.weight(.semibold))
                .frame(width: 18)
            Image(systemName: "folder.fill")
                .font(.body)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .lineLimit(1)
                Text(count == 1 ? "1 item" : "\(count) items")
                    .font(.caption)
                    .foregroundStyle(emphasized ? Color.white.opacity(0.75) : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(emphasized ? Color.white : Color.primary)
        .padding(.vertical, 2)
        .id(PaletteRow.folderID(folder.id))
        .keyboardListRow(selected: sel.isSelected, listActive: sel.isActive)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Preview pane — owns its `paletteSelection` reads so selection changes
/// rebuild only this small subtree, not the palette.
private struct PalettePreviewPane: View {
    let appState: AppState
    let historyStore: HistoryStore
    let isCollapsed: (BookmarkFolder) -> Bool
    let onEditHistory: (HistoryItem) -> Void
    let onEditBookmark: (BookmarkItem) -> Void
    let onNewFolder: (HistoryItem) -> Void
    let onMoveBookmark: (BookmarkItem) -> Void

    var body: some View {
        #if DEBUG
        let _ = DebugTools.clickMark("pane-eval")
        #endif
        paneContent
    }

    @ViewBuilder
    private var paneContent: some View {
        switch appState.paletteSelection {
        case .history(let id):
            if let item = historyStore.itemsByID[id] {
                ClipboardDetailPane(
                    item: item,
                    onEdit: { onEditHistory(item) },
                    onNewFolder: { onNewFolder(item) }
                )
            } else {
                ContentUnavailableView("Select an item", systemImage: "doc.on.clipboard")
            }
        case .bookmark(let id):
            if let item = historyStore.bookmarkItemsByID[id] {
                BookmarkDetailPane(
                    item: item,
                    onEdit: { onEditBookmark(item) },
                    onMoveFolder: { onMoveBookmark(item) }
                )
            } else {
                ContentUnavailableView("Select an item", systemImage: "doc.on.clipboard")
            }
        case .folder(let id):
            if let folder = historyStore.foldersByID[id] {
                let count = historyStore.paletteBookmarkSections
                    .first { $0.folder?.id == folder.id }?.items.count ?? 0
                ContentUnavailableView(
                    folder.name,
                    systemImage: "folder.fill",
                    description: Text(isCollapsed(folder)
                        ? "\(count == 1 ? "1 item" : "\(count) items") · Return to expand"
                        : "\(count == 1 ? "1 item" : "\(count) items") · ↓ to browse · Return to collapse")
                )
            } else {
                ContentUnavailableView("Select an item", systemImage: "doc.on.clipboard")
            }
        case nil:
            ContentUnavailableView("Select an item", systemImage: "doc.on.clipboard")
        }
    }
}

/// Footer action capsule ("Paste"/"Copy to Clipboard" + "Actions ⌘K") — owns
/// its `paletteSelection` reads; the outer palette body stays selection-free.
private struct PaletteActionCapsule: View {
    let appState: AppState
    let historyStore: HistoryStore
    let pasteAutomatically: Bool
    let isCollapsed: (BookmarkFolder) -> Bool
    let onPrimary: () -> Void
    let onActions: () -> Void

    private var selectedItem: Bool {
        switch appState.paletteSelection {
        case .history(let id): historyStore.itemsByID[id] != nil
        case .bookmark(let id): historyStore.bookmarkItemsByID[id] != nil
        default: false
        }
    }

    private var primaryActionTitle: String? {
        if case .folder(let id) = appState.paletteSelection,
           let folder = historyStore.foldersByID[id] {
            return isCollapsed(folder) ? "Expand" : "Collapse"
        }
        if selectedItem {
            return pasteAutomatically ? "Paste" : "Copy to Clipboard"
        }
        return nil
    }

    var body: some View {
        if primaryActionTitle != nil || selectedItem {
            HStack(spacing: 0) {
                if let primaryActionTitle {
                    Button(action: onPrimary) {
                        HStack(spacing: 6) {
                            Text(primaryActionTitle)
                            PaletteKeycap(systemImage: "return")
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .pointingHandCursor()
                    .disabled(appState.paletteSelection == nil)
                }

                if selectedItem {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 12)

                    Button(action: onActions) {
                        HStack(spacing: 6) {
                            Text("Actions")
                            PaletteKeycap(text: "⌘")
                            PaletteKeycap(text: "K")
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .pointingHandCursor()
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary.opacity(0.9))
            .padding(.horizontal, LiquidGlassMetrics.pillPaddingH)
            .padding(.vertical, LiquidGlassMetrics.pillPaddingV)
            .contentShape(Capsule())
            .liquidGlass(.interactive, in: Capsule(), fallback: Color.primary.opacity(0.10))
        }
    }
}
