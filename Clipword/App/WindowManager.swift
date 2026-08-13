import AppKit
import SwiftUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Single floating menu-bar popup. Never activates Dock (.accessory stays).
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    static let windowSize = NSSize(width: 900, height: 600)

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<AnyView>?
    private weak var historyStore: HistoryStore?
    private weak var analyticsEngine: AnalyticsEngine?
    private weak var appState: AppState?
    private weak var statusButton: NSStatusBarButton?

    func configure(historyStore: HistoryStore, analyticsEngine: AnalyticsEngine, appState: AppState) {
        self.historyStore = historyStore
        self.analyticsEngine = analyticsEngine
        self.appState = appState
    }

    func setStatusButton(_ button: NSStatusBarButton?) {
        statusButton = button
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func toggleMainWindow(section: MainSection = .clipboard) {
        if isVisible, appState?.mainSection == section {
            hideMainWindow()
            return
        }
        if isVisible {
            appState?.mainSection = section
            return
        }
        showMainWindow(section: section)
    }

    func showMainWindow(section: MainSection = .clipboard) {
        // Stay menu-bar only — never flip to .regular (avoids Dock icon).
        NSApp.setActivationPolicy(.accessory)
        appState?.mainSection = section

        guard let historyStore, let analyticsEngine, let appState else { return }

        if panel == nil {
            let root = AnyView(
                MainRootView()
                    .environment(historyStore)
                    .environment(analyticsEngine)
                    .environment(appState)
                    .environment(appState.searchService)
                    .ignoresSafeArea()
            )
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: Self.windowSize)

            let panel = KeyablePanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .windowBackgroundColor
            panel.isOpaque = true
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.contentView = hosting
            panel.delegate = PanelDelegate.shared
            PanelDelegate.shared.manager = self

            self.panel = panel
            self.hosting = hosting
        } else if let hosting {
            hosting.rootView = AnyView(
                MainRootView()
                    .environment(historyStore)
                    .environment(analyticsEngine)
                    .environment(appState)
                    .environment(appState.searchService)
                    .ignoresSafeArea()
            )
        }

        guard let panel else { return }
        applyChrome(to: panel)
        positionNearStatusItem(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
        panel.orderFrontRegardless()

        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            self.applyChrome(to: panel)
        }
    }

    func hideMainWindow() {
        panel?.orderOut(nil)
    }

    func handlePanelClosed() {
        // Keep panel instance for reuse; just hide.
    }

    private func applyChrome(to window: NSWindow) {
        window.toolbar = nil
        window.title = ""
        window.styleMask = [.borderless, .nonactivatingPanel, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        if let closeButton = window.standardWindowButton(.closeButton),
           let titleBarContainer = closeButton.superview?.superview {
            titleBarContainer.isHidden = true
            titleBarContainer.alphaValue = 0
            titleBarContainer.frame.size.height = 0
        }
    }

    private func positionNearStatusItem(_ panel: NSPanel) {
        let size = Self.windowSize
        let frame: NSRect

        if let button = statusButton, let buttonWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRect)
            let screen = buttonWindow.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? .zero

            var x = screenRect.midX - size.width / 2
            var y = screenRect.minY - size.height - 8

            if let screen {
                x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
                if y < visible.minY {
                    y = screenRect.maxY + 8
                }
            }
            frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            frame = NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        } else {
            return
        }

        panel.setFrame(frame, display: true)
    }
}

@MainActor
private final class PanelDelegate: NSObject, NSWindowDelegate {
    static let shared = PanelDelegate()
    weak var manager: WindowManager?

    func windowDidResignKey(_ notification: Notification) {
        // Keep open when clicking into other apps; user closes via X / toggle.
    }

    func windowWillClose(_ notification: Notification) {
        manager?.handlePanelClosed()
    }

    func windowDidUpdate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.toolbar != nil { window.toolbar = nil }
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}
