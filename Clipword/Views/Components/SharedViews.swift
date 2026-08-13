import AppKit
import SwiftUI

// MARK: - Arrow focus (web-style tabbing via arrows)

enum ArrowFocusExitDirection {
    case previous, next
}

private struct ArrowFocusExitKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((ArrowFocusExitDirection) -> Void)? = nil
}

private struct ArrowFocusEnterTokenKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

private struct ContentShouldTakeFocusKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var arrowFocusExit: ((ArrowFocusExitDirection) -> Void)? {
        get { self[ArrowFocusExitKey.self] }
        set { self[ArrowFocusExitKey.self] = newValue }
    }

    /// Incremented when chrome hands focus into content (focus first content stop).
    var arrowFocusEnterToken: Int {
        get { self[ArrowFocusEnterTokenKey.self] }
        set { self[ArrowFocusEnterTokenKey.self] = newValue }
    }

    /// False while sidebar (or other chrome) holds keyboard focus.
    var contentShouldTakeFocus: Bool {
        get { self[ContentShouldTakeFocusKey.self] }
        set { self[ContentShouldTakeFocusKey.self] = newValue }
    }
}

struct ArrowFocusRingModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    var forced: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity((isFocused || forced) ? 1 : 0)
                    .padding(-2)
            }
            .animation(.easeInOut(duration: 0.1), value: isFocused || forced)
    }
}

extension View {
    func arrowFocus<F: Hashable>(_ focus: FocusState<F?>.Binding, equals value: F) -> some View {
        self
            .focusable(true, interactions: .activate)
            .focused(focus, equals: value)
            .modifier(ArrowFocusRingModifier())
            .modifier(PointingHandOnHover())
    }

    /// Highlight ring without focusing an editable TextField (Return enters edit).
    func arrowHighlight<F: Hashable>(_ focus: F?, equals value: F) -> some View {
        self.modifier(ArrowFocusRingModifier(forced: focus == value))
    }

    func pointingHandCursor() -> some View {
        modifier(PointingHandOnHover())
    }
}

private struct PointingHandOnHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                hovering = isHovering
                if isHovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if hovering { NSCursor.pop() }
            }
    }
}

enum SpatialFocusResult<F: Hashable> {
    case moved(F)
    case listMove(Int)
    case exitPrevious
    case exitNext
}

enum SpatialDirection {
    case up, down, left, right
}

/// Grid rows: left/right within a row; up/down to adjacent row (same column index when possible).
func moveSpatialFocus<F: Hashable>(
    from current: F,
    direction: SpatialDirection,
    rows: [[F]],
    listIDs: Set<F> = []
) -> SpatialFocusResult<F> {
    guard let rowIndex = rows.firstIndex(where: { $0.contains(current) }),
          let colIndex = rows[rowIndex].firstIndex(of: current) else {
        return .exitNext
    }

    switch direction {
    case .left:
        if colIndex > 0 { return .moved(rows[rowIndex][colIndex - 1]) }
        return .exitPrevious
    case .right:
        if colIndex + 1 < rows[rowIndex].count { return .moved(rows[rowIndex][colIndex + 1]) }
        return .exitNext
    case .up:
        if listIDs.contains(current) { return .listMove(-1) }
        if rowIndex == 0 { return .exitPrevious }
        let prev = rows[rowIndex - 1]
        return .moved(prev[min(colIndex, prev.count - 1)])
    case .down:
        if listIDs.contains(current) { return .listMove(1) }
        if rowIndex + 1 >= rows.count { return .exitNext }
        let next = rows[rowIndex + 1]
        return .moved(next[min(colIndex, next.count - 1)])
    }
}

/// Moves focus within `order`; returns false if movement would leave the ends (caller may exit to chrome).
@discardableResult
func advanceArrowFocus<F: Hashable>(
    _ focus: inout F?,
    order: [F],
    delta: Int,
    listIDs: Set<F> = [],
    vertical: Bool = false,
    onListMove: ((Int) -> Void)? = nil
) -> Bool {
    guard !order.isEmpty else { return true }
    if let current = focus, listIDs.contains(current), vertical {
        onListMove?(delta)
        return true
    }
    guard let current = focus, let index = order.firstIndex(of: current) else {
        focus = delta > 0 ? order.first : order.last
        return true
    }
    let next = index + delta
    if next < 0 || next >= order.count {
        return false
    }
    focus = order[next]
    return true
}

@MainActor
enum KeyboardContextMenu {
    private static var keepAlive: MenuActions?

    final class MenuActions: NSObject {
        var handlers: [Int: () -> Void] = [:]

        @objc func invoke(_ sender: NSMenuItem) {
            handlers[sender.tag]?()
        }
    }

    static func popHistory(
        copy: @escaping () -> Void,
        paste: @escaping () -> Void,
        addToStack: @escaping () -> Void,
        edit: @escaping () -> Void,
        toggleBookmark: @escaping () -> Void,
        bookmarkTitle: String,
        togglePin: @escaping () -> Void,
        pinTitle: String,
        delete: @escaping () -> Void
    ) {
        pop(buildMenu { add, separator in
            add("Copy", "c", .command, copy)
            add("Paste", "\r", [], paste)
            add("Add to Paste Stack", "v", [.command, .shift], addToStack)
            separator()
            add("Edit…", "e", .command, edit)
            add(bookmarkTitle, "b", .option, toggleBookmark)
            add(pinTitle, "p", .option, togglePin)
            separator()
            add("Delete", "\u{08}", .command, delete)
        })
    }

    static func popBookmark(
        copy: @escaping () -> Void,
        paste: @escaping () -> Void,
        edit: @escaping () -> Void,
        remove: @escaping () -> Void
    ) {
        pop(buildMenu { add, separator in
            add("Copy", "c", .command, copy)
            add("Paste", "\r", [], paste)
            separator()
            add("Edit…", "e", .command, edit)
            add("Remove Bookmark", "\u{08}", .command, remove)
        })
    }

    private static func buildMenu(
        _ build: (
            _ add: (String, String, NSEvent.ModifierFlags, @escaping () -> Void) -> Void,
            _ separator: () -> Void
        ) -> Void
    ) -> NSMenu {
        let actions = MenuActions()
        keepAlive = actions
        let menu = NSMenu()
        menu.autoenablesItems = false
        var tag = 1

        func add(_ title: String, _ key: String, _ mask: NSEvent.ModifierFlags, _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuActions.invoke(_:)), keyEquivalent: key)
            item.target = actions
            item.keyEquivalentModifierMask = mask
            item.tag = tag
            actions.handlers[tag] = handler
            tag += 1
            menu.addItem(item)
        }

        build(add, { menu.addItem(.separator()) })
        return menu
    }

    private static func pop(_ menu: NSMenu) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = NSPoint(x: 260, y: view.bounds.midY)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

struct StatCardView: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TimeRangePickerView: View {
    @Binding var preset: TimeRangePreset
    @Binding var customStart: Date
    @Binding var customEnd: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Range", selection: $preset) {
                ForEach(TimeRangePreset.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .help("Time range")

            if preset == .custom {
                DatePicker("Start", selection: $customStart, displayedComponents: .date)
                DatePicker("End", selection: $customEnd, displayedComponents: .date)
            }
        }
    }
}

struct AppIconView: View {
    let bundleId: String?
    var size: CGFloat = 20

    var body: some View {
        if let bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app")
                .frame(width: size, height: size)
        }
    }
}
