import AppKit
import Defaults
import SwiftUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PopupPanelController {
    private var panel: KeyablePanel?
    private var hostingView: NSHostingView<AnyView>?
    private var onHide: (() -> Void)?

    func show(appState: AppState, relativeTo statusButton: NSStatusBarButton? = nil, onHide: (() -> Void)? = nil) {
        self.onHide = onHide

        let rootView = AnyView(
            ClipboardPopupView()
                .environment(appState)
                .environment(appState.historyStore)
                .environment(appState.searchService)
        )

        if panel == nil {
            let hosting = NSHostingView(rootView: rootView)
            hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 520)

            let panel = KeyablePanel(
                contentRect: hosting.frame,
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .windowBackgroundColor
            panel.isOpaque = true
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.contentView = hosting
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.delegate = PopupPanelDelegate.shared
            self.panel = panel
            self.hostingView = hosting
            PopupPanelDelegate.shared.controller = self
        } else {
            hostingView?.rootView = rootView
        }

        positionPanel(relativeTo: statusButton)
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        onHide?()
        onHide = nil
    }

    func handlePanelClosed() {
        onHide?()
        onHide = nil
    }

    private func positionPanel(relativeTo statusButton: NSStatusBarButton?) {
        guard let panel else { return }

        let size = panel.frame.size
        let frame: NSRect

        if let button = statusButton,
           let buttonWindow = button.window {
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
        } else {
            guard let screen = NSScreen.main else { return }
            let visible = screen.visibleFrame
            switch Defaults[.popupPosition] {
            case .cursor:
                let mouse = NSEvent.mouseLocation
                var x = mouse.x - size.width / 2
                var y = mouse.y - size.height - 20
                x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
                y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
                frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            case .menuBar:
                frame = NSRect(
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
                if panel.frame.origin != .zero {
                    frame = panel.frame
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
}

@MainActor
private final class PopupPanelDelegate: NSObject, NSWindowDelegate {
    static let shared = PopupPanelDelegate()
    weak var controller: PopupPanelController?

    func windowDidResignKey(_ notification: Notification) {
        // Keep popup open when switching apps unless user dismissed it.
    }

    func windowWillClose(_ notification: Notification) {
        controller?.handlePanelClosed()
    }
}
