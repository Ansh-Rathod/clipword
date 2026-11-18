import KeyboardShortcuts
import Defaults
import SwiftUI

extension KeyboardShortcuts.Name {
    static let openClipword = Self("openClipword", default: .init(.c, modifiers: [.command, .shift]))
}

private enum GeneralFocus: Hashable {
    case launchAtLogin, popupPosition, openShortcut, searchMode, pasteAuto, pastePlain
}

struct GeneralSettingsView: View {
    @Default(.pasteAutomatically) private var pasteAutomatically
    @Default(.pasteWithoutFormatting) private var pasteWithoutFormatting
    @Default(.searchMode) private var searchMode
    @Default(.launchAtLogin) private var launchAtLogin
    @Default(.popupPosition) private var popupPosition
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @Environment(\.globalJumpToken) private var globalJumpToken
    @Environment(\.globalJumpDirection) private var globalJumpDirection
    @FocusState private var focus: GeneralFocus?

    private let order: [GeneralFocus] = [
        .launchAtLogin, .popupPosition, .openShortcut, .searchMode, .pasteAuto, .pastePlain
    ]

    /// Last focusable row of the preceding section — scroll anchor so a focused
    /// row lower in the Form is revealed when focus lands on it.
    private func sectionAnchor(for focus: GeneralFocus) -> GeneralFocus {
        switch focus {
        case .launchAtLogin: return .launchAtLogin
        case .popupPosition: return .launchAtLogin
        case .openShortcut: return .popupPosition
        case .searchMode: return .openShortcut
        case .pasteAuto, .pastePlain: return .searchMode
        }
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLoginHelper.setEnabled(enabled)
                    }
                    .arrowFocus($focus, equals: .launchAtLogin)
                    .id(GeneralFocus.launchAtLogin)
            }
            Section("Window") {
                Picker("Open at", selection: $popupPosition) {
                    ForEach(PopupPosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                .arrowFocus($focus, equals: .popupPosition)
                .id(GeneralFocus.popupPosition)
            }
            Section("Shortcuts") {
                LabeledContent("Open Clipword") {
                    KeyboardShortcuts.Recorder(for: .openClipword)
                }
                .arrowFocus($focus, equals: .openShortcut)
                .id(GeneralFocus.openShortcut)
            }
            Section("Search") {
                Picker("Search mode", selection: $searchMode) {
                    ForEach(SearchMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .arrowFocus($focus, equals: .searchMode)
                .id(GeneralFocus.searchMode)
            }
            Section("Paste") {
                Toggle("Paste automatically", isOn: $pasteAutomatically)
                    .arrowFocus($focus, equals: .pasteAuto)
                    .id(GeneralFocus.pasteAuto)
                Toggle("Paste without formatting by default", isOn: $pasteWithoutFormatting)
                    .arrowFocus($focus, equals: .pastePlain)
                    .id(GeneralFocus.pastePlain)
            }
            // Reference-only section — kept last so ↓ never leaps across a
            // big block of non-focusable rows mid-form.
            Section("Palette") {
                shortcutRow("Type", "Search clips and bookmarks")
                shortcutRow("↓", "Move from search into the list")
                shortcutRow("↑", "Leave the list, or focus Back in bookmarks")
                shortcutRow("↑ ↓", "Move through the list")
                shortcutRow("Return", "Expand folder, or paste")
                shortcutRow("Esc", "Clear search, or close")
                shortcutRow("⌘B", "Toggle bookmarks / recent")
                shortcutRow("⌘K", "Item actions menu")
                shortcutRow("⌘,", "Open Settings")
            }
        }
        .formStyle(.grouped)
        .padding()
        .scrollToVisible(target: focus.map { sectionAnchor(for: $0) }, anchor: .center)
        .onAppear { if contentShouldTakeFocus { focus = order.first } }
        .onChange(of: enterToken) { _, _ in focus = order.first }
        .onChange(of: globalJumpToken) { _, _ in applyGlobalJump(globalJumpDirection) }
        .onChange(of: contentShouldTakeFocus) { _, should in
            if should {
                if focus == nil { focus = order.first }
            } else {
                focus = nil
            }
        }
        .onKeyPress(.rightArrow) { move(1, vertical: false) }
        .onKeyPress(.leftArrow) { move(-1, vertical: false) }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            if press.modifiers.contains(.command) {
                applyGlobalJump(press.key == .upArrow ? .up : .down)
                return .handled
            }
            return move(press.key == .upArrow ? -1 : 1, vertical: true)
        }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.space) { activate() }
        .onKeyPress(.escape) { exitToSidebar() }
    }

    /// ⌘↑/⌘↓ jump the form to its top or bottom row (works even when no row is
    /// focused, e.g. right after leaving the page).
    private func applyGlobalJump(_ direction: SpatialDirection) {
        focus = direction == .up ? order.first : order.last
    }

    /// Single-column form: ↑/↓ walk the rows; → activates the focused row
    /// (same as Return — toggles, opens pickers); ← backs out to the sidebar.
    /// Reaching either end just eats the key — no ejection, no surprise jumps.
    private func move(_ delta: Int, vertical: Bool) -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        if !vertical {
            if delta > 0 { return activate() }
            arrowFocusExit?(.previous)
            return .handled
        }
        var current = focus
        if advanceArrowFocus(&current, order: order, delta: delta) {
            focus = current
        }
        return .handled
    }

    private func exitToSidebar() -> KeyPress.Result {
        arrowFocusExit?(.previous)
        return .handled
    }

    private func activate() -> KeyPress.Result {
        switch focus {
        case .launchAtLogin:
            launchAtLogin.toggle()
            LaunchAtLoginHelper.setEnabled(launchAtLogin)
            return .handled
        case .popupPosition:
            KeyboardContextMenu.popChoices(
                title: { $0.label },
                current: popupPosition,
                choices: PopupPosition.allCases
            ) { popupPosition = $0 }
            return .handled
        case .openShortcut:
            return KeyboardNativeFocus.focusEmbeddedControl() ? .handled : .ignored
        case .searchMode:
            KeyboardContextMenu.popChoices(
                title: { $0.label },
                current: searchMode,
                choices: SearchMode.allCases
            ) { searchMode = $0 }
            return .handled
        case .pasteAuto:
            pasteAutomatically.toggle()
            return .handled
        case .pastePlain:
            pasteWithoutFormatting.toggle()
            return .handled
        default:
            return .ignored
        }
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        LabeledContent(action, value: keys)
            .font(.body.monospacedDigit())
    }
}

