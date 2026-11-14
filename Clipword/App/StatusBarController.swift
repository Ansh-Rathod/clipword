import AppKit
import Defaults
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var appState: AppState?
    /// Accessory apps often receive the waking click twice. The second one
    /// toggles the window shut, so the first menu-bar click looks ignored.
    private var lastLeftClick = Date.distantPast

    func install(appState: AppState) {
        self.appState = appState

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipword")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // mouseUp is swallowed the first time the app is inactive. mouseDown
            // is delivered, and is what actually opens the window on the first click.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            WindowManager.shared.setStatusButton(button)
        }
        statusItem = item
    }

    @objc func statusItemClicked(_ sender: Any?) {
        let type = NSApp.currentEvent?.type
        if type == .rightMouseDown || type == .rightMouseUp {
            showContextMenu()
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastLeftClick) < 0.3 { return }
        lastLeftClick = now
        appState?.toggleWindow(section: .clipboard, fromStatusItem: true)
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        let menu = buildMenu()
        statusItem?.menu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        statusItem?.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item("Clipboard", action: #selector(openClipboard), image: "doc.on.clipboard"))
        menu.addItem(item("Bookmarks", action: #selector(openBookmarks), image: "bookmark"))
        menu.addItem(item("Analytics", action: #selector(openAnalytics), image: "chart.bar"))
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        settingsMenu.autoenablesItems = false
        settingsMenu.addItem(item("General", action: #selector(openGeneral), image: "gear"))
        settingsMenu.addItem(item("Storage", action: #selector(openStorage), image: "internaldrive"))
        settingsMenu.addItem(item("Ignore", action: #selector(openIgnore), image: "eye.slash"))
        settingsMenu.addItem(item("Advanced", action: #selector(openAdvanced), image: "wrench.and.screwdriver"))
        settings.submenu = settingsMenu
        menu.addItem(settings)

        menu.addItem(.separator())

        let paused = Defaults[.ignoreEvents]
        let pauseItem = NSMenuItem(
            title: paused ? "Resume Monitoring" : "Pause Monitoring",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Clipword", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func item(_ title: String, action: Selector, image: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.image = NSImage(systemSymbolName: image, accessibilityDescription: title)
        return menuItem
    }

    @objc func openClipboard() { appState?.showWindow(section: .clipboard) }
    @objc func openBookmarks() { appState?.showWindow(section: .bookmarks) }
    @objc func openAnalytics() { appState?.showWindow(section: .analytics) }
    @objc func openGeneral() { appState?.showWindow(section: .general) }
    @objc func openStorage() { appState?.showWindow(section: .storage) }
    @objc func openIgnore() { appState?.showWindow(section: .ignore) }
    @objc func openAdvanced() { appState?.showWindow(section: .advanced) }

    @objc func togglePause() {
        Defaults[.ignoreEvents].toggle()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
