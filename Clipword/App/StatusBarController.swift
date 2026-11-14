import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var appState: AppState?
    /// Accessory apps often receive the waking click twice. The second one
    /// toggles the window shut, so the first menu-bar click looks ignored.
    private var lastLeftClick = Date.distantPast
    /// Item actions run inside the menu's tracking loop. Showing a panel there
    /// is discarded when the menu closes, so the action is stored and run after.
    private var pendingMenuAction: ((AppState) -> Void)?

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
        // Same toggle as the global shortcut, including where the panel opens.
        appState?.toggleWindow()
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        let menu = buildMenu()
        statusItem?.menu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        statusItem?.menu = nil

        let action = pendingMenuAction
        pendingMenuAction = nil
        guard let action else { return }
        // Tracking has ended. Present on the next turn so the menu's resign
        // is already done, then use the same path as the global shortcut.
        DispatchQueue.main.async { [weak self] in
            guard let appState = self?.appState else { return }
            action(appState)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item("Clipboard", action: #selector(openClipboard), image: "doc.on.clipboard"))
        menu.addItem(item("Bookmarks", action: #selector(openBookmarks), image: "bookmark"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(openSettings), image: "gear"))
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

    @objc func openClipboard() { pendingMenuAction = { $0.showWindow(source: .history) } }
    @objc func openBookmarks() { pendingMenuAction = { $0.showWindow(source: .bookmarks) } }
    @objc func openSettings() { pendingMenuAction = { $0.showSettings(section: .general) } }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
