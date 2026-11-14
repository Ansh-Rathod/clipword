import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct IgnoreSettingsView: View {
    @Default(.ignoredApps) private var ignoredApps
    @Default(.allowedAppsOnly) private var allowedAppsOnly
    @Default(.ignoredPasteboardTypes) private var ignoredPasteboardTypes
    @Default(.ignoredRegexPatterns) private var ignoredRegexPatterns

    @State private var newApp = ""
    @State private var newType = ""
    @State private var newRegex = ""
    @State private var selectedTab = 0

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
        .padding(.bottom)
    }

    private var appsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Allow listed apps only", isOn: $allowedAppsOnly)
            HStack {
                TextField("Bundle ID (e.g. com.apple.Safari)", text: $newApp)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addApp() }
                Button("Add") { addApp() }
                    .disabled(newApp.isEmpty)
                Button {
                    pickAppFromFinder()
                } label: {
                    Label("Choose App…", systemImage: "folder")
                }
                .help("Pick an app from Finder; its clipboard content will be ignored")
            }
            List {
                ForEach(ignoredApps, id: \.self) { app in
                    HStack {
                        Text(app)
                        Spacer()
                        Button("Remove", role: .destructive) { removeApp(app) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
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
                Button("Add") { addType() }
                    .disabled(newType.isEmpty)
            }
            List {
                ForEach(ignoredPasteboardTypes, id: \.self) { type in
                    HStack {
                        Text(type)
                        Spacer()
                        Button("Remove", role: .destructive) { removeType(type) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
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
                Button("Add") { addRegex() }
                    .disabled(newRegex.isEmpty)
            }
            List {
                ForEach(ignoredRegexPatterns, id: \.self) { pattern in
                    HStack {
                        Text(pattern)
                        Spacer()
                        Button("Remove", role: .destructive) { removeRegex(pattern) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private func addApp() {
        guard !newApp.isEmpty, !ignoredApps.contains(newApp) else { return }
        ignoredApps.append(newApp)
        newApp = ""
    }

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
