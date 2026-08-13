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
                shortcutRow("⌘1–7", "Switch section")
                shortcutRow("⌘[ ⌘]", "Previous / next section")
                shortcutRow("⌘⇧[ ⌘⇧]", "Previous / next analytics view")
                shortcutRow("⌘\\", "Toggle sidebar")
                shortcutRow("⌘F", "Search")
                shortcutRow("↑ ↓", "Move in list / sidebar")
                shortcutRow("Return", "Paste selected item")
                shortcutRow("⌘Return", "Paste and close")
                shortcutRow("⌘C", "Copy selected item")
                shortcutRow("⌘E", "Edit selected item")
                shortcutRow("⌃1–9", "Jump to clipboard item")
                shortcutRow("⌘W / Esc", "Close window")
                shortcutRow("⌘Q", "Quit")
                Text("Enable Full Keyboard Access in System Settings → Keyboard to Tab through buttons and toggles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
