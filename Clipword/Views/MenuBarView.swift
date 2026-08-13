import AppKit
import Defaults
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("Open Clipword") {
                appState.showWindow(section: .clipboard)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button("Analytics…") {
                appState.showWindow(section: .analytics)
            }

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
                appState.showWindow(section: .general)
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Pause Monitoring") {
                Defaults[.ignoreEvents].toggle()
            }

            Button("Ignore Next Copy") {
                Defaults[.ignoreNextEvent] = true
            }

            Divider()

            Button("Quit Clipword") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(8)
    }
}
