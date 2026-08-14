import AppKit
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case clipboard, bookmarks, analytics, general, storage, ignore, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .bookmarks: "Bookmarks"
        case .analytics: "Analytics"
        case .general: "General"
        case .storage: "Storage"
        case .ignore: "Ignore"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .bookmarks: "bookmark"
        case .analytics: "chart.bar"
        case .general: "gear"
        case .storage: "internaldrive"
        case .ignore: "eye.slash"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    static let primary: [MainSection] = [.clipboard, .bookmarks, .analytics]
    static let settings: [MainSection] = [.general, .storage, .ignore, .advanced]
}

private enum ChromeFocus: Hashable {
    case sidebarToggle, close, sidebar
}

struct MainRootView: View {
    @Environment(AppState.self) private var appState
    @State private var showSidebar = false
    @FocusState private var chromeFocus: ChromeFocus?
    @State private var enterContentToken = 0
    @State private var enterContentTarget: ArrowFocusEnterTarget = .listPreferred
    @State private var globalJumpToken = 0
    @State private var globalJumpDirection: SpatialDirection = .down

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                    .frame(width: 180)
                    .arrowFocus($chromeFocus, equals: .sidebar)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }

            VStack(spacing: 0) {
                chromeBar
                Divider()
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.arrowFocusEnterToken, enterContentToken)
                    .environment(\.arrowFocusEnterTarget, enterContentTarget)
                    .environment(\.contentShouldTakeFocus, chromeFocus == nil)
                    .environment(\.sidebarOpenForFocus, showSidebar)
                    .environment(\.globalJumpToken, globalJumpToken)
                    .environment(\.globalJumpDirection, globalJumpDirection)
                    .environment(\.arrowFocusExit) { direction in
                        handleContentExit(direction)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: showSidebar)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onKeyPress(.rightArrow) { handleChromeArrow(.right) }
        .onKeyPress(.leftArrow) { handleChromeArrow(.left) }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            let direction: SpatialDirection = press.key == .upArrow ? .up : .down
            if press.modifiers.contains(.command) {
                return handleGlobalJump(direction)
            }
            return handleChromeArrow(direction)
        }
        .onKeyPress(.return) { activateChrome() }
        .onKeyPress(.space) { activateChrome() }
        .onKeyPress(.escape) {
            if appState.isSearchFocused { return .ignored }
            if chromeFocus == .sidebar {
                chromeFocus = .sidebarToggle
                return .handled
            }
            appState.hideWindow()
            return .handled
        }
        .background {
            Button("Quit Clipword") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .onAppear { resetForWindowPresentation() }
        .onChange(of: appState.windowPresentationToken) { _, _ in
            resetForWindowPresentation()
        }
    }

    private func resetForWindowPresentation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showSidebar = false
        }
        chromeFocus = nil
        enterContentTarget = .listPreferred
        DispatchQueue.main.async {
            enterContentToken += 1
        }
    }

    private var chromeBar: some View {
        HStack(spacing: 8) {
            Button {
                toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .arrowFocus($chromeFocus, equals: .sidebarToggle)
            .pointingHandCursor()
            .help(showSidebar ? "Hide Sidebar" : "Show Sidebar")

            Text(appState.mainSection.title)
                .font(.headline)
                .foregroundStyle(.secondary)

            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            Button {
                appState.hideWindow()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .arrowFocus($chromeFocus, equals: .close)
            .pointingHandCursor()
            .keyboardShortcut("w", modifiers: .command)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background)
    }

    private var sidebar: some View {
        @Bindable var appState = appState
        return List(selection: $appState.mainSection) {
            Section {
                ForEach(MainSection.primary) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            Section("Settings") {
                ForEach(MainSection.settings) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .toolbar(.hidden)
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.mainSection {
        case .clipboard:
            ClipboardPopupView()
        case .bookmarks:
            BookmarksView()
        case .general:
            GeneralSettingsView()
        case .storage:
            StorageSettingsView()
        case .ignore:
            IgnoreSettingsView()
        case .advanced:
            AdvancedSettingsView()
        case .analytics:
            AnalyticsRootView()
        }
    }

    private func handleChromeArrow(_ direction: SpatialDirection) -> KeyPress.Result {
        guard let current = chromeFocus else { return .ignored }

        // Sidebar column: ↑↓ cycle sections; → chrome toggle; ← noop
        if current == .sidebar {
            switch direction {
            case .up:
                let all = MainSection.allCases
                if let index = all.firstIndex(of: appState.mainSection), index > 0 {
                    appState.cycleSection(-1)
                }
                return .handled
            case .down:
                appState.cycleSection(1)
                return .handled
            case .right:
                chromeFocus = .sidebarToggle
                return .handled
            case .left:
                return .handled
            }
        }

        switch (current, direction) {
        case (.sidebarToggle, .right):
            chromeFocus = .close
            return .handled
        case (.sidebarToggle, .left):
            if showSidebar { chromeFocus = .sidebar }
            return .handled
        case (.sidebarToggle, .down):
            enterContent(.toolbarLeading)
            return .handled
        case (.sidebarToggle, .up):
            return .handled
        case (.close, .left):
            chromeFocus = .sidebarToggle
            return .handled
        case (.close, .right):
            return .handled
        case (.close, .down):
            enterContent(.toolbarTrailing)
            return .handled
        case (.close, .up):
            return .handled
        default:
            return .ignored
        }
    }

    private func activateChrome() -> KeyPress.Result {
        guard let current = chromeFocus else { return .ignored }
        switch current {
        case .sidebarToggle:
            toggleSidebar()
        case .close:
            appState.hideWindow()
        case .sidebar:
            enterContent(.listPreferred)
        }
        return .handled
    }

    /// ⌘↑/⌘↓ from any context (sidebar, chrome bar, or a page that didn't
    /// consume the key) moves the current list/form to its top or bottom.
    private func handleGlobalJump(_ direction: SpatialDirection) -> KeyPress.Result {
        // While typing in search, ⌘↑/⌘↓ stays text navigation.
        if appState.isSearchFocused { return .ignored }

        // Sidebar column focused: jump the section list to its top/bottom.
        if chromeFocus == .sidebar {
            jumpSidebarSelection(direction)
            return .handled
        }

        // Chrome bar (toggle/close) focused: with the sidebar open, jump its
        // sections; otherwise enter content and ask the page to jump.
        if chromeFocus != nil {
            if showSidebar {
                chromeFocus = .sidebar
                jumpSidebarSelection(direction)
            } else {
                enterContent(.listPreferred)
                requestContentJump(direction)
            }
            return .handled
        }

        // Content focused but nothing consumed the key (e.g. page focus was
        // cleared): let the page's observer apply the jump.
        requestContentJump(direction)
        return .handled
    }

    private func jumpSidebarSelection(_ direction: SpatialDirection) {
        let sections = MainSection.allCases
        appState.mainSection = direction == .up ? sections.first! : sections.last!
    }

    private func requestContentJump(_ direction: SpatialDirection) {
        globalJumpDirection = direction
        globalJumpToken += 1
    }

    private func enterContent(_ target: ArrowFocusEnterTarget = .listPreferred) {
        enterContentTarget = target
        chromeFocus = nil
        enterContentToken += 1
    }

    private func handleContentExit(_ direction: ArrowFocusExitDirection) {
        switch direction {
        case .previous:
            // Esc from a page (or ← at left edge): highlight the sidebar, or its toggle when hidden.
            chromeFocus = showSidebar ? .sidebar : .sidebarToggle
        case .chromeLeading:
            chromeFocus = .sidebarToggle
        case .chromeTrailing:
            chromeFocus = .close
        case .next:
            break
        }
    }

    private func toggleSidebar() {
        showSidebar.toggle()
        if showSidebar {
            // Opened via button — stay on toggle; ← enters sidebar when open.
            chromeFocus = .sidebarToggle
        } else if chromeFocus == .sidebar {
            chromeFocus = .sidebarToggle
        }
    }
}
