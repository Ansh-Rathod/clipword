import AppKit
import CoreFoundation
import CoreGraphics
import Foundation

/// CGEventTap that can *consume* Tab and Esc while an inline suggestion is
/// visible — an `NSEvent` monitor can only observe, never swallow, so without
/// this the Tab would both accept the suggestion AND insert a tab character.
///
/// The tap only exists in Phase B auto mode, is created lazily on first
/// suggestion, and is flagged inactive whenever the strip hides. Requires
/// Accessibility (same permission as auto-paste).
@MainActor
final class InlineKeyTap {
    static let shared = InlineKeyTap()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?

    private var wasEnabledByUser = false

    // Callback runs on the tap thread, off main — state it reads must be
    // thread-safe, hence the lock instead of touching MainActor state.
    private static let lock = NSLock()
    private static var _active = false

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _active
    }

    /// Suggestion panel visibility. While true, Tab/Esc are consumed.
    func setActive(_ active: Bool) {
        Self.lock.lock()
        Self._active = active
        Self.lock.unlock()
        if active { enable() }
        // Keep the tap alive but passive when inactive: recreating a CFMachPort
        // per keystroke burst is wasteful, and an inactive tap is a no-op.
    }

    private func enable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }
        let callback: CGEventTapCallBack = { _, _, event, _ in
            guard InlineKeyTap.isActive else {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            switch keyCode {
            case 48: // Tab → accept the top suggestion
                Task { @MainActor in InlineSuggestionService.shared.acceptTop() }
                return nil
            case 53: // Esc → dismiss, don't let the host app see it either
                Task { @MainActor in InlineSuggestionService.shared.dismiss() }
                return nil
            default:
                return Unmanaged.passUnretained(event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: (1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: nil
        ) else {
            // Missing Accessibility permission or tap denied — suggestions
            // still work, just without Tab-accept.
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.source = source

        let thread = Thread { [weak self] in
            guard let self, let source = self.source else { return }
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "Clipword.InlineKeyTap"
        thread.stackSize = 128 * 1024
        self.thread = thread
        thread.start()
    }

    /// App-lifetime singleton: the tap is never torn down, only enabled/disabled,
    /// so no deinit cleanup is needed (Swift 6 forbids nonisolated stored-property
    /// access in deinit for @MainActor classes).
}
