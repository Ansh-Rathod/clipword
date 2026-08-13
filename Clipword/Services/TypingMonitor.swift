import ApplicationServices
import AppKit
import Defaults
import Foundation
import Observation

/// Opt-in global key monitor for typed-word + typing-time analytics.
@Observable
@MainActor
final class TypingMonitor {
    private var monitor: Any?
    private var buffer = ""
    private var lastKeyAt: Date?
    private var sessionStartedAt: Date?
    private weak var analyticsEngine: AnalyticsEngine?

    private let idleGap: TimeInterval = 2.0
    private let flushInterval: TimeInterval = 5.0
    private var flushTimer: Timer?

    var isRunning = false

    func configure(analyticsEngine: AnalyticsEngine) {
        self.analyticsEngine = analyticsEngine
    }

    func syncWithPreference() {
        if Defaults[.typingAnalyticsEnabled] {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            PasteService.requestAccessibility()
            Defaults[.typingAnalyticsEnabled] = false
            return
        }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
        isRunning = monitor != nil
        guard isRunning else {
            Defaults[.typingAnalyticsEnabled] = false
            return
        }

        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flushTypingTime()
            }
        }
    }

    func stop() {
        flushWordBuffer()
        flushTypingTime()
        flushTimer?.invalidate()
        flushTimer = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRunning = false
        buffer = ""
        lastKeyAt = nil
        sessionStartedAt = nil
    }

    private func handle(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            return
        }

        let now = Date.now
        if let last = lastKeyAt, now.timeIntervalSince(last) > idleGap {
            flushWordBuffer()
            flushTypingTime()
            sessionStartedAt = now
        } else if sessionStartedAt == nil {
            sessionStartedAt = now
        }
        lastKeyAt = now

        switch event.keyCode {
        case 36, 48, 49: // return, tab, space
            flushWordBuffer()
            return
        case 51: // delete
            if !buffer.isEmpty { buffer.removeLast() }
            return
        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        for ch in chars {
            if ch.isLetter || ch.isNumber || ch == "'" {
                buffer.append(ch.lowercased())
            } else if ch.isWhitespace || ch.isPunctuation {
                flushWordBuffer()
            }
        }
    }

    private func flushWordBuffer() {
        let word = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard word.count >= Defaults[.analyticsMinWordLength] else { return }
        if Defaults[.analyticsStopWords], TextAnalytics.isStopWord(word) {
            return
        }
        analyticsEngine?.recordTypedWord(word)
    }

    private func flushTypingTime() {
        guard let started = sessionStartedAt, let last = lastKeyAt else { return }
        let seconds = last.timeIntervalSince(started)
        sessionStartedAt = lastKeyAt
        guard seconds > 0 else { return }
        analyticsEngine?.recordTypingSeconds(seconds)
    }
}
