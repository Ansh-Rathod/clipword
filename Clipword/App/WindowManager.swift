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
    static let cornerRadius: CGFloat = 16

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<AnyView>?
    private weak var historyStore: HistoryStore?
    private weak var analyticsEngine: AnalyticsEngine?
    private weak var appState: AppState?
    private weak var statusButton: NSStatusBarButton?
    private var resignObserver: NSObjectProtocol?

    func configure(historyStore: HistoryStore, analyticsEngine: AnalyticsEngine, appState: AppState) {
        self.historyStore = historyStore
        self.analyticsEngine = analyticsEngine
        self.appState = appState
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.hideMainWindow()
                }
            }
        }
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
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = Self.cornerRadius
            hosting.layer?.cornerCurve = .continuous
            hosting.layer?.masksToBounds = true

            let panel = KeyablePanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            // false so buttons keep pointing-hand cursor / hit testing
            panel.isMovableByWindowBackground = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = true
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
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hidesOnDeactivate = true
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        if let content = window.contentView {
            content.wantsLayer = true
            content.layer?.cornerRadius = Self.cornerRadius
            content.layer?.cornerCurve = .continuous
            content.layer?.masksToBounds = true
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
        guard let window = notification.object as? NSWindow else { return }
        // Defer so sheets attached to this panel can become key first.
        DispatchQueue.main.async { [weak self] in
            if window.attachedSheet != nil { return }
            if let key = NSApp.keyWindow, key.sheetParent === window { return }
            self?.manager?.hideMainWindow()
        }
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
