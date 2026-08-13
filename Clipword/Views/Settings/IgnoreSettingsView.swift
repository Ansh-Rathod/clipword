import SwiftUI

struct IgnoreSettingsView: View {
    @Default(.ignoredApps) private var ignoredApps
    @Default(.allowedAppsOnly) private var allowedAppsOnly
    @Default(.ignoredPasteboardTypes) private var ignoredPasteboardTypes
    @Default(.ignoredRegexPatterns) private var ignoredRegexPatterns

    @State private var newApp = ""
    @State private var newType = ""
    @State private var newRegex = ""
    @State private var selectedApp: String?
    @State private var selectedType: String?
    @State private var selectedRegex: String?

    var body: some View {
        TabView {
            Tab("Apps", systemImage: "app.badge") {
                appsTab
            }
            Tab("Types", systemImage: "doc.badge.gearshape") {
                typesTab
            }
            Tab("Regex", systemImage: "text.magnifyingglass") {
                regexTab
            }
        }
        .padding()
        .focusSection()
    }

    private var appsTab: some View {
        VStack(alignment: .leading) {
            Toggle("Allow listed apps only", isOn: $allowedAppsOnly)
            HStack {
                TextField("Bundle ID (e.g. com.apple.Safari)", text: $newApp)
                    .onSubmit { addApp() }
                Button("Add") { addApp() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newApp.isEmpty)
            }
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
                Button("Add") { addType() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newType.isEmpty)
            }
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
                Button("Add") { addRegex() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newRegex.isEmpty)
            }
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
            .onDeleteCommand {
                if let selectedRegex { removeRegex(selectedRegex) }
            }
        }
    }

    private func addApp() {
        guard !ignoredApps.contains(newApp) else { return }
        ignoredApps.append(newApp)
        newApp = ""
    }

    private func removeApp(_ app: String) {
        ignoredApps.removeAll { $0 == app }
    }

    private func addType() {
        guard !ignoredPasteboardTypes.contains(newType) else { return }
        ignoredPasteboardTypes.append(newType)
        newType = ""
    }

    private func removeType(_ type: String) {
        ignoredPasteboardTypes.removeAll { $0 == type }
    }

    private func addRegex() {
        guard !ignoredRegexPatterns.contains(newRegex) else { return }
        ignoredRegexPatterns.append(newRegex)
        newRegex = ""
    }

    private func removeRegex(_ pattern: String) {
        ignoredRegexPatterns.removeAll { $0 == pattern }
    }
}

import Defaults
