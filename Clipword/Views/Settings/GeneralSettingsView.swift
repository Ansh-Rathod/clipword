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
    @FocusState private var focus: GeneralFocus?

    private let order: [GeneralFocus] = [
        .launchAtLogin, .openShortcut, .pinShortcut, .bookmarkShortcut, .deleteShortcut,
        .searchMode, .pasteAuto, .pastePlain
    ]

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .arrowFocus($focus, equals: .launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLoginHelper.setEnabled(enabled)
                    }
            }
            Section("Shortcuts") {
                LabeledContent("Open Clipword") {
                    KeyboardShortcuts.Recorder(for: .openClipword)
                }
                .arrowFocus($focus, equals: .openShortcut)
                LabeledContent("Pin item") {
                    KeyboardShortcuts.Recorder(for: .pinItem)
                }
                .arrowFocus($focus, equals: .pinShortcut)
                LabeledContent("Bookmark item") {
                    KeyboardShortcuts.Recorder(for: .bookmarkItem)
                }
                .arrowFocus($focus, equals: .bookmarkShortcut)
                LabeledContent("Delete item") {
                    KeyboardShortcuts.Recorder(for: .deleteItem)
                }
                .arrowFocus($focus, equals: .deleteShortcut)
            }
            Section("Keyboard") {
                shortcutRow("← →", "Move within a row")
                shortcutRow("↑ ↓", "Move between rows / list items")
                shortcutRow("←", "To sidebar (only at page left edge, sidebar open)")
                shortcutRow("→ / Return", "Enter page from sidebar")
                shortcutRow("Return", "Activate · edit text field · paste from list")
                shortcutRow("⌘K", "Item actions menu")
                shortcutRow("Esc", "Leave text field / close")
            }
            Section("Search") {
                Picker("Search mode", selection: $searchMode) {
                    ForEach(SearchMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .arrowFocus($focus, equals: .searchMode)
            }
            Section("Paste") {
                Toggle("Paste automatically", isOn: $pasteAutomatically)
                    .arrowFocus($focus, equals: .pasteAuto)
                Toggle("Paste without formatting by default", isOn: $pasteWithoutFormatting)
                    .arrowFocus($focus, equals: .pastePlain)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { if contentShouldTakeFocus { focus = order.first } }
        .onChange(of: enterToken) { _, _ in focus = order.first }
        .onChange(of: contentShouldTakeFocus) { _, should in if !should { focus = nil } }
        .onKeyPress(.rightArrow) { move(1, vertical: false) }
        .onKeyPress(.leftArrow) { move(-1, vertical: false) }
        .onKeyPress(.downArrow) { move(1, vertical: true) }
        .onKeyPress(.upArrow) { move(-1, vertical: true) }
        .onKeyPress(.return) { toggleIfNeeded() }
        .onKeyPress(.space) { toggleIfNeeded() }
    }

    private func move(_ delta: Int, vertical: Bool) -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        var current = focus
        if advanceArrowFocus(&current, order: order, delta: delta, vertical: vertical) {
            focus = current
            return .handled
        }
        if vertical, delta < 0 {
            focus = nil
            arrowFocusExit?(.chromeLeading)
        } else if !vertical, delta < 0, sidebarOpenForFocus {
            focus = nil
            arrowFocusExit?(.previous)
        }
        return .handled
    }

    private func toggleIfNeeded() -> KeyPress.Result {
        switch focus {
        case .launchAtLogin:
            launchAtLogin.toggle()
            LaunchAtLoginHelper.setEnabled(launchAtLogin)
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
