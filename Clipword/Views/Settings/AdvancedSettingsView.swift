import Defaults
import SwiftUI

private enum AdvancedFocus: Hashable {
    case clearOnQuit, clearClipboard, requestPermission
}

struct AdvancedSettingsView: View {
    @Default(.clearOnQuit) private var clearOnQuit
    @Default(.clearSystemClipboard) private var clearSystemClipboard
    @Environment(\.arrowFocusExit) private var arrowFocusExit
    @Environment(\.arrowFocusEnterToken) private var enterToken
    @Environment(\.contentShouldTakeFocus) private var contentShouldTakeFocus
    @Environment(\.globalJumpToken) private var globalJumpToken
    @Environment(\.globalJumpDirection) private var globalJumpDirection
    @FocusState private var focus: AdvancedFocus?

    private var order: [AdvancedFocus] {
        var items: [AdvancedFocus] = [.clearOnQuit, .clearClipboard]
        if !PasteService.isAccessibilityTrusted { items.append(.requestPermission) }
        return items
    }

    /// Last focusable row of the preceding section — scroll anchor so a focused
    /// row lower in the Form is revealed when focus lands on it.
    private func sectionAnchor(for focus: AdvancedFocus) -> AdvancedFocus {
        switch focus {
        case .clearOnQuit, .clearClipboard: return .clearOnQuit
        case .requestPermission: return .clearClipboard
        }
    }

    var body: some View {
        Form {
            Section("Clipboard") {
                Toggle("Clear history on quit", isOn: $clearOnQuit)
                    .arrowFocus($focus, equals: .clearOnQuit)
                    .id(AdvancedFocus.clearOnQuit)
                Toggle("Clear system clipboard after copy", isOn: $clearSystemClipboard)
                    .arrowFocus($focus, equals: .clearClipboard)
                    .id(AdvancedFocus.clearClipboard)
            }
            Section("Device Access") {
                LabeledContent("Permission") {
                    if PasteService.isAccessibilityTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Request Permission") {
                            PasteService.requestAccessibility()
                        }
                        .arrowFocus($focus, equals: .requestPermission)
                    }
                }
                .id(AdvancedFocus.requestPermission)
                Text("macOS lists this as Device Control and Data Access. Clipword only asks when you press this button or paste — not on every launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .scrollToVisible(target: focus.map { sectionAnchor(for: $0) }, anchor: .center)
        .onAppear { if contentShouldTakeFocus { focus = order.first } }
        .onChange(of: enterToken) { _, _ in
            #if DEBUG
            DebugTools.settingsLog("[adv] enterToken → order.first")
            #endif
            focus = order.first
        }
        .onChange(of: globalJumpToken) { _, _ in applyGlobalJump(globalJumpDirection) }
        .onChange(of: contentShouldTakeFocus) { _, should in
            if should {
                if focus == nil { focus = order.first }
            } else {
                focus = nil
            }
        }
        .onKeyPress(.rightArrow) { move(1, vertical: false) }
        .onKeyPress(.leftArrow) { move(-1, vertical: false) }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            if press.modifiers.contains(.command) {
                applyGlobalJump(press.key == .upArrow ? .up : .down)
                return .handled
            }
            return move(press.key == .upArrow ? -1 : 1, vertical: true)
        }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.space) { activate() }
        .onKeyPress(.escape) { exitToSidebar() }
    }

    /// ⌘↑/⌘↓ jump the form to its top or bottom row (works even when no row is
    /// focused, e.g. right after leaving the page).
    private func applyGlobalJump(_ direction: SpatialDirection) {
        focus = direction == .up ? order.first : order.last
    }

    /// Single-column form: ↑/↓ walk the rows; → activates the focused row
    /// (same as Return — toggles, opens pickers); ← backs out to the sidebar.
    /// Reaching either end just eats the key — no ejection, no surprise jumps.
    private func move(_ delta: Int, vertical: Bool) -> KeyPress.Result {
        guard focus != nil else { return .ignored }
        if !vertical {
            if delta > 0 { return activate() }
            arrowFocusExit?(.previous)
            return .handled
        }
        var current = focus
        if advanceArrowFocus(&current, order: order, delta: delta) {
            focus = current
        }
        return .handled
    }

    private func exitToSidebar() -> KeyPress.Result {
        arrowFocusExit?(.previous)
        return .handled
    }

    private func activate() -> KeyPress.Result {
        #if DEBUG
        DebugTools.settingsLog("[adv] activate focus=\(String(describing: focus))")
        #endif
        switch focus {
        case .clearOnQuit:
            clearOnQuit.toggle()
            return .handled
        case .clearClipboard:
            clearSystemClipboard.toggle()
            return .handled
        case .requestPermission:
            PasteService.requestAccessibility()
            return .handled
        default:
            return .ignored
        }
    }
}