struct SettingsRootView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var sidebarFocused: Bool
    @State private var enterContentToken = 0
    @State private var globalJumpToken = 0
    @State private var globalJumpDirection: SpatialDirection = .down

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 0) {
            List(selection: $appState.settingsSection) {
                Section("Settings") {
                    ForEach(SettingsSection.settings) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 196)
            .scrollContentBackground(.hidden)
            .focused($sidebarFocused)

            Divider()

            Group {
                switch appState.settingsSection {
                case .general:
                    GeneralSettingsView()
                case .storage:
                    StorageSettingsView()
                case .ignore:
                    IgnoreSettingsView()
                case .advanced:
                    AdvancedSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.arrowFocusEnterToken, enterContentToken)
            .environment(\.arrowFocusEnterTarget, .listPreferred)
            .environment(\.contentShouldTakeFocus, !sidebarFocused)
            .environment(\.sidebarOpenForFocus, true)
            .environment(\.globalJumpToken, globalJumpToken)
            .environment(\.globalJumpDirection, globalJumpDirection)
            .environment(\.arrowFocusExit) { _ in sidebarFocused = true }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onKeyPress(.return) { enterContent() }
        .onKeyPress(.space) { enterContent() }
        .onKeyPress(.rightArrow) { enterContent() }
        .onKeyPress(.escape) {
            // Esc on the sidebar closes the window; Esc inside a page is the
            // page's own "back to sidebar" handler.
            guard sidebarFocused else { return .ignored }
            appState.closeSettings()
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            // Plain arrows stay with the sidebar list; ⌘ jumps the page.
            guard press.modifiers.contains(.command) else { return .ignored }
            globalJumpDirection = press.key == .upArrow ? .up : .down
            globalJumpToken += 1
            return .handled
        }
    }

    private func enterContent() -> KeyPress.Result {
        guard sidebarFocused else { return .ignored }
        #if DEBUG
        DebugTools.settingsLog("[root] enterContent section=\(appState.settingsSection)")
        #endif
        sidebarFocused = false
        enterContentToken += 1
        return .handled
    }
}
