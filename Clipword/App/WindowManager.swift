import AppKit
import Defaults
import SwiftUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Floating Raycast-style palette plus a separate mouse-driven settings window.
/// Never activates Dock (.accessory stays).
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    static let windowSize = NSSize(width: 720, height: 520)
    static let settingsWindowSize = NSSize(width: 820, height: 580)
    static let cornerRadius: CGFloat = LiquidGlassMetrics.panelRadius

    private var panel: KeyablePanel?
    private var hosting: NSHostingView<AnyView>?
    fileprivate var settingsWindow: NSWindow?
    private var settingsHosting: NSHostingView<AnyView>?
    private weak var historyStore: HistoryStore?
    private weak var appState: AppState?
    private weak var statusButton: NSStatusBarButton?
    private var resignObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    /// App that was frontmost before the popup opened; pastes are delivered to it.
    private var previousApp: NSRunningApplication?
    /// Bumped on every show and hide so a late re-show from an older open cannot
    /// resurrect a window the user already dismissed.
    private var showGeneration = 0
    /// True while a show is still settling. Accessory apps resign active for a
    /// moment as they come forward; hiding on that flicker is why the first
    /// click or shortcut appears to do nothing.
    private var suppressFocusLossHide = false
    private var wantsMainWindow = false
    private var isPresenting = false
    /// Set once this show has actually brought Clipword forward. Distinguishes
    /// "activation hasn't landed yet" from "the user already switched away".
    private var activationLanded = false

    func configure(historyStore: HistoryStore, appState: AppState) {
        self.historyStore = historyStore
        self.appState = appState
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.hideBecauseFocusLeft()
                }
            }
        }
        if activateObserver == nil {
            activateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.restoreIfActivationLanded()
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

    var isSettingsVisible: Bool {
        settingsWindow?.isVisible == true
    }

    func toggleMainWindow(source: PaletteSource? = nil, fromStatusItem: Bool = false) {
        if isVisible {
            if let source, appState?.paletteSource != source {
                appState?.paletteSource = source
                return
            }
            hideMainWindow()
            return
        }
        showMainWindow(source: source, fromStatusItem: fromStatusItem)
    }

    func showMainWindow(source: PaletteSource? = nil, fromStatusItem: Bool = false) {
        // Stay menu-bar only — never flip to .regular (avoids Dock icon).
        NSApp.setActivationPolicy(.accessory)
        if let source {
            appState?.paletteSource = source
        }

        guard let historyStore, let appState else { return }

        if panel == nil {
            let root = AnyView(
                MainRootView()
                    .environment(historyStore)
                    .environment(appState)
                    .environment(appState.searchService)
                    .ignoresSafeArea()
            )
            let hosting = TransparentHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: Self.windowSize)

            let panel = KeyablePanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            // No `.transient`: that flag hides the panel the moment the app is
            // inactive, which is still true while an accessory app is activating.
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // false so buttons keep pointing-hand cursor / hit testing
            panel.isMovableByWindowBackground = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.contentView = LiquidGlass.embed(hosting, cornerRadius: Self.cornerRadius)
            panel.delegate = PanelDelegate.shared
            PanelDelegate.shared.manager = self

            self.panel = panel
            self.hosting = hosting
        }

        guard let panel else { return }
        showGeneration += 1
        let generation = showGeneration
        wantsMainWindow = true
        activationLanded = false
        // Cover the whole activation handshake, not just the current turn.
        // didResignActive often arrives a beat after activate() returns.
        suppressFocusLossHide = true

        // Remember who the user came from so pastes can return to that app.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        applyChrome(to: panel)
        positionPanel(panel, fromStatusItem: fromStatusItem)
        // Order front before activate. Activating an accessory app with nothing
        // on screen makes macOS resign immediately, and a panel shown during
        // that resign is discarded — the first click/shortcut never appears.
        present(panel)
        appState.windowPresentationToken += 1

        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.showGeneration == generation else { return }
            self.applyChrome(to: panel)
            self.present(panel)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak panel] in
            guard let self, let panel, self.showGeneration == generation else { return }
            if !panel.isVisible || (!NSApp.isActive && !self.activationLanded) {
                // Still hidden, or activation never stuck. Try once more.
                self.present(panel)
                self.releaseFocusLossSuppression(for: generation, after: 0.2)
            } else if panel.isVisible && !NSApp.isActive && self.activationLanded {
                // Came forward, then the user left during the grace period.
                self.hideMainWindow()
            } else {
                if !panel.isKeyWindow { panel.makeKey() }
                self.suppressFocusLossHide = false
            }
        }
    }

    private func releaseFocusLossSuppression(for generation: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.showGeneration == generation else { return }
            self.suppressFocusLossHide = false
        }
    }

    func hideMainWindow() {
        showGeneration += 1
        wantsMainWindow = false
        suppressFocusLossHide = false
        if let panel {
            Defaults[.popupLastFrame] = NSStringFromRect(panel.frame)
        }
        panel?.orderOut(nil)
    }

    func showSettingsWindow(section: SettingsSection = .general) {
        NSApp.setActivationPolicy(.accessory)
        appState?.settingsSection = section
        hideMainWindow()

        guard let historyStore, let appState else { return }

        if settingsWindow == nil {
            let root = AnyView(
                SettingsRootView()
                    .environment(historyStore)
                    .environment(appState)
                    .environment(appState.searchService)
            )
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: Self.settingsWindowSize)

            let window = NSWindow(
                contentRect: hosting.frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.level = NSWindow.Level.normal
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = hosting
            window.delegate = SettingsWindowDelegate.shared
            SettingsWindowDelegate.shared.manager = self
            window.setContentSize(Self.settingsWindowSize)
            window.center()

            settingsWindow = window
            settingsHosting = hosting
        }

        guard let settingsWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    func handleSettingsClosed() {
        settingsWindow?.orderOut(nil)
    }

    /// Resign notifications that are part of coming forward, not the user leaving.
    func hideBecauseFocusLeft() {
        guard wantsMainWindow, !suppressFocusLossHide else { return }
        hideMainWindow()
    }

    /// activate() finishes after show() returns. If the panel was dropped on the
    /// way up, put it back once the app is actually frontmost.
    private func restoreIfActivationLanded() {
        activationLanded = true
        guard wantsMainWindow, let panel else { return }
        if !panel.isVisible {
            present(panel)
        } else if !panel.isKeyWindow {
            panel.makeKey()
        }
    }

    private func present(_ panel: NSPanel) {
        if isPresenting { return }
        isPresenting = true
        defer { isPresenting = false }

        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Brings back the app that was frontmost before the popup opened, so a
    /// simulated ⌘V lands there instead of in Clipword. Only switches when
    /// Clipword itself is still frontmost (e.g. right after the panel closes);
    /// if the user already moved to another app, that app keeps focus.
    /// Returns the app focus was handed to (nil = no switch happened).
    @discardableResult
    func reactivatePreviousApp() -> NSRunningApplication? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        guard let previousApp,
              !previousApp.isTerminated,
              previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        let target = previousApp
        target.activate(options: [.activateAllWindows])
        // Handed focus to the source app; drop the reference so a later paste
        // can't target a stale app. (Kept across hide, because the panel hides
        // before the deferred ⌘V fires.)
        self.previousApp = nil
        return target
    }

    func handlePanelClosed() {
        // Keep panel instance for reuse; just hide.
    }

    private func applyChrome(to window: NSWindow) {
        window.toolbar = nil
        window.title = ""
        window.styleMask = [.borderless, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        LiquidGlass.applyWindowShape(window.contentView, cornerRadius: Self.cornerRadius)
    }

    private func positionPanel(_ panel: NSPanel, fromStatusItem: Bool) {
        let size = Self.windowSize
        let screen = screenForPlacement(preferStatusItem: fromStatusItem)
        let visible = screen.visibleFrame
        let frame: NSRect

        if fromStatusItem, let statusFrame = frameNearStatusItem(size: size) {
            frame = statusFrame
        } else {
            switch Defaults[.popupPosition] {
            case .cursor:
                let mouse = NSEvent.mouseLocation
                var x = mouse.x - size.width / 2
                var y = mouse.y - size.height - 20
                x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
                y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
                frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            case .menuBar:
                frame = frameNearStatusItem(size: size) ?? NSRect(
                    x: visible.maxX - size.width - 20,
                    y: visible.maxY - size.height - 12,
                    width: size.width,
                    height: size.height
                )
            case .center:
                frame = NSRect(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            case .lastPosition:
                if let saved = lastSavedFrame() {
                    frame = clamped(saved, size: size, to: visible)
                } else {
                    frame = NSRect(
                        x: visible.midX - size.width / 2,
                        y: visible.midY - size.height / 2,
                        width: size.width,
                        height: size.height
                    )
                }
            }
        }

        panel.setFrame(frame, display: true)
    }

    private func screenForPlacement(preferStatusItem: Bool) -> NSScreen {
        if preferStatusItem, let screen = statusButton?.window?.screen {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func frameNearStatusItem(size: NSSize) -> NSRect? {
        guard let button = statusButton, let buttonWindow = button.window else { return nil }
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
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func lastSavedFrame() -> NSRect? {
        let raw = Defaults[.popupLastFrame]
        guard !raw.isEmpty else { return nil }
        let rect = NSRectFromString(raw)
        return rect.width > 0 && rect.height > 0 ? rect : nil
    }

    private func clamped(_ frame: NSRect, size: NSSize, to visible: NSRect) -> NSRect {
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(origin: origin, size: size)
    }
}

@MainActor
private final class PanelDelegate: NSObject, NSWindowDelegate {
    static let shared = PanelDelegate()
    weak var manager: WindowManager?

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Defer so sheets/menus can become key first.
        DispatchQueue.main.async { [weak self] in
            if window.attachedSheet != nil { return }
            if let key = NSApp.keyWindow, key.sheetParent === window { return }
            // Stay open for in-app menus/popovers (pickers, context menus).
            // Close when the settings window takes key, or when focus left the app.
            if let settings = self?.manager?.settingsWindow, settings.isKeyWindow {
                self?.manager?.hideMainWindow()
                return
            }
            guard !NSApp.isActive else { return }
            self?.manager?.hideBecauseFocusLeft()
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

@MainActor
private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowDelegate()
    weak var manager: WindowManager?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        manager?.handleSettingsClosed()
        return false
    }
}
