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

        #if DEBUG
        let debugMenu = NSMenu()
        debugMenu.addItem(debugItem("Seed 1,500 items", action: #selector(seed1500)))
        debugMenu.addItem(debugItem("Seed 5,000 items", action: #selector(seed5000)))
        debugMenu.addItem(debugItem("Clear seeded items", action: #selector(clearSeeded)))
        debugMenu.addItem(.separator())
        debugMenu.addItem(debugItem("Run perf self-test", action: #selector(runSelfTest)))
        let debugRoot = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugRoot.image = NSImage(systemSymbolName: "ladybug", accessibilityDescription: "Debug")
        debugRoot.submenu = debugMenu
        menu.addItem(debugRoot)
        menu.addItem(.separator())
        #endif

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

    #if DEBUG
    private func debugItem(_ title: String, action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    // Debug actions run directly — no panel needed, output goes to stdout
    // (visible under run.sh) and `log stream --predicate 'subsystem ==
    // "com.clipword.app"'`.
    @objc private func seed1500() {
        guard let store = appState?.historyStore else { return }
        DebugTools.seedItems(1500, into: store)
    }

    @objc private func seed5000() {
        guard let store = appState?.historyStore else { return }
        DebugTools.seedItems(5000, into: store)
    }

    @objc private func clearSeeded() {
        guard let store = appState?.historyStore else { return }
        DebugTools.clearSeededItems(from: store)
    }

    @objc private func runSelfTest() {
        guard let appState else { return }
        let report = DebugTools.runPerfSelfTest(
            store: appState.historyStore,
            search: appState.searchService
        )
        // Also surface in-app so there's feedback without a console.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Performance self-test"
        alert.informativeText = report
        alert.runModal()
    }
    #endif

    @objc func openClipboard() { pendingMenuAction = { $0.showWindow(source: .history) } }
    @objc func openBookmarks() { pendingMenuAction = { $0.showWindow(source: .bookmarks) } }
    @objc func openSettings() { pendingMenuAction = { $0.showSettings(section: .general) } }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
