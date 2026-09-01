import AppKit
import Defaults
import SwiftUI

// Reuse the same nonactivating-panel tech as WindowManager/FloatingPanel.
private final class SuggestionKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Small type-to-filter palette (⌥Space by default) floating near the cursor.
/// Deliberately does NOT activate Clipword: the frontmost app keeps focus, so
/// the existing `PasteService.paste()` ⌘V lands right back where the user was.
@MainActor
final class SuggestionPanelController: NSObject, NSWindowDelegate {
    static let shared = SuggestionPanelController()

    private var panel: SuggestionKeyablePanel?
    private var hosting: NSHostingView<AnyView>?
    private weak var appState: AppState?
    /// App that was frontmost before the palette opened; pastes target it.
    private var previousApp: NSRunningApplication?

    private static let panelSize = NSSize(width: 480, height: 320)

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(appState: AppState) {
        if isVisible {
            hide()
        } else {
            show(appState: appState)
        }
    }

    func show(appState: AppState) {
        self.appState = appState

        let root = AnyView(
            SuggestionPaletteView(onClose: { [weak self] in self?.hide() })
                .environment(appState)
                .environment(appState.historyStore)
        )

        if panel == nil {
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 10
            hosting.layer?.cornerCurve = .continuous
            hosting.layer?.masksToBounds = true

            let panel = SuggestionKeyablePanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            // Must be false: the palette deliberately deactivates the user's app
            // (Spotlight-style), and hidesOnDeactivate would instantly hide us.
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.contentView = hosting
            panel.delegate = self
            self.panel = panel
            self.hosting = hosting
        } else {
            hosting?.rootView = root
        }

        guard let panel else { return }
        positionPanel(panel)
        // Spotlight-style: remember who the user was typing in, then activate
        // Clipword so the text field actually receives keystrokes. The stored
        // paste target is what PasteService's simulated ⌘V returns to.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
            WindowManager.shared.setPasteTarget(frontmost)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionPanel(_ panel: NSPanel) {
        let size = Self.panelSize
        let mouse = NSEvent.mouseLocation
        // Anchor to the screen the cursor is on, not NSScreen.main.
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var x = mouse.x - 20 // slight left bias, like a context menu
        var y = mouse.y - size.height - 12

        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        if y < visible.minY + 8 {
            y = mouse.y + 20
        }
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hide()
        // Palette lost key (Esc dismiss, click elsewhere, app switch): hand
        // focus back to the app the user was typing in — unless PasteService is
        // mid-paste (it manages the switch itself with the right delay).
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isVisible else { return }
            self.reactivatePasteTarget()
        }
    }

    /// Returns focus to the app the user came from, only when Clipword itself
    /// is still frontmost (otherwise the user already moved on).
    private func reactivatePasteTarget() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else {
            previousApp = nil
            return
        }
        guard let previousApp,
              !previousApp.isTerminated,
              previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            self.previousApp = nil
            return
        }
        previousApp.activate(options: [.activateAllWindows])
        self.previousApp = nil
    }
}

/// Type-to-filter palette over clipboard history. Enter/Tab pastes the
/// selection into the previously frontmost app; Esc dismisses.
struct SuggestionPaletteView: View {
    var onClose: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore
    @Default(.inlineMinChars) private var minChars
    @Default(.inlineMaxLength) private var maxLength
    @Default(.inlineMaxSuggestions) private var maxSuggestions

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private var results: [HistoryItem] {
        let config = SuggestionMatcher.Config(
            minChars: minChars,
            maxLength: maxLength,
            limit: maxSuggestions
        )
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SuggestionMatcher.recentTextItems(in: historyStore.items, limit: maxSuggestions)
        }
        return SuggestionMatcher.suggestions(for: query, in: historyStore.items, config: config)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
            footer
        }
        .frame(width: 480, height: 320)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { fieldFocused = true }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            let items = results
            guard !items.isEmpty else { return .ignored }
            let delta = press.key == .upArrow ? -1 : 1
            selectedIndex = (selectedIndex + delta + items.count) % items.count
            return .handled
        }
        .onKeyPress(.return) { accept(); return .handled }
        .onKeyPress(.tab) { accept(); return .handled }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.and.command.macwindow")
                .foregroundStyle(.secondary)
            TextField("Type to filter snippets…", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { accept() }
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let items = results
                    if items.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            HistoryRowView(item: item)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background {
                                    if index == selectedIndex {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(.tint.opacity(0.15))
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = index
                                    accept()
                                }
                                .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                if let id = results[safe: newIndex]?.id {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("↑↓ navigate", systemImage: "arrow.up.arrow.down")
            Label("Tab paste", systemImage: "return")
            Label("Esc dismiss", systemImage: "escape")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func accept() {
        guard let item = results[safe: selectedIndex] ?? results.first else { return }
        // Reuses the existing auto-paste path: clipboard write with Clipword
        // marker, then simulated ⌘V into the (still-frontmost) source app.
        historyStore.select(item, paste: true)
        onClose()
    }
}

private extension [HistoryItem] {
    subscript(safe index: Int) -> HistoryItem? {
        indices.contains(index) ? self[index] : nil
    }
}
