import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("Open Clipword") {
                appState.showWindow()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Divider()

            if historyStore.items.isEmpty {
                Text("No recent copies")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(historyStore.items.prefix(5)) { item in
                    Button(item.displayTitle) {
                        historyStore.select(item, paste: true)
                    }
                }
            }

            Divider()

            Button("Settings…") {
                appState.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit Clipword") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(8)
    }
}
