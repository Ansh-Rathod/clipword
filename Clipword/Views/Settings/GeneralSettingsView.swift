import KeyboardShortcuts
import Defaults
import SwiftUI

extension KeyboardShortcuts.Name {
    static let openClipword = Self("openClipword", default: .init(.c, modifiers: [.command, .shift]))
    static let pinItem = Self("pinItem", default: .init(.p, modifiers: [.option]))
    static let bookmarkItem = Self("bookmarkItem", default: .init(.b, modifiers: [.option]))
    static let deleteItem = Self("deleteItem", default: .init(.delete, modifiers: [.option]))
}

private enum GeneralFocus: Hashable {
    case launchAtLogin, openShortcut, pinShortcut, bookmarkShortcut, deleteShortcut
    case searchMode, pasteAuto, pastePlain
}

struct GeneralSettingsView: View {
    @Default(.pasteAutomatically) private var pasteAutomatically
    @Default(.pasteWithoutFormatting) private var pasteWithoutFormatting
    @Default(.searchMode) private var searchMode
    @Default(.launchAtLogin) private var launchAtLogin
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @Environment(\.sidebarOpenForFocus) private var sidebarOpenForFocus
    @Environment(\.globalJumpToken) private var globalJumpToken
    @Environment(\.globalJumpDirection) private var globalJumpDirection
    @FocusState private var focus: GeneralFocus?

    private let order: [GeneralFocus] = [
        .launchAtLogin, .openShortcut, .pinShortcut, .bookmarkShortcut, .deleteShortcut,
        .searchMode, .pasteAuto, .pastePlain
    ]

    /// Scroll target that reveals the whole section containing `focus`: the last
    /// row of the preceding section, so the target section's header stays
    /// visible. The first section anchors to its own first row.
    private func sectionAnchor(for focus: GeneralFocus) -> GeneralFocus {
        switch focus {
        case .launchAtLogin: return .launchAtLogin
        case .openShortcut, .pinShortcut, .bookmarkShortcut, .deleteShortcut: return .launchAtLogin
        case .searchMode: return .deleteShortcut
        case .pasteAuto, .pastePlain: return .searchMode
        }
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .arrowFocus($focus, equals: .launchAtLogin)
                    .id(GeneralFocus.launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLoginHelper.setEnabled(enabled)
                    }
            }
            Section("Shortcuts") {
                LabeledContent("Open Clipword") {
                    KeyboardShortcuts.Recorder(for: .openClipword)
                }
                .arrowFocus($focus, equals: .openShortcut)
                .id(GeneralFocus.openShortcut)
                LabeledContent("Pin item") {
                    KeyboardShortcuts.Recorder(for: .pinItem)
                }
                .arrowFocus($focus, equals: .pinShortcut)
                .id(GeneralFocus.pinShortcut)
                LabeledContent("Bookmark item") {
                    KeyboardShortcuts.Recorder(for: .bookmarkItem)
                }
                .arrowFocus($focus, equals: .bookmarkShortcut)
                .id(GeneralFocus.bookmarkShortcut)
                LabeledContent("Delete item") {
                    KeyboardShortcuts.Recorder(for: .deleteItem)
                }
                .arrowFocus($focus, equals: .deleteShortcut)
                .id(GeneralFocus.deleteShortcut)
            }
            Section("Keyboard") {
                shortcutRow("← →", "Move within a row")
                shortcutRow("↑ ↓", "Move between rows / list items")
                shortcutRow("←", "To sidebar (only at page left edge, sidebar open)")
                shortcutRow("→", "From sidebar → chrome toggle · within chrome → close")
                shortcutRow("Return", "Enter page from sidebar · activate · open picker · paste from list")
                shortcutRow("Space", "Step down (on steppers)")
                shortcutRow("⌘K", "Item actions menu")
                shortcutRow("Esc", "Leave text field / to sidebar / close")
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
        }
        .formStyle(.grouped)
        .padding()
        .scrollToVisible(target: focus.map { sectionAnchor(for: $0) }, anchor: .top)
        .onAppear { if contentShouldTakeFocus { focus = order.first } }
        .onChange(of: enterToken) { _, _ in focus = order.first }
        .onChange(of: globalJumpToken) { _, _ in applyGlobalJump(globalJumpDirection) }
        .onChange(of: contentShouldTakeFocus) { _, should in if !should { focus = nil } }
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

    private func move(_ delta: Int, vertical: Bool) -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        var current = focus
        if advanceArrowFocus(&current, order: order, delta: delta, vertical: vertical) {
            focus = current
            return .handled
        }
        if vertical, delta < 0 {
            arrowFocusExit?(.chromeLeading)
        } else if !vertical, delta < 0, sidebarOpenForFocus {
            arrowFocusExit?(.previous)
        }
        return .handled
    }

    private func exitToSidebar() -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        arrowFocusExit?(.previous)
        return .handled
    }

    private func activate() -> KeyPress.Result {
        switch focus {
        case .launchAtLogin:
            launchAtLogin.toggle()
            LaunchAtLoginHelper.setEnabled(launchAtLogin)
            return .handled
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
