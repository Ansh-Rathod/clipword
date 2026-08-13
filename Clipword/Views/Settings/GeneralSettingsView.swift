import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let openClipword = Self("openClipword", default: .init(.c, modifiers: [.command, .shift]))
    static let pinItem = Self("pinItem", default: .init(.p, modifiers: [.option]))
    static let bookmarkItem = Self("bookmarkItem", default: .init(.b, modifiers: [.option]))
    static let deleteItem = Self("deleteItem", default: .init(.delete, modifiers: [.option]))
}

struct GeneralSettingsView: View {
    @Default(.pasteAutomatically) private var pasteAutomatically
    @Default(.pasteWithoutFormatting) private var pasteWithoutFormatting
    @Default(.searchMode) private var searchMode
    @Default(.launchAtLogin) private var launchAtLogin

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLoginHelper.setEnabled(enabled)
                    }
            }
            Section("Shortcuts") {
                LabeledContent("Open Clipword") {
                    KeyboardShortcuts.Recorder(for: .openClipword)
                }
                LabeledContent("Pin item") {
                    KeyboardShortcuts.Recorder(for: .pinItem)
                }
                LabeledContent("Bookmark item") {
                    KeyboardShortcuts.Recorder(for: .bookmarkItem)
                }
                LabeledContent("Delete item") {
                    KeyboardShortcuts.Recorder(for: .deleteItem)
                }
            }
            Section("Keyboard") {
                shortcutRow("←", "Focus sidebar")
                shortcutRow("→ / Return", "Enter section from sidebar")
                shortcutRow("↑ ↓", "Move in sidebar or list")
                shortcutRow("Return", "Paste selected item")
                shortcutRow("⌘K", "Item actions menu")
                shortcutRow("Esc", "Close window")
            }
            Section("Search") {
                Picker("Search mode", selection: $searchMode) {
                    ForEach(SearchMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }
            Section("Paste") {
                Toggle("Paste automatically", isOn: $pasteAutomatically)
                Toggle("Paste without formatting by default", isOn: $pasteWithoutFormatting)
            }
        }
        .formStyle(.grouped)
        .padding()
        .focusSection()
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        LabeledContent(action, value: keys)
            .font(.body.monospacedDigit())
    }
}

import Defaults
