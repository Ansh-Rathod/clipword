import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func awakeFromNib() {
        isRestorable = false
        orderOut(nil)

        let flutterViewController = FlutterViewController()
        flutterViewController.view.wantsLayer = true
        flutterViewController.view.layer?.backgroundColor = NSColor.clear.cgColor
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: false)
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true

        RegisterGeneratedPlugins(registry: flutterViewController)
        ClipwordHost.shared.attach(window: self, messenger: flutterViewController.engine.binaryMessenger)

        super.awakeFromNib()
        orderOut(nil)
    }
}
