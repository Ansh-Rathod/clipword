import KeyboardShortcuts
import Defaults
import SwiftUI

extension KeyboardShortcuts.Name {
    static let openClipword = Self("openClipword", default: .init(.c, modifiers: [.command, .shift]))
}

struct GeneralSettingsView: View {
    @Default(.pasteAutomatically) private var pasteAutomatically
    @Default(.pasteWithoutFormatting) private var pasteWithoutFormatting
    @Default(.searchMode) private var searchMode
    @Default(.launchAtLogin) private var launchAtLogin
    @Default(.popupPosition) private var popupPosition

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        LaunchAtLoginHelper.setEnabled(enabled)
                    }
            }
            Section("Window") {
                Picker("Open at", selection: $popupPosition) {
                    ForEach(PopupPosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
            }
            Section("Shortcuts") {
                LabeledContent("Open Clipword") {
                    KeyboardShortcuts.Recorder(for: .openClipword)
                }
            }
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
    }

    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        LabeledContent(action, value: keys)
            .font(.body.monospacedDigit())
    }
}

struct SettingsRootView: View {
    @Environment(AppState.self) private var appState

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
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
