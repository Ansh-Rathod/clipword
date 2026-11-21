import AppKit

/// Shared paste target for the Swift UI and the Flutter host.
/// Remember the app that was frontmost before Clipword came forward.
@MainActor
public enum PasteSession {
    public static var previousApp: NSRunningApplication?

    public static func captureFrontmost() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
    }

    /// Brings back the app that was frontmost before the popup opened.
    @discardableResult
    public static func reactivatePreviousApp() -> NSRunningApplication? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        guard let previousApp,
              !previousApp.isTerminated,
              previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        let target = previousApp
        target.activate(options: [.activateAllWindows])
        self.previousApp = nil
        return target
    }
}
