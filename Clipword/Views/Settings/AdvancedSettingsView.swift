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
    @Environment(\.sidebarOpenForFocus) private var sidebarOpenForFocus
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

    /// Scroll target that reveals the whole section containing `focus`: the last
    /// row of the preceding section, so the target section's header stays
    /// visible. The first section anchors to its own first row.
    private func sectionAnchor(for focus: AdvancedFocus) -> AdvancedFocus {
        switch focus {
        case .pause, .interval: return .pause
        case .clearOnQuit, .clearClipboard: return .interval
        case .stopWords, .minWordLength, .typing: return .clearClipboard
        case .requestPermission: return .typing
        }
    }

    var body: some View {
        Form {
            Section("Monitoring") {
                Toggle("Pause clipboard monitoring", isOn: $ignoreEvents)
                    .arrowFocus($focus, equals: .pause)
                    .id(AdvancedFocus.pause)
                LabeledContent("Check interval") {
                    Stepper(value: $clipboardCheckInterval, in: 0.1...2, step: 0.1) {
                        Text("\(clipboardCheckInterval, specifier: "%.1f")s")
                            .monospacedDigit()
                    }
                }
                .arrowFocus($focus, equals: .interval)
                .id(AdvancedFocus.interval)
            }
            Section("Clipboard") {
                Toggle("Clear history on quit", isOn: $clearOnQuit)
                    .arrowFocus($focus, equals: .clearOnQuit)
                    .id(AdvancedFocus.clearOnQuit)
                Toggle("Clear system clipboard after copy", isOn: $clearSystemClipboard)
                    .arrowFocus($focus, equals: .clearClipboard)
                    .id(AdvancedFocus.clearClipboard)
            }
            Section("Analytics") {
                Toggle("Exclude common stop words", isOn: $analyticsStopWords)
                    .arrowFocus($focus, equals: .stopWords)
                    .id(AdvancedFocus.stopWords)
                Stepper("Minimum word length: \(analyticsMinWordLength)", value: $analyticsMinWordLength, in: 1...10)
                    .arrowFocus($focus, equals: .minWordLength)
                    .id(AdvancedFocus.minWordLength)
                Toggle("Track typing (words & time)", isOn: $typingAnalyticsEnabled)
                    .arrowFocus($focus, equals: .typing)
                    .id(AdvancedFocus.typing)
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
                        .id(AdvancedFocus.requestPermission)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .scrollToVisible(target: focus.map { sectionAnchor(for: $0) }, anchor: .top)
        .onAppear { if contentShouldTakeFocus { focus = order.first } }
        .onChange(of: enterToken) { _, _ in focus = order.first }
        .onChange(of: contentShouldTakeFocus) { _, should in if !should { focus = nil } }
        .onKeyPress(.rightArrow) { move(1, vertical: false) }
        .onKeyPress(.leftArrow) { move(-1, vertical: false) }
        .onKeyPress(.downArrow) { move(1, vertical: true) }
        .onKeyPress(.upArrow) { move(-1, vertical: true) }
        .onKeyPress(.return) { activate(delta: 1) }
        .onKeyPress(.space) { activate(delta: -1) }
        .onKeyPress(.escape) { exitToSidebar() }
    }

    private func move(_ delta: Int, vertical: Bool) -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        var current = focus
        if advanceArrowFocus(&current, order: order, delta: delta) {
            focus = current
            return .handled
        }
        if vertical, delta < 0 {
            arrowFocusExit?(.chromeLeading)
        } else if !vertical, delta < 0, sidebarOpenForFocus {
            arrowFocusExit?(.previous)
        }
        return .handled
    }

    private func exitToSidebar() -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        arrowFocusExit?(.previous)
        return .handled
    }

    private func activate(delta: Int) -> KeyPress.Result {
        switch focus {
        case .pause: ignoreEvents.toggle(); return .handled
        case .clearOnQuit: clearOnQuit.toggle(); return .handled
        case .clearClipboard: clearSystemClipboard.toggle(); return .handled
        case .stopWords: analyticsStopWords.toggle(); return .handled
        case .typing: typingAnalyticsEnabled.toggle(); return .handled
        case .interval:
            clipboardCheckInterval = min(2.0, max(0.1, clipboardCheckInterval + Double(delta) * 0.1))
            return .handled
        case .minWordLength:
            analyticsMinWordLength = min(10, max(1, analyticsMinWordLength + delta))
            return .handled
        case .requestPermission:
            PasteService.requestAccessibility()
            return .handled
        default:
            return .ignored
        }
    }
}
