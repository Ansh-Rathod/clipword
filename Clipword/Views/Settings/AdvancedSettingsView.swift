import Defaults
import SwiftUI

struct AdvancedSettingsView: View {
    @Default(.clearOnQuit) private var clearOnQuit
    @Default(.clearSystemClipboard) private var clearSystemClipboard

    var body: some View {
        Form {
            Section("Clipboard") {
                Toggle("Clear history on quit", isOn: $clearOnQuit)
                Toggle("Clear system clipboard after copy", isOn: $clearSystemClipboard)
            }
            Section("Device Access") {
                LabeledContent("Permission") {
                    if PasteService.isAccessibilityTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Request Permission") {
                            PasteService.requestAccessibility()
                        }
                    }
                }
                Text("macOS lists this as Device Control and Data Access. Clipword only asks when you press this button or paste — not on every launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
