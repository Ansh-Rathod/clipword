import AppKit
import SwiftUI

// MARK: - Arrow focus (web-style tabbing via arrows)

enum ArrowFocusExitDirection {
    /// Esc (or ← at page left edge) → sidebar; falls back to the sidebar toggle when hidden.
    case previous, next
    /// ↑ from content top-left → sidebar toggle
    case chromeLeading
    /// ↑ from content top (other columns) → close
    case chromeTrailing
}

enum ArrowFocusEnterTarget {
    /// Window open / Return from sidebar → list when available.
    case listPreferred
    /// ↓ from sidebar toggle → leftmost toolbar control.
    case toolbarLeading
    /// ↓ from close → rightmost toolbar control.
    case toolbarTrailing
}

private struct ArrowFocusExitKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: ((ArrowFocusExitDirection) -> Void)? = nil
}

private struct ArrowFocusEnterTokenKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

private struct ArrowFocusEnterTargetKey: EnvironmentKey {
    static let defaultValue: ArrowFocusEnterTarget = .listPreferred
}

private struct ContentShouldTakeFocusKey: EnvironmentKey {
    static let defaultValue = true
}

private struct SidebarOpenForFocusKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var arrowFocusExit: ((ArrowFocusExitDirection) -> Void)? {
        get { self[ArrowFocusExitKey.self] }
        set { self[ArrowFocusExitKey.self] = newValue }
    }

    /// Incremented when chrome hands focus into content.
    var arrowFocusEnterToken: Int {
        get { self[ArrowFocusEnterTokenKey.self] }
        set { self[ArrowFocusEnterTokenKey.self] = newValue }
    }

    /// Which content stop to highlight when `arrowFocusEnterToken` bumps.
    var arrowFocusEnterTarget: ArrowFocusEnterTarget {
        get { self[ArrowFocusEnterTargetKey.self] }
        set { self[ArrowFocusEnterTargetKey.self] = newValue }
    }

    /// False while sidebar (or other chrome) holds keyboard focus.
    var contentShouldTakeFocus: Bool {
        get { self[ContentShouldTakeFocusKey.self] }
        set { self[ContentShouldTakeFocusKey.self] = newValue }
    }

    /// True when the sidebar is visible (← from page edge may focus it).
    var sidebarOpenForFocus: Bool {
        get { self[SidebarOpenForFocusKey.self] }
        set { self[SidebarOpenForFocusKey.self] = newValue }
    }
}

struct ArrowFocusRingModifier: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    var forced: Bool = false

    private var active: Bool { isFocused || forced }

    func body(content: Content) -> some View {
        content
            .background {
                ArrowFocusAnchorProbe(active: active)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(active ? 1 : 0)
                    .padding(-2)
            }
            .animation(.easeInOut(duration: 0.1), value: active)
    }
}

/// Tracks the NSView under the arrow-focused control so menus can pop beside it.
@MainActor
enum ArrowFocusMenuAnchor {
    static var view: NSView?
}

private final class ArrowFocusAnchorNSView: NSView {
    var active = false {
        didSet { publish() }
    }

    override func layout() {
        super.layout()
        publish()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publish()
    }

    private func publish() {
        if active, window != nil, bounds.width > 0, bounds.height > 0 {
            ArrowFocusMenuAnchor.view = self
        } else if ArrowFocusMenuAnchor.view === self {
            ArrowFocusMenuAnchor.view = nil
        }
    }
}

private struct ArrowFocusAnchorProbe: NSViewRepresentable {
    var active: Bool

    func makeNSView(context: Context) -> ArrowFocusAnchorNSView {
        ArrowFocusAnchorNSView()
    }

    func updateNSView(_ nsView: ArrowFocusAnchorNSView, context: Context) {
        nsView.active = active
    }

    static func dismantleNSView(_ nsView: ArrowFocusAnchorNSView, coordinator: ()) {
        nsView.active = false
        if ArrowFocusMenuAnchor.view === nsView {
            ArrowFocusMenuAnchor.view = nil
        }
    }
}

extension View {
    func arrowFocus<F: Hashable>(_ focus: FocusState<F?>.Binding, equals value: F) -> some View {
        self
            .focusable()
            .focused(focus, equals: value)
            .modifier(ArrowFocusRingModifier())
    }

    /// Keyboard focus on a List without a ring around the whole list — row selection is the indicator.
    func arrowListFocus<F: Hashable>(_ focus: FocusState<F?>.Binding, equals value: F) -> some View {
        self
            .focusable()
            .focused(focus, equals: value)
            .focusEffectDisabled()
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

    static func popCategoryFilter(
        current: ClipboardCategory?,
        select: @escaping (ClipboardCategory?) -> Void
    ) {
        pop(buildMenu { add, separator in
            add(current == nil ? "✓ All Types" : "All Types", "", [], { select(nil) })
            separator()
            for category in ClipboardCategory.allCases {
                let title = category == current ? "✓ \(category.label)" : category.label
                add(title, "", [], { select(category) })
            }
        })
    }

    static func popAppFilter(
        apps: [AppFilterOption],
        current: String?,
        select: @escaping (String?) -> Void
    ) {
        pop(buildMenu { add, separator in
            add(current == nil ? "✓ All Apps" : "All Apps", "", [], { select(nil) })
            if !apps.isEmpty {
                separator()
                for app in apps {
                    let label = "\(app.name) (\(app.count))"
                    let title = app.bundleId == current ? "✓ \(label)" : label
                    add(title, "", [], { select(app.bundleId) })
                }
            }
        })
    }

    /// Pop a menu of choices with a checkmark on the current one (arrow-key navigable).
    static func popChoices<T: Hashable>(
        title: (T) -> String,
        current: T?,
        choices: [T],
        select: @escaping (T) -> Void
    ) {
        pop(buildMenu { add, _ in
            for choice in choices {
                let label = title(choice)
                add(current == choice ? "✓ \(label)" : label, "", [], { select(choice) })
            }
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
        if let anchor = ArrowFocusMenuAnchor.view, anchor.window != nil, !anchor.bounds.isEmpty {
            let y = anchor.isFlipped ? anchor.bounds.maxY + 2 : anchor.bounds.minY - 2
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: anchor)
            return
        }

        guard let contentView = NSApp.keyWindow?.contentView else { return }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 16, y: contentView.isFlipped ? 56 : contentView.bounds.maxY - 56),
            in: contentView
        )
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

/// Read-only, selectable, monospaced text preview backed by NSTextView (TextKit 2).
/// SwiftUI `Text` lays out the entire string before first paint, which freezes on
/// multi-MB clipboard payloads. TextKit 2's NSTextLayoutManager lays out only the
/// viewport, so huge documents render and scroll smoothly. Never becomes first
/// responder so it can't trap the app's arrow-key navigation.
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        // Explicit TextKit 2: viewport-based layout for large documents. Avoid
        // touching `layoutManager`/`textContainer`, which would flip it back to
        // TextKit 1 (full-document layout on every string set).
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesFindBar = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only replace when the item actually changed — avoids relayout churn on
        // every SwiftUI body evaluation.
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
        }
    }
}

/// NSTextView that stays out of the keyboard focus chain: the app navigates with
/// arrow keys via SwiftUI, and a first-responder text view would swallow them.
private final class PreviewTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
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
