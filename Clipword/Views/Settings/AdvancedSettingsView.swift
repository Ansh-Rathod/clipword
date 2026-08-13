import Defaults
import SwiftUI

private enum AdvancedFocus: Hashable {
    case pause, interval, clearOnQuit, clearClipboard
    case stopWords, minWordLength, typing, requestPermission
}

struct AdvancedSettingsView: View {
    @Default(.ignoreEvents) private var ignoreEvents
    @Default(.clearOnQuit) private var clearOnQuit
    @Default(.clearSystemClipboard) private var clearSystemClipboard
    @Default(.clipboardCheckInterval) private var clipboardCheckInterval
    @Default(.analyticsStopWords) private var analyticsStopWords
    @Default(.analyticsMinWordLength) private var analyticsMinWordLength
    @Default(.typingAnalyticsEnabled) private var typingAnalyticsEnabled
    @Environment(AppState.self) private var appState
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @FocusState private var focus: AdvancedFocus?

    private var order: [AdvancedFocus] {
        var items: [AdvancedFocus] = [
            .pause, .interval, .clearOnQuit, .clearClipboard,
            .stopWords, .minWordLength, .typing
        ]
        if !PasteService.isAccessibilityTrusted {
            items.append(.requestPermission)
        }
        return items
    }

    var body: some View {
        Form {
            Section("Monitoring") {
                Toggle("Pause clipboard monitoring", isOn: $ignoreEvents)
                    .arrowFocus($focus, equals: .pause)
                LabeledContent("Check interval") {
                    Stepper(value: $clipboardCheckInterval, in: 0.1...2, step: 0.1) {
                        Text("\(clipboardCheckInterval, specifier: "%.1f")s")
                            .monospacedDigit()
                    }
                }
                .arrowFocus($focus, equals: .interval)
            }
            Section("Clipboard") {
                Toggle("Clear history on quit", isOn: $clearOnQuit)
                    .arrowFocus($focus, equals: .clearOnQuit)
                Toggle("Clear system clipboard after copy", isOn: $clearSystemClipboard)
                    .arrowFocus($focus, equals: .clearClipboard)
            }
            Section("Analytics") {
                Toggle("Exclude common stop words", isOn: $analyticsStopWords)
                    .arrowFocus($focus, equals: .stopWords)
                Stepper("Minimum word length: \(analyticsMinWordLength)", value: $analyticsMinWordLength, in: 1...10)
                    .arrowFocus($focus, equals: .minWordLength)
                Toggle("Track typing (words & time)", isOn: $typingAnalyticsEnabled)
                    .arrowFocus($focus, equals: .typing)
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
                        .arrowFocus($focus, equals: .requestPermission)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { if contentShouldTakeFocus { focus = order.first } }
        .onChange(of: enterToken) { _, _ in focus = order.first }
        .onChange(of: contentShouldTakeFocus) { _, should in if !should { focus = nil } }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.space) { activate() }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        var current = focus
        if advanceArrowFocus(&current, order: order, delta: delta) {
            focus = current
            return .handled
        }
        focus = nil
        arrowFocusExit?(delta < 0 ? .previous : .next)
        return .handled
    }

    private func activate() -> KeyPress.Result {
        switch focus {
        case .pause: ignoreEvents.toggle(); return .handled
        case .clearOnQuit: clearOnQuit.toggle(); return .handled
        case .clearClipboard: clearSystemClipboard.toggle(); return .handled
        case .stopWords: analyticsStopWords.toggle(); return .handled
        case .typing: typingAnalyticsEnabled.toggle(); return .handled
        case .requestPermission:
            PasteService.requestAccessibility()
            return .handled
        default:
            return .ignored
        }
    }
}
