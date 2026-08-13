import Defaults
import SwiftUI

private enum IgnoreFocus: Hashable {
    case allowOnly, field, add, list
}

struct IgnoreSettingsView: View {
    @Default(.ignoredApps) private var ignoredApps
    @Default(.allowedAppsOnly) private var allowedAppsOnly
    @Default(.ignoredPasteboardTypes) private var ignoredPasteboardTypes
    @Default(.ignoredRegexPatterns) private var ignoredRegexPatterns
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @Environment(\.sidebarOpenForFocus) private var sidebarOpenForFocus
    @Environment(AppState.self) private var appState

    @State private var newApp = ""
    @State private var newType = ""
    @State private var newRegex = ""
    @State private var selectedApp: String?
    @State private var selectedType: String?
    @State private var selectedRegex: String?
    @State private var selectedTab = 0
    @FocusState private var focus: IgnoreFocus?
    @FocusState private var fieldActive: Bool

    private var focusOrder: [IgnoreFocus] {
        selectedTab == 0
            ? [.allowOnly, .field, .add, .list]
            : [.field, .add, .list]
    }

    private var focusRows: [[IgnoreFocus]] {
        focusOrder.map { [$0] }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Apps", systemImage: "app.badge", value: 0) {
                appsTab
            }
            Tab("Types", systemImage: "doc.badge.gearshape", value: 1) {
                typesTab
            }
            Tab("Regex", systemImage: "text.magnifyingglass", value: 2) {
                regexTab
            }
        }
        .padding()
        .onAppear {
            if contentShouldTakeFocus { focus = focusOrder.first }
        }
        .onChange(of: enterToken) { _, _ in focus = focusOrder.first; fieldActive = false }
        .onChange(of: selectedTab) { _, _ in focus = focusOrder.first; fieldActive = false }
        .onChange(of: contentShouldTakeFocus) { _, should in
            if !should { focus = nil; fieldActive = false }
        }
        .onChange(of: fieldActive) { _, active in
            appState.isSearchFocused = active
        }
        .onKeyPress(.rightArrow) { handleArrow(.right) }
        .onKeyPress(.leftArrow) { handleArrow(.left) }
        .onKeyPress(.downArrow) { handleArrow(.down) }
        .onKeyPress(.upArrow) { handleArrow(.up) }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.space) { activate() }
        .onKeyPress(.escape) {
            if fieldActive {
                fieldActive = false
                focus = .field
                return .handled
            }
            return .ignored
        }
        .onDisappear { appState.isSearchFocused = false }
    }

    private var appsTab: some View {
        VStack(alignment: .leading) {
            Toggle("Allow listed apps only", isOn: $allowedAppsOnly)
                .arrowFocus($focus, equals: .allowOnly)
            HStack {
                TextField("Bundle ID (e.g. com.apple.Safari)", text: $newApp)
                    .onSubmit { addApp() }
                    .focused($fieldActive)
                Button("Add") { addApp() }
                    .disabled(newApp.isEmpty)
                    .arrowFocus($focus, equals: .add)
            }
            .background {
                Color.clear
                    .focusable(!fieldActive)
                    .focused($focus, equals: .field)
            }
            .modifier(ArrowFocusRingModifier(forced: focus == .field && !fieldActive))
            List(selection: $selectedApp) {
                ForEach(ignoredApps, id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Button("Remove", role: .destructive) { removeApp(app) }
                            .buttonStyle(.borderless)
                    }
                    .tag(app)
                }
            }
            .arrowFocus($focus, equals: .list)
            .onDeleteCommand {
                if let selectedApp { removeApp(selectedApp) }
            }
        }
    }

    private var typesTab: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Pasteboard type UTI", text: $newType)
                    .onSubmit { addType() }
                    .focused($fieldActive)
                Button("Add") { addType() }
                    .disabled(newType.isEmpty)
                    .arrowFocus($focus, equals: .add)
            }
            .modifier(ArrowFocusRingModifier(forced: focus == .field && !fieldActive))
            .focusable(!fieldActive)
            .focused($focus, equals: .field)
            List(selection: $selectedType) {
                ForEach(ignoredPasteboardTypes, id: \.self) { type in
                    HStack {
                        Text(type)
                        Spacer()
                        Button("Remove", role: .destructive) { removeType(type) }
                            .buttonStyle(.borderless)
                    }
                    .tag(type)
                }
            }
            .arrowFocus($focus, equals: .list)
            .onDeleteCommand {
                if let selectedType { removeType(selectedType) }
            }
        }
    }

    private var regexTab: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("Regex pattern", text: $newRegex)
                    .onSubmit { addRegex() }
                    .focused($fieldActive)
                Button("Add") { addRegex() }
                    .disabled(newRegex.isEmpty)
                    .arrowFocus($focus, equals: .add)
            }
            .modifier(ArrowFocusRingModifier(forced: focus == .field && !fieldActive))
            .focusable(!fieldActive)
            .focused($focus, equals: .field)
            List(selection: $selectedRegex) {
                ForEach(ignoredRegexPatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern)
                        Spacer()
                        Button("Remove", role: .destructive) { removeRegex(pattern) }
                            .buttonStyle(.borderless)
                    }
                    .tag(pattern)
                }
            }
            .arrowFocus($focus, equals: .list)
            .onDeleteCommand {
                if let selectedRegex { removeRegex(selectedRegex) }
            }
        }
    }

    private func handleArrow(_ direction: SpatialDirection) -> KeyPress.Result {
        guard let current = focus else { return .ignored }

        if current == .field, fieldActive {
            if direction == .left || direction == .right { return .ignored }
            fieldActive = false
        }

        if current == .list, direction == .up || direction == .down {
            moveListSelection(direction == .down ? 1 : -1)
            return .handled
        }

        let result = moveSpatialFocus(from: current, direction: direction, rows: focusRows)
        switch result {
        case .moved(let next):
            fieldActive = false
            focus = next
            return .handled
        case .listMove:
            return .handled
        case .exitPrevious:
            if direction == .up {
                fieldActive = false
                focus = nil
                arrowFocusExit?(current == focusRows.first?.first ? .chromeLeading : .chromeTrailing)
            } else if direction == .left, sidebarOpenForFocus {
                fieldActive = false
                focus = nil
                arrowFocusExit?(.previous)
            }
            return .handled
        case .exitNext:
            return .handled
        }
    }

    private func moveListSelection(_ delta: Int) {
        switch selectedTab {
        case 0:
            guard !ignoredApps.isEmpty else { return }
            let items = ignoredApps
            let index = selectedApp.flatMap { items.firstIndex(of: $0) } ?? 0
            selectedApp = items[max(0, min(items.count - 1, index + delta))]
        case 1:
            guard !ignoredPasteboardTypes.isEmpty else { return }
            let items = ignoredPasteboardTypes
            let index = selectedType.flatMap { items.firstIndex(of: $0) } ?? 0
            selectedType = items[max(0, min(items.count - 1, index + delta))]
        default:
            guard !ignoredRegexPatterns.isEmpty else { return }
            let items = ignoredRegexPatterns
            let index = selectedRegex.flatMap { items.firstIndex(of: $0) } ?? 0
            selectedRegex = items[max(0, min(items.count - 1, index + delta))]
        }
    }

    private func activate() -> KeyPress.Result {
        switch focus {
        case .allowOnly:
            allowedAppsOnly.toggle()
            return .handled
        case .field:
            fieldActive = true
            return .handled
        case .add:
            switch selectedTab {
            case 0: addApp()
            case 1: addType()
            default: addRegex()
            }
            return .handled
        case .list:
            switch selectedTab {
            case 0: if let selectedApp { removeApp(selectedApp) }
            case 1: if let selectedType { removeType(selectedType) }
            default: if let selectedRegex { removeRegex(selectedRegex) }
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func addApp() {
        guard !newApp.isEmpty, !ignoredApps.contains(newApp) else { return }
        ignoredApps.append(newApp)
        newApp = ""
    }

    private func removeApp(_ app: String) {
        ignoredApps.removeAll { $0 == app }
    }

    private func addType() {
        guard !newType.isEmpty, !ignoredPasteboardTypes.contains(newType) else { return }
        ignoredPasteboardTypes.append(newType)
        newType = ""
    }

    private func removeType(_ type: String) {
        ignoredPasteboardTypes.removeAll { $0 == type }
    }

    private func addRegex() {
        guard !newRegex.isEmpty, !ignoredRegexPatterns.contains(newRegex) else { return }
        ignoredRegexPatterns.append(newRegex)
        newRegex = ""
    }

    private func removeRegex(_ pattern: String) {
        ignoredRegexPatterns.removeAll { $0 == pattern }
    }
}
