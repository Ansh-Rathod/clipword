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
    @State private var listRevealToken = 0
    @State private var toast: HistoryActionEvent?
    @State private var toastHideTask: Task<Void, Never>?
    @State private var recentlyActedID: UUID?
    @State private var listFocused = false
    @State private var showingTimeFilter = false
    @FocusState private var searchFieldActive: Bool
    @FocusState private var backButtonFocused: Bool
    @Default(.pasteAutomatically) private var pasteAutomatically

    private var selectedHistoryItem: HistoryItem? {
        guard case .history(let id) = appState.paletteSelection else { return nil }
        return historyRows.first { $0.id == id }
    }

    private var selectedBookmarkItem: BookmarkItem? {
        guard case .bookmark(let id) = appState.paletteSelection else { return nil }
        return bookmarkRows.first { $0.id == id }
    }

    private var selectedFolder: BookmarkFolder? {
        guard case .folder(let id) = appState.paletteSelection else { return nil }
        return historyStore.folders.first { $0.id == id }
    }

    private var bookmarkRows: [BookmarkItem] {
        guard appState.paletteSource == .bookmarks else { return [] }
        var result = historyStore.bookmarks
        if let category = historyStore.activeCategory {
            result = result.filter { $0.category == category }
        }
        if let bundleId = historyStore.activeAppBundleId {
            result = result.filter { $0.applicationBundleId == bundleId }
        }
        if !historyStore.searchQuery.isEmpty {
            result = searchService.searchBookmarks(query: historyStore.searchQuery, in: result)
        }
        return result
    }

    private var historyRows: [HistoryItem] {
        guard appState.paletteSource == .history else { return [] }
        return historyStore.displayedItems
    }

    private var isFilteringBookmarks: Bool {
        historyStore.activeCategory != nil
            || historyStore.activeAppBundleId != nil
            || !historyStore.searchQuery.isEmpty
    }

    private var bookmarkSections: [PaletteBookmarkSection] {
        let items = bookmarkRows
        if historyStore.folders.isEmpty {
            guard !items.isEmpty else { return [] }
            return [PaletteBookmarkSection(id: "bookmarks", title: "Bookmarks", folder: nil, items: items)]
        }

        var sections: [PaletteBookmarkSection] = []
        for folder in historyStore.folders {
            let folderItems = items.filter { $0.folder?.id == folder.id }
            if folderItems.isEmpty && isFilteringBookmarks { continue }
            sections.append(
                PaletteBookmarkSection(
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
                PaletteBookmarkSection(id: "unfiled", title: "Unfiled", folder: nil, items: unfiled)
            )
        }
        return sections
    }

    private var historySections: [HistoryDaySection] {
        let calendar = Calendar.current
        let extractPins = !historyStore.timeFilter.isActive
        var pinned: [HistoryItem] = []
        var buckets: [Date: [HistoryItem]] = [:]

        for item in historyRows {
            if extractPins && item.isPinned {
                pinned.append(item)
                continue
            }
            let day = calendar.startOfDay(for: item.lastCopiedAt)
            buckets[day, default: []].append(item)
        }

        var sections: [HistoryDaySection] = []
        if extractPins, Defaults[.pinPosition] == .top, !pinned.isEmpty {
            sections.append(HistoryDaySection(id: "pinned", title: "Pinned", items: pinned))
        }
        for day in buckets.keys.sorted(by: >) {
            sections.append(
                HistoryDaySection(
                    id: "day-\(Int(day.timeIntervalSince1970))",
                    title: HistoryTimeFilter.sectionTitle(for: day, calendar: calendar),
                    items: buckets[day] ?? []
                )
            )
        }
        if extractPins, Defaults[.pinPosition] == .bottom, !pinned.isEmpty {
            sections.append(HistoryDaySection(id: "pinned", title: "Pinned", items: pinned))
        }
        return sections
    }

    private var flattenedRows: [PaletteRow] {
        switch appState.paletteSource {
        case .history:
            return historySections.flatMap { $0.items.map { .history($0) } }
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

    private var isEmpty: Bool {
        switch appState.paletteSource {
        case .history:
            return historyRows.isEmpty
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
                    previewPane
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
        .onAppear { prepareForWindowPresentation() }
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
        .onChange(of: flattenedRows.map(\.id)) { _, _ in
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

            if primaryActionTitle != nil || canShowItemActions {
                footerPill { actionCapsuleContent }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .clipwordChromeBackground()
    }

    private var actionCapsuleContent: some View {
        HStack(spacing: 0) {
            if let primaryActionTitle {
                Button {
                    _ = pasteSelected()
                } label: {
                    HStack(spacing: 6) {
                        Text(primaryActionTitle)
                        PaletteKeycap(systemImage: "return")
                    }
                }
                .buttonStyle(.plain)
                .focusable(false)
                .pointingHandCursor()
                .disabled(appState.paletteSelection == nil)

                if canShowItemActions {
                    capsuleDivider
                }
            }

            if canShowItemActions {
                Button {
                    listFocused = true
                    showSelectedItemMenu()
                } label: {
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

    private var capsuleDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 12)
    }

    private var primaryActionTitle: String? {
        if let folder = selectedFolder {
            return isCollapsed(folder) ? "Expand" : "Collapse"
        }
        if selectedHistoryItem != nil || selectedBookmarkItem != nil {
            return pasteAutomatically ? "Paste" : "Copy to Clipboard"
        }
        return nil
    }

    private var canShowItemActions: Bool {
        selectedHistoryItem != nil || selectedBookmarkItem != nil
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
            AppFilterOption(bundleId: bundleId, name: appName(for: bundleId), count: count)
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
            .scrollContentBackground(.hidden)
            .background(.clear)
            .background(RefuseListFirstResponder().frame(width: 0, height: 0))
            .scrollToVisible(target: listScrollTarget, tableRow: selectedTableRow)
            .persistScrollOffset(
                store: appState.scrollStore,
                key: PaletteScrollKey.list(.history),
                restoreToken: appState.windowPresentationToken
            )
            .animation(.snappy(duration: 0.32), value: flattenedRows.map(\.id))
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
            .scrollContentBackground(.hidden)
            .background(.clear)
            .background(RefuseListFirstResponder().frame(width: 0, height: 0))
            .scrollToVisible(target: listScrollTarget, tableRow: selectedTableRow)
            .persistScrollOffset(
                store: appState.scrollStore,
                key: PaletteScrollKey.list(.bookmarks),
                restoreToken: appState.windowPresentationToken
            )
            .animation(.snappy(duration: 0.32), value: flattenedRows.map(\.id))
        }
    }

    private func historyRow(_ item: HistoryItem) -> some View {
        let selected = appState.paletteSelection == .history(item.id)
        return HistoryRowView(
            item: item,
            emphasized: selected && listFocused,
            recentlyActed: recentlyActedID == item.id
        )
        .id(PaletteRow.history(item).id)
        .keyboardListRow(selected: selected, listActive: listFocused)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.paletteSelection = .history(item.id)
            historyStore.selectedItemID = item.id
            listFocused = true
            focusSearch()
        }
        .onTapGesture(count: 2) {
            historyStore.select(item, paste: NSEvent.modifierFlags.contains(.option))
            appState.hideWindow()
        }
        .contextMenu { historyContextMenu(for: item) }
    }

    private func folderRow(_ folder: BookmarkFolder, count: Int) -> some View {
        let selected = appState.paletteSelection == .folder(folder.id)
        let collapsed = isCollapsed(folder)
        return HStack(spacing: 10) {
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
                    .foregroundStyle(selected && listFocused ? Color.white.opacity(0.75) : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected && listFocused ? Color.white : Color.primary)
        .padding(.vertical, 2)
        .id(PaletteRow.folder(folder, count: count).id)
        .keyboardListRow(selected: selected, listActive: listFocused)
        .contentShape(Rectangle())
        .onTapGesture {
            applySelection(.folder(folder, count: count), reveal: false)
            listFocused = true
            focusSearch()
        }
        .onTapGesture(count: 2) {
            toggleFolder(folder)
        }
        .contextMenu {
            Button(collapsed ? "Expand" : "Collapse") { toggleFolder(folder) }
            Button("Rename…") { beginRename(folder) }
            Button("Delete Folder", role: .destructive) {
                historyStore.deleteFolder(folder)
                appState.collapsedFolderIDs.remove(folder.id)
            }
        }
    }

    private func bookmarkRow(_ item: BookmarkItem, showFolderName: Bool = false) -> some View {
        let selected = appState.paletteSelection == .bookmark(item.id)
        return BookmarkRowView(
            item: item,
            emphasized: selected && listFocused,
            folderName: showFolderName ? item.folder?.name : nil
        )
        .id(PaletteRow.bookmark(item).id)
        .keyboardListRow(selected: selected, listActive: listFocused)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.paletteSelection = .bookmark(item.id)
            historyStore.selectedBookmarkID = item.id
            listFocused = true
            focusSearch()
        }
        .onTapGesture(count: 2) {
            historyStore.selectBookmark(item, paste: NSEvent.modifierFlags.contains(.option))
            appState.hideWindow()
        }
        .contextMenu { bookmarkContextMenu(for: item) }
    }

    @ViewBuilder
    private var previewPane: some View {
        if let item = selectedHistoryItem {
            ClipboardDetailPane(
                item: item,
                onEdit: { editingHistoryItem = item },
                onNewFolder: { beginNewFolder(assigningHistory: item) }
            )
        } else if let item = selectedBookmarkItem {
            BookmarkDetailPane(
                item: item,
                onEdit: { editingBookmarkItem = item },
                onMoveFolder: { showBookmarkFolderMenu(for: item) }
            )
        } else if let folder = selectedFolder {
            let count = bookmarkRows.filter { $0.folder?.id == folder.id }.count
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
        if preferExisting,
           let current = appState.paletteSelection,
           rows.contains(where: { $0.selection == current }) {
            return
        }
        if let first = rows.first {
            applySelection(first, reveal: false)
        } else {
            appState.paletteSelection = nil
            historyStore.selectedItemID = nil
            historyStore.selectedBookmarkID = nil
        }
    }

    private var selectedTableRow: Int? {
        tableRow(for: appState.paletteSelection)
    }

    private func tableRow(for selection: PaletteSelection?) -> Int? {
        guard let selection else { return nil }
        switch appState.paletteSource {
        case .history:
            var row = 0
            for section in historySections {
                row += 1
                for item in section.items {
                    if selection == .history(item.id) { return row }
                    row += 1
                }
            }
            return nil
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
        switch row {
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
        listRevealToken += 1
    }

    private func toggleFolder(_ folder: BookmarkFolder) {
        let collapsing = !isCollapsed(folder)
        appState.collapsedFolderIDs.formSymmetricDifference([folder.id])
        let count = bookmarkRows.filter { $0.folder?.id == folder.id }.count
        if collapsing, case .bookmark(let id) = appState.paletteSelection,
           bookmarkRows.first(where: { $0.id == id })?.folder?.id == folder.id {
            applySelection(.folder(folder, count: count))
        } else {
            applySelection(.folder(folder, count: count))
        }
        focusSearch()
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
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

        let current = appState.paletteSelection.flatMap { selection in
            rows.firstIndex { $0.selection == selection }
        } ?? 0

        if delta < 0 && current <= 0 {
            listFocused = false
            if appState.paletteSource == .bookmarks {
                focusBackButton()
            }
            return .handled
        }

        let next = min(rows.count - 1, max(0, current + delta))
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

    @ViewBuilder
    private func historyContextMenu(for item: HistoryItem) -> some View {
        Button("Copy") { historyStore.select(item, paste: false) }
            .keyboardShortcut("c")
        Button("Paste") {
            historyStore.select(item, paste: true)
            appState.hideWindow()
        }
        Button("Add to Paste Stack") { historyStore.addToPasteStack(item) }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        Divider()
        Button("Edit…") { editingHistoryItem = item }
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
                onNew: { beginNewFolder(assigningHistory: item) }
            )
        }
        Button(item.isPinned ? "Unpin" : "Pin") { historyStore.togglePin(item) }
            .keyboardShortcut("p", modifiers: .option)
        Divider()
        Button("Delete", role: .destructive) { historyStore.delete(item) }
            .keyboardShortcut(.delete, modifiers: .command)
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
        Button("Edit…") { editingBookmarkItem = item }
            .keyboardShortcut("e")
        Menu("Move to Folder") {
            BookmarkFolderPickerButtons(
                folders: historyStore.folders,
                currentFolderID: item.folder?.id,
                allowUnfiled: true,
                onPick: { historyStore.moveBookmark(item, to: $0) },
                onNew: { beginNewFolder(assigningBookmark: item) }
            )
        }
        Divider()
        Button("Remove Bookmark", role: .destructive) {
            historyStore.deleteBookmark(item)
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }

    private func showHistoryMenu(_ item: HistoryItem) {
        KeyboardContextMenu.popHistory(
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

    private func showBookmarkMenu(_ item: BookmarkItem) {
        KeyboardContextMenu.popBookmark(
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

    private func appName(for bundleId: String?) -> String {
        guard let bundleId, bundleId != "unknown" else { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId
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

private struct HistoryDaySection: Identifiable {
    let id: String
    let title: String
    let items: [HistoryItem]
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

private struct PaletteBookmarkSection: Identifiable {
    let id: String
    let title: String
    let folder: BookmarkFolder?
    let items: [BookmarkItem]
}

private enum PaletteRow: Identifiable {
    case history(HistoryItem)
    case bookmark(BookmarkItem)
    case folder(BookmarkFolder, count: Int)

    var id: String {
        switch self {
        case .history(let item): "h-\(item.id.uuidString)"
        case .bookmark(let item): "b-\(item.id.uuidString)"
        case .folder(let folder, _): "f-\(folder.id.uuidString)"
        }
    }

    var selection: PaletteSelection {
        switch self {
        case .history(let item): .history(item.id)
        case .bookmark(let item): .bookmark(item.id)
        case .folder(let folder, _): .folder(folder.id)
        }
    }

    static func historyID(_ id: UUID) -> String {
        "h-\(id.uuidString)"
    }
}
