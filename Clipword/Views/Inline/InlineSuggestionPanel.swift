import AppKit
import SwiftUI

/// Borderless, non-key, click-through strip rendered at the caret (or near the
/// mouse as fallback) showing clipboard-history completions. Never activates
/// Clipword, never takes focus — the host app keeps typing untouched.
private final class InlinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class InlineSuggestionPanelController {
    private var panel: InlinePanel?
    private var hosting: NSHostingView<AnyView>?

    var isVisible: Bool { panel?.isVisible == true }

    private static let width: CGFloat = 440
    private static let rowHeight: CGFloat = 26
    private static let padding: CGFloat = 14

    func show(buffer: String, suggestions: [HistoryItem], caretRect: NSRect?) {
        let rows = min(suggestions.count, 3)
        let size = NSSize(width: Self.width, height: CGFloat(rows) * Self.rowHeight + Self.padding)

        let root = AnyView(
            InlineSuggestionView(buffer: buffer, suggestions: suggestions)
        )

        if panel == nil {
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 8
            hosting.layer?.cornerCurve = .continuous
            hosting.layer?.masksToBounds = true

            let panel = InlinePanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            // Must never react to or affect host-app focus.
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.contentView = hosting
            self.panel = panel
            self.hosting = hosting
        } else {
            hosting?.rootView = root
        }

        guard let panel else { return }
        hosting?.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        positionPanel(caretRect: caretRect, size: size)
        // setFrame without animation to avoid flicker between keystrokes.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionPanel(caretRect: NSRect?, size: NSSize) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var x: CGFloat
        var y: CGFloat
        if let caretRect, caretRect.width >= 0, caretRect.height > 0 {
            x = caretRect.minX
            y = caretRect.maxY + 6
        } else {
            x = mouse.x
            y = mouse.y + 20
        }

        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        if y + size.height > visible.maxY - 8 {
            y = (caretRect?.minY ?? mouse.y) - size.height - 6
        }
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

/// Ghost-text strip: the typed prefix in tertiary color followed by the
/// completion, plus dimmed alternatives below.
struct InlineSuggestionView: View {
    let buffer: String
    let suggestions: [HistoryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let top = suggestions.first {
                ghostRow(for: top)
            }
            ForEach(suggestions.dropFirst().prefix(2), id: \.id) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.category.systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(item.displayTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.background.opacity(0.98))
        .overlay(alignment: .bottomTrailing) {
            Text("Tab")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(4)
        }
        .frame(width: 440, height: CGFloat(min(suggestions.count, 3)) * 26 + 14)
    }

    /// Typed prefix in tertiary + remaining text in primary, like VSCode ghost text.
    private func ghostRow(for item: HistoryItem) -> some View {
        let full: Substring = item.plainText.map { $0.prefix(300) } ?? Substring(item.displayTitle)
        let typed = buffer.count <= full.count ? String(full.prefix(buffer.count)) : ""
        let rest = buffer.count <= full.count ? String(full.dropFirst(buffer.count)) : String(full)
        let restSingleLine = rest.replacingOccurrences(of: "\n", with: " ⏎ ")
        return (Text(typed).foregroundColor(Color(nsColor: .tertiaryLabelColor))
                + Text(restSingleLine).foregroundColor(.primary))
            .font(.system(size: 13, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
