import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

private enum IgnoreFocus: Hashable {
    case tabs, allowOnly, field, add, pick, list
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
    @Environment(\.globalJumpToken) private var globalJumpToken
    @Environment(\.globalJumpDirection) private var globalJumpDirection
    @Environment(AppState.self) private var appState

    @State private var newApp = ""
    @State private var newType = ""
    @State private var newRegex = ""
    @State private var selectedApp: String?
    @State private var selectedType: String?
    @State private var selectedRegex: String?
    @State private var appListScrollTarget: String?
    @State private var typeListScrollTarget: String?
    @State private var regexListScrollTarget: String?
    @State private var selectedTab = 0
    @FocusState private var focus: IgnoreFocus?
    @FocusState private var fieldActive: Bool

    private var focusOrder: [IgnoreFocus] {
        var items: [IgnoreFocus] = [.tabs]
        if selectedTab == 0 { items.append(.allowOnly) }
        items.append(.field)
        items.append(.add)
        if selectedTab == 0 { items.append(.pick) }
        items.append(.list)
        return items
    }

    /// Spatial grid: the segmented tab picker is one focus slot; the
    /// field/add/(pick) row moves horizontally, the list is the last row.
    private var focusRows: [[IgnoreFocus]] {
        let controls: [IgnoreFocus] = selectedTab == 0
            ? [.field, .add, .pick]
            : [.field, .add]
        if selectedTab == 0 {
            return [[.tabs], [.allowOnly], controls, [.list]]
        }
        return [[.tabs], controls, [.list]]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Ignore", selection: $selectedTab) {
                Text("Apps").tag(0)
                Text("Types").tag(1)
                Text("Regex").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .arrowFocus($focus, equals: .tabs)

            Divider()

            Group {
                switch selectedTab {
                case 0: appsTab
                case 1: typesTab
                default: regexTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // The `.field` focus slot lives OUTSIDE the per-tab `Group` — a sink
        // inside the conditional content loses its registration for one
        // transaction after a tab switch, silently dropping `focus = .field`.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(width: 1, height: 1)
                .contentShape(Rectangle())
                .focusable(!fieldActive)
                .focusEffectDisabled()
                .focused($focus, equals: .field)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .padding(.bottom)
        .onAppear {
            if contentShouldTakeFocus { focus = focusOrder.first }
        }
        .onChange(of: enterToken) { _, _ in focus = focusOrder.first; fieldActive = false }
        .onChange(of: selectedTab) { _, _ in
            fieldActive = false
            // Only re-home focus when the focused control doesn't exist on the
            // new tab (e.g. .allowOnly/.pick are Apps-tab-only). Fires deferred,
            // so it must not clobber focus a later arrow press already moved.
            if let f = focus, !focusRows.contains(where: { $0.contains(f) }) {
                focus = .tabs
            }
            #if DEBUG
            DebugTools.settingsLog("[ignore] tabChanged tab=\(selectedTab) focus=\(String(describing: focus))")
            #endif
        }
        .onChange(of: globalJumpToken) { _, _ in applyGlobalJump(globalJumpDirection) }
        .onChange(of: contentShouldTakeFocus) { _, should in
            if should {
                if focus == nil { focus = focusOrder.first }
            } else {
                focus = nil
                fieldActive = false
            }
        }
        .onChange(of: fieldActive) { _, active in
            appState.isSearchFocused = active
        }
        #if DEBUG
        .onChange(of: focus) { old, new in
            DebugTools.settingsLog("[ignore] focusChanged \(String(describing: old)) → \(String(describing: new))")
        }
        #endif
        .onKeyPress(.rightArrow) { handleArrow(.right) }
        .onKeyPress(.leftArrow) { handleArrow(.left) }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            handleArrow(press.key == .upArrow ? .up : .down, modifiers: press.modifiers)
        }
        .onKeyPress(.return) {
            // Editing a field: Return must reach the TextField's onSubmit —
            // swallowing it here made typed content impossible to commit.
            if fieldActive { return .ignored }
            return activate()
        }
        .onKeyPress(.space) {
            // Editing a field: space is a character, not an activation.
            if fieldActive { return .ignored }
            return activate()
        }
        .onKeyPress(.escape) {
            if fieldActive {
                fieldActive = false
                focus = .field
                return .handled
            }
            // Esc → back to the sidebar (even when focus was lost, e.g. a
            // focus target vanished; exiting is a no-op if we're not focused).
            arrowFocusExit?(.previous)
            return .handled
        }
        .onDisappear { appState.isSearchFocused = false }
    }

    private var appsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Allow listed apps only", isOn: $allowedAppsOnly)
                .arrowFocus($focus, equals: .allowOnly)
            HStack {
                TextField("Bundle ID (e.g. com.apple.Safari)", text: $newApp)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addApp() }
                    .focused($fieldActive)
                Button("Add") { addApp() }
                    .disabled(newApp.isEmpty)
                    .arrowFocus($focus, equals: .add)
                Button {
                    pickAppFromFinder()
                } label: {
                    Label("Choose App…", systemImage: "folder")
                }
                .help("Pick an app from Finder; its clipboard content will be ignored")
                .arrowFocus($focus, equals: .pick)
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
            .listStyle(.inset)
            .arrowFocus($focus, equals: .list)
            .scrollToVisible(target: appListScrollTarget)
            .onDeleteCommand {
                if let selectedApp { removeApp(selectedApp) }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private var typesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Pasteboard type UTI", text: $newType)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addType() }
                    .focused($fieldActive)
                Button("Add") { addType() }
                    .disabled(newType.isEmpty)
                    .arrowFocus($focus, equals: .add)
            }
            .modifier(ArrowFocusRingModifier(forced: focus == .field && !fieldActive))
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
            .listStyle(.inset)
            .arrowFocus($focus, equals: .list)
            .scrollToVisible(target: typeListScrollTarget)
            .onDeleteCommand {
                if let selectedType { removeType(selectedType) }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private var regexTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Regex pattern", text: $newRegex)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addRegex() }
                    .focused($fieldActive)
                Button("Add") { addRegex() }
                    .disabled(newRegex.isEmpty)
                    .arrowFocus($focus, equals: .add)
            }
            .modifier(ArrowFocusRingModifier(forced: focus == .field && !fieldActive))
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
            .listStyle(.inset)
            .arrowFocus($focus, equals: .list)
            .scrollToVisible(target: regexListScrollTarget)
            .onDeleteCommand {
                if let selectedRegex { removeRegex(selectedRegex) }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    /// ⌘↑/⌘↓ jump the current tab's list to its top/bottom item (or, when the
    /// list is empty, the first/last focusable control). Works even when no
    /// control is focused.
    private func applyGlobalJump(_ direction: SpatialDirection) {
        let hasItems: Bool
        switch selectedTab {
        case 0: hasItems = !ignoredApps.isEmpty
        case 1: hasItems = !ignoredPasteboardTypes.isEmpty
        default: hasItems = !ignoredRegexPatterns.isEmpty
        }
        guard hasItems else {
            focus = direction == .up ? focusOrder.first : focusOrder.last
            return
        }
        focus = .list
        moveListSelection(direction == .up ? -10_000 : 10_000)
    }

    private func handleArrow(_ direction: SpatialDirection, modifiers: EventModifiers = []) -> KeyPress.Result {
        #if DEBUG
        DebugTools.settingsLog("[ignore] arrow dir=\(direction) focus=\(String(describing: focus)) tab=\(selectedTab) fieldActive=\(fieldActive)")
        #endif
        // ⌘↑/⌘↓ jump to the top/bottom item from anywhere in the view (unless
        // the text field is being edited, where they're text-navigation).
        if (direction == .up || direction == .down), modifiers.contains(.command),
           !fieldActive {
            applyGlobalJump(direction)
            return .handled
        }

        // Editing a field: ←/→ are caret keys; ↑/↓ commit-and-exit, then
        // continue moving from the field row. (`focus` is nil while the real
        // field editor holds first responder.)
        if fieldActive {
            if direction == .left || direction == .right { return .ignored }
            fieldActive = false
            focus = .field
        }

        guard let current = focus else { return .ignored }

        // ←/→ while the segmented tab picker is highlighted flips tabs —
        // that *is* its activation, matching the form pages' "right = deeper".
        if current == .tabs, direction == .left || direction == .right {
            let next = selectedTab + (direction == .right ? 1 : -1)
            if (0...2).contains(next) {
                selectedTab = next
                return .handled
            }
        }

        if current == .list, direction == .up || direction == .down {
            moveListSelection(direction == .down ? 1 : -1)
            return .handled
        }

        // Same model as the form pages: ↑/↓ walk the row order, → activates
        // the focused control, ← backs out to the sidebar.
        switch direction {
        case .up, .down:
            guard let idx = focusOrder.firstIndex(of: current) else { return .handled }
            let next = idx + (direction == .down ? 1 : -1)
            guard focusOrder.indices.contains(next) else { return .handled }
            fieldActive = false
            focus = focusOrder[next]
            #if DEBUG
            DebugTools.settingsLog("[ignore] moved → \(focusOrder[next])")
            #endif
            return .handled
        case .right:
            return activate()
        case .left:
            if sidebarOpenForFocus {
                fieldActive = false
                arrowFocusExit?(.previous)
            }
            return .handled
        }
    }

    private func moveListSelection(_ delta: Int) {
        switch selectedTab {
        case 0:
            guard !ignoredApps.isEmpty else { return }
            let items = ignoredApps
            let index = selectedApp.flatMap { items.firstIndex(of: $0) } ?? 0
            let next = items[max(0, min(items.count - 1, index + delta))]
            selectedApp = next
            appListScrollTarget = next
        case 1:
            guard !ignoredPasteboardTypes.isEmpty else { return }
            let items = ignoredPasteboardTypes
            let index = selectedType.flatMap { items.firstIndex(of: $0) } ?? 0
            let next = items[max(0, min(items.count - 1, index + delta))]
            selectedType = next
            typeListScrollTarget = next
        default:
            guard !ignoredRegexPatterns.isEmpty else { return }
            let items = ignoredRegexPatterns
            let index = selectedRegex.flatMap { items.firstIndex(of: $0) } ?? 0
            let next = items[max(0, min(items.count - 1, index + delta))]
            selectedRegex = next
            regexListScrollTarget = next
        }
    }

    private func activate() -> KeyPress.Result {
        #if DEBUG
        DebugTools.settingsLog("[ignore] activate focus=\(String(describing: focus)) tab=\(selectedTab) fieldActive=\(fieldActive)")
        #endif
        switch focus {
        case .tabs:
            // Tab switching is handled by ←/→; Return just confirms the slot.
            return .handled
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
        case .pick:
            pickAppFromFinder()
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

    /// Opens a Finder picker so the user can choose an app (or apps) whose
    /// clipboard content should be ignored. Adds each chosen app's bundle ID.
    private func pickAppFromFinder() {
        let panel = NSOpenPanel()
        panel.title = "Choose App to Ignore"
        panel.message = "Clipword will ignore clipboard content copied from the selected app(s)."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else { continue }
            if !ignoredApps.contains(bundleId) {
                ignoredApps.append(bundleId)
            }
        }
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
