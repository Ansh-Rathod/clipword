import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        super.applicationDidFinishLaunching(notification)
        ClipwordHost.shared.stripAppMenuKeyEquivalents()
        mainFlutterWindow?.orderOut(nil)
        ClipwordHost.shared.hidePalette()
    }

    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ClipwordHost.shared.focusSettingsIfOpen() {
            return false
        }
        ClipwordHost.shared.togglePalette()
        return false
    }
}
