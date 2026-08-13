import SwiftUI

struct AdvancedSettingsView: View {
    @Default(.ignoreEvents) private var ignoreEvents
    @Default(.clearOnQuit) private var clearOnQuit
    @Default(.clearSystemClipboard) private var clearSystemClipboard
    @Default(.clipboardCheckInterval) private var clipboardCheckInterval
    @Default(.analyticsStopWords) private var analyticsStopWords
    @Default(.analyticsMinWordLength) private var analyticsMinWordLength
    @Default(.typingAnalyticsEnabled) private var typingAnalyticsEnabled
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Monitoring") {
                Toggle("Pause clipboard monitoring", isOn: $ignoreEvents)
                LabeledContent("Check interval") {
                    Stepper(value: $clipboardCheckInterval, in: 0.1...2, step: 0.1) {
                        Text("\(clipboardCheckInterval, specifier: "%.1f")s")
                            .monospacedDigit()
                    }
                }
            }
            Section("Clipboard") {
                Toggle("Clear history on quit", isOn: $clearOnQuit)
                Toggle("Clear system clipboard after copy", isOn: $clearSystemClipboard)
            }
            Section("Analytics") {
                Toggle("Exclude common stop words", isOn: $analyticsStopWords)
                Stepper("Minimum word length: \(analyticsMinWordLength)", value: $analyticsMinWordLength, in: 1...10)
                Toggle("Track typing (words & time)", isOn: $typingAnalyticsEnabled)
                    .onChange(of: typingAnalyticsEnabled) { _, enabled in
                        if enabled {
                            appState.typingMonitor.start()
                            if !appState.typingMonitor.isRunning {
                                typingAnalyticsEnabled = false
                            }
                        } else {
                            appState.typingMonitor.stop()
                        }
                    }
                Text("Requires Accessibility permission. Only typed words are counted separately from clipboard words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Accessibility") {
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
            }
        }
        .formStyle(.grouped)
        .padding()
        .focusSection()
    }
}

import Defaults
