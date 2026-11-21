import AppKit
import Defaults
import Foundation

@MainActor
public final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    public var onNewCopy: ((NSPasteboard) -> Void)?

    public init() {}

    public func start() {
        stop()
        let interval = Defaults[.clipboardCheckInterval]
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        onNewCopy?(pasteboard)
    }
}
