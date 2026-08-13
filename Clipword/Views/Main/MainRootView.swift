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
                    .environment(\.contentShouldTakeFocus, chromeFocus == nil)
                    .environment(\.sidebarOpenForFocus, showSidebar)
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
        .onKeyPress(.downArrow) { handleChromeArrow(.down) }
        .onKeyPress(.upArrow) { handleChromeArrow(.up) }
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

        // Sidebar: up/down change section only; right/Return enter page; left → toggle
        if current == .sidebar {
            switch direction {
            case .up:
                let all = MainSection.allCases
                if let index = all.firstIndex(of: appState.mainSection), index > 0 {
                    appState.cycleSection(-1)
                } else {
                    chromeFocus = .sidebarToggle
                }
                return .handled
            case .down:
                appState.cycleSection(1)
                return .handled
            case .right:
                enterContent()
                return .handled
            case .left:
                chromeFocus = .sidebarToggle
                return .handled
            }
        }

        // Toggle: ↓ enters sidebar only if already open, else page. Never auto-opens sidebar.
        switch (current, direction) {
        case (.sidebarToggle, .right):
            chromeFocus = .close
            return .handled
        case (.sidebarToggle, .left):
            return .handled
        case (.sidebarToggle, .down):
            if showSidebar {
                chromeFocus = .sidebar
            } else {
                enterContent()
            }
            return .handled
        case (.sidebarToggle, .up):
            return .handled
        case (.close, .left):
            chromeFocus = .sidebarToggle
            return .handled
        case (.close, .right), (.close, .down):
            enterContent()
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
            enterContent()
        }
        return .handled
    }

    private func enterContent() {
        chromeFocus = nil
        enterContentToken += 1
    }

    private func handleContentExit(_ direction: ArrowFocusExitDirection) {
        switch direction {
        case .previous:
            // Only ← from page edge enters an already-open sidebar.
            guard showSidebar else { return }
            chromeFocus = .sidebar
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
            // Opened via button — stay on toggle; user enters sidebar with ↓ or later ← from page.
            chromeFocus = .sidebarToggle
        } else if chromeFocus == .sidebar {
            chromeFocus = .sidebarToggle
        }
    }
}
