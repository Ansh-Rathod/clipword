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

private struct SidebarFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarFocused: Bool {
        get { self[SidebarFocusedKey.self] }
        set { self[SidebarFocusedKey.self] = newValue }
    }
}

enum ContentFocus: Hashable {
    case search, list
}

struct MainRootView: View {
    @Environment(AppState.self) private var appState
    @State private var showSidebar = true
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                    .frame(width: 180)
                    .focused($sidebarFocused)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }

            VStack(spacing: 0) {
                chromeBar
                Divider()
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.sidebarFocused, sidebarFocused)
            }
        }
        .frame(width: 700, height: 500)
        .animation(.easeInOut(duration: 0.2), value: showSidebar)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .toolbar(removing: .sidebarToggle)
        .onKeyPress(.leftArrow) {
            if appState.isSearchFocused { return .ignored }
            if !showSidebar { showSidebar = true }
            DispatchQueue.main.async { sidebarFocused = true }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard sidebarFocused else { return .ignored }
            sidebarFocused = false
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard sidebarFocused else { return .ignored }
            appState.cycleSection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard sidebarFocused else { return .ignored }
            appState.cycleSection(1)
            return .handled
        }
        .onKeyPress(.return) {
            guard sidebarFocused else { return .ignored }
            sidebarFocused = false
            return .handled
        }
        .onKeyPress(.escape) {
            if appState.isSearchFocused { return .ignored }
            if sidebarFocused {
                sidebarFocused = false
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
            .help(showSidebar ? "Hide Sidebar (← to return)" : "Show Sidebar (←)")

            Text(appState.mainSection.title)
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                appState.hideWindow()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("w", modifiers: .command)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    private func toggleSidebar() {
        showSidebar.toggle()
        if showSidebar {
            DispatchQueue.main.async { sidebarFocused = true }
        } else {
            sidebarFocused = false
        }
    }
}
