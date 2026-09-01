import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Defaults
import Foundation
import Observation

/// Phase B: automatic as-you-type inline suggestions.
///
/// A global `NSEvent` keyDown monitor (observe-only) maintains the current
/// word buffer; a debounced filter over `HistoryStore.items` produces
/// suggestions that are rendered ghost-text-style at the caret via
/// `InlineSuggestionPanelController`. Accepting (Tab, consumed by
/// `InlineKeyTap`) deletes the typed prefix and pastes the full snippet.
@MainActor
final class InlineSuggestionService {
    static let shared = InlineSuggestionService()

    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var observations: [Defaults.Observation] = []
    private var debounceTask: Task<Void, Never>?
    private let panel = InlineSuggestionPanelController()
    private weak var historyStore: HistoryStore?
    private var buffer = ""
    private(set) var currentSuggestions: [HistoryItem] = []

    var isRunning = false
    var isSuggestionVisible: Bool { panel.isVisible }

    func configure(historyStore: HistoryStore) {
        self.historyStore = historyStore
        observations.append(Defaults.observe(.inlineSuggestionsEnabled) { [weak self] _ in
            Task { @MainActor in self?.syncWithPreference() }
        })
        observations.append(Defaults.observe(.inlineTriggerMode) { [weak self] _ in
            Task { @MainActor in self?.syncWithPreference() }
        })
    }

    func syncWithPreference() {
        if Defaults[.inlineSuggestionsEnabled], Defaults[.inlineTriggerMode] == .auto {
            start()
        } else {
            stop()
        }
    }

    // MARK: Lifecycle

    private func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            print("[InlineSuggestions] Accessibility permission missing — requesting")
            PasteService.requestAccessibility()
            return
        }
        print("[InlineSuggestions] running (auto mode, minChars \(Defaults[.inlineMinChars]), debounce \(Defaults[.inlineDebounceMs])ms)")

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            Task { @MainActor in
                InlineSuggestionService.shared.handleKeyDown(event)
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            Task { @MainActor in
                InlineSuggestionService.shared.dismiss()
            }
        }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
        isRunning = keyMonitor != nil
        if !isRunning {
            Defaults[.inlineTriggerMode] = .hotkey
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
        InlineKeyTap.shared.setActive(false)
        panel.hide()
        buffer = ""
        if isRunning { print("[InlineSuggestions] stopped") }
        isRunning = false
    }

    // MARK: Key handling

    private func handleKeyDown(_ event: NSEvent) {
        // Never track our own UI.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            return
        }

        switch event.keyCode {
        case 36, 48, 49: // return, tab, space end the word
            // Tab/Esc while a suggestion is visible never gets here — the
            // CGEventTap consumed it.
            dismiss()
            return
        case 51: // delete: shrink the buffer
            if !buffer.isEmpty {
                buffer.removeLast()
                scheduleRefresh()
            } else {
                dismiss()
            }
            return
        case 53: // esc (only when tap is inactive)
            dismiss()
            return
        case 125, 126: // arrows pass through untouched
            return
        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        for ch in chars {
            if ch.isLetter || ch.isNumber || "._-/'\":@#()[]{}".contains(ch) {
                buffer.append(Character(ch.lowercased()))
            } else {
                // Anything else (whitespace handled above via keyCode 49)
                // ends the word — nothing to suggest.
                dismiss()
                return
            }
        }
        scheduleRefresh()
    }

    // MARK: Matching & display

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Defaults[.inlineDebounceMs] * 1_000_000))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        guard !buffer.isEmpty, buffer.count >= Defaults[.inlineMinChars] else {
            hideSuggestion()
            return
        }
        // Never suggest in password/secure-input contexts.
        if IsSecureEventInputEnabled() {
            dismiss()
            return
        }
        guard let historyStore else { return }

        let suggestions = SuggestionMatcher.suggestions(
            for: buffer,
            in: historyStore.items,
            config: SuggestionMatcher.Config(
                minChars: Defaults[.inlineMinChars],
                maxLength: Defaults[.inlineMaxLength],
                limit: 3
            )
        )
        guard !suggestions.isEmpty else {
            hideSuggestion()
            return
        }

        currentSuggestions = suggestions
        print("[InlineSuggestions] showing \(suggestions.count) for \"\(buffer)\" → \"\(suggestions[0].displayTitle.prefix(40))\"")
        let capturedBuffer = buffer
        // NSScreen access is main-thread; capture what the AX conversion needs
        // before hopping to the background query.
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.maxY
            ?? NSScreen.main?.frame.maxY ?? 0

        Task { [weak self] in
            guard let self else { return }
            let caret = await CaretProvider.caretRect(primaryScreenHeight: primaryHeight)
            // Stale request (buffer moved on during the AX query) → drop it.
            guard self.buffer == capturedBuffer else { return }
            self.panel.show(buffer: self.buffer, suggestions: self.currentSuggestions, caretRect: caret)
            InlineKeyTap.shared.setActive(true)
        }
    }

    private func hideSuggestion() {
        InlineKeyTap.shared.setActive(false)
        panel.hide()
    }

    // MARK: Accept / dismiss

    /// Accepts the top suggestion: deletes the typed prefix in the host app and
    /// pastes the full snippet.
    func acceptTop() {
        guard let top = currentSuggestions.first else { return }
        let deleteCount = buffer.count
        dismiss()
        PasteService.insertText(top, deleteBackCount: deleteCount)
    }

    func dismiss() {
        debounceTask?.cancel()
        InlineKeyTap.shared.setActive(false)
        panel.hide()
        buffer = ""
    }
}
