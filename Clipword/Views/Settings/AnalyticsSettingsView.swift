import Defaults
import SwiftUI

struct AnalyticsSettingsView: View {
    @Default(.analyticsStopWords) private var analyticsStopWords
    @Default(.analyticsMinWordLength) private var analyticsMinWordLength

    var body: some View {
        Form {
            Section("Word analysis") {
                Toggle("Exclude common stop words", isOn: $analyticsStopWords)
                Stepper("Minimum word length: \(analyticsMinWordLength)", value: $analyticsMinWordLength, in: 1...10)
            }
            Section("Privacy") {
                Text("All analytics are computed and stored locally on your Mac. No data leaves your device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
