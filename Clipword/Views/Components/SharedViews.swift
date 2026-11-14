import AppKit
import ImageIO
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

private struct GlobalJumpTokenKey: EnvironmentKey {
    static let defaultValue = 0
}

private struct GlobalJumpDirectionKey: EnvironmentKey {
    static let defaultValue = SpatialDirection.down
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

    /// Bumped by `MainRootView` when ⌘↑/⌘↓ should jump the current page's
    /// content to its top/bottom (works even while the sidebar or chrome bar
    /// holds focus). Pages observe it and apply their own jump.
    var globalJumpToken: Int {
        get { self[GlobalJumpTokenKey.self] }
        set { self[GlobalJumpTokenKey.self] = newValue }
    }

    var globalJumpDirection: SpatialDirection {
        get { self[GlobalJumpDirectionKey.self] }
        set { self[GlobalJumpDirectionKey.self] = newValue }
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
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(active ? 0.14 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(active ? 0.85 : 0), lineWidth: 1.5)
            }
            .animation(.easeInOut(duration: 0.12), value: active)
    }
}

/// Tracks the NSView under the arrow-focused control so menus can pop beside it.
@MainActor
enum ArrowFocusMenuAnchor {
    static weak var view: NSView?
}

/// Holds a persistent NSView pointer for a control that can open a menu on click
/// even when it is not the keyboard-focused view.
@MainActor
final class MenuAnchorBox {
    weak var view: NSView?
}

/// Accent fill on the selected row while the list has keyboard focus; a quieter
/// fill when the row is selected but the list is not the active control.
struct KeyboardListRowChrome: View {
    let isSelected: Bool
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fillColor)
            .padding(.vertical, 1)
    }

    private var fillColor: Color {
        if isSelected && isActive { return Color.accentColor }
        if isSelected { return Color.primary.opacity(0.10) }
        return .clear
    }
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

private final class PersistentMenuAnchorNSView: NSView {
    weak var box: MenuAnchorBox?

    override func layout() {
        super.layout()
        box?.view = self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        box?.view = self
    }
}

private struct PersistentMenuAnchorProbe: NSViewRepresentable {
    let box: MenuAnchorBox

    func makeNSView(context: Context) -> PersistentMenuAnchorNSView {
        let view = PersistentMenuAnchorNSView()
        view.box = box
        return view
    }

    func updateNSView(_ nsView: PersistentMenuAnchorNSView, context: Context) {
        nsView.box = box
        box.view = nsView
    }

    static func dismantleNSView(_ nsView: PersistentMenuAnchorNSView, coordinator: ()) {
        if nsView.box?.view === nsView {
            nsView.box?.view = nil
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

    /// Publishes this view as the menu anchor while `active` is true (selected list row).
    func keyboardMenuAnchor(_ active: Bool) -> some View {
        background {
            ArrowFocusAnchorProbe(active: active)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }

    func keyboardListRow(selected: Bool, listActive: Bool) -> some View {
        let active = selected && listActive
        return self
            .keyboardMenuAnchor(active)
            .listRowBackground(KeyboardListRowChrome(isSelected: selected, isActive: active))
    }

    /// Keeps the row identified by `target` visible whenever it changes.
    ///
    /// `List` doesn't support `.scrollPosition(id:)` — that modifier is
    /// `ScrollView`-only and is a silent no-op on a `List`. This wraps the list
    /// in a `ScrollViewReader` and calls `scrollTo`. A nil anchor scrolls the
    /// minimum amount needed to make the target visible; a non-nil anchor aligns
    /// the target to that point (e.g. `.top` snaps the target's top to the
    /// scroll view's top).
    func scrollToVisible<T: Hashable>(target: T?, anchor: UnitPoint? = nil) -> some View {
        ScrollViewReader { proxy in
            self
                .onChange(of: target) { _, newValue in
                    guard let newValue else { return }
                    // Defer so the row's layout exists before we ask the scroll
                    // view to reveal it; direct calls inside key handling can
                    // be swallowed before the list updates.
                    DispatchQueue.main.async {
                        proxy.scrollTo(newValue, anchor: anchor)
                    }
                }
        }
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
enum KeyboardNativeFocus {
    /// Makes an embedded AppKit editor (shortcut recorder, date picker) first responder.
    @discardableResult
    static func focusEmbeddedControl() -> Bool {
        guard let anchor = ArrowFocusMenuAnchor.view,
              let window = anchor.window else { return false }

        func isControl(_ view: NSView) -> Bool {
            view is NSSearchField || view is NSDatePicker || view is NSComboBox
        }

        func find(in view: NSView) -> NSView? {
            if view !== anchor, isControl(view) { return view }
            for subview in view.subviews {
                if let hit = find(in: subview) { return hit }
            }
            return nil
        }

        var node: NSView? = anchor.superview
        while let view = node {
            if let hit = find(in: view) {
                return window.makeFirstResponder(hit)
            }
            node = view.superview
        }
        return false
    }
}

/// Pull-down that opens `KeyboardContextMenu` under the control, for both click
/// and Return — native `Picker` menus track the mouse cursor on keyboard open.
struct KeyboardMenuPicker<Value: Hashable>: View {
    var prompt: String?
    @Binding var selection: Value
    let options: [Value]
    var title: (Value) -> String

    @State private var anchor = MenuAnchorBox()

    var body: some View {
        Group {
            if let prompt {
                LabeledContent(prompt) { pickerButton }
            } else {
                pickerButton
            }
        }
    }

    private var pickerButton: some View {
        HStack(spacing: 6) {
            Text(title(selection))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .pointingHandCursor()
        .background {
            PersistentMenuAnchorProbe(box: anchor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
        .onTapGesture { showMenu() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(prompt ?? title(selection))
        .accessibilityValue(title(selection))
    }

    func showMenu() {
        KeyboardContextMenu.popChoices(
            title: title,
            current: selection,
            choices: options,
            relativeTo: anchor.view
        ) { selection = $0 }
    }
}

@MainActor
enum KeyboardContextMenu {
    private static var keepAlive: MenuActions?
    private static var lastPopAt: TimeInterval = 0

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
        delete: @escaping () -> Void,
        relativeTo view: NSView? = nil
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
        }, relativeTo: view)
    }

    static func popBookmark(
        copy: @escaping () -> Void,
        paste: @escaping () -> Void,
        edit: @escaping () -> Void,
        remove: @escaping () -> Void,
        relativeTo view: NSView? = nil
    ) {
        pop(buildMenu { add, separator in
            add("Copy", "c", .command, copy)
            add("Paste", "\r", [], paste)
            separator()
            add("Edit…", "e", .command, edit)
            add("Remove Bookmark", "\u{08}", .command, remove)
        }, relativeTo: view)
    }

    static func popCategoryFilter(
        current: ClipboardCategory?,
        select: @escaping (ClipboardCategory?) -> Void,
        relativeTo view: NSView? = nil
    ) {
        pop(buildMenu { add, separator in
            add(current == nil ? "✓ All Types" : "All Types", "", [], { select(nil) })
            separator()
            for category in ClipboardCategory.allCases {
                let title = category == current ? "✓ \(category.label)" : category.label
                add(title, "", [], { select(category) })
            }
        }, relativeTo: view)
    }

    static func popAppFilter(
        apps: [AppFilterOption],
        current: String?,
        select: @escaping (String?) -> Void,
        relativeTo view: NSView? = nil
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
        }, relativeTo: view)
    }

    /// Pop a menu of choices with a checkmark on the current one (arrow-key navigable).
    static func popChoices<T: Hashable>(
        title: (T) -> String,
        current: T?,
        choices: [T],
        relativeTo view: NSView? = nil,
        select: @escaping (T) -> Void
    ) {
        pop(buildMenu { add, _ in
            for choice in choices {
                let label = title(choice)
                add(current == choice ? "✓ \(label)" : label, "", [], { select(choice) })
            }
        }, relativeTo: view)
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

    private static func pop(_ menu: NSMenu, relativeTo view: NSView? = nil) {
        // Return on a focused control can fire both the control action and the
        // page's onKeyPress handler; ignore a second pop while the first is up.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPopAt < 0.2 { return }
        lastPopAt = now

        let anchor = view ?? ArrowFocusMenuAnchor.view
        let window = anchor?.window ?? NSApp.keyWindow

        // Key events store the mouse cursor in `locationInWindow`. NSMenu uses
        // the current event unless we synthesize a click on the control itself.
        if let anchor, let window, !anchor.bounds.isEmpty {
            let rectInWindow = anchor.convert(anchor.bounds, to: nil)
            let clickInWindow = NSPoint(x: rectInWindow.minX, y: rectInWindow.minY)
            if let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: clickInWindow,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) {
                NSMenu.popUpContextMenu(menu, with: event, for: anchor)
                return
            }
            let screenRect = window.convertToScreen(rectInWindow)
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: screenRect.minX, y: screenRect.minY - 2),
                in: nil
            )
            return
        }

        if let window {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: window.frame.minX + 16, y: window.frame.maxY - 72),
                in: nil
            )
        }
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
///
/// The input is still bounded to `previewCharacterLimit`: in the real panel the
/// initial layout + scroll-view content sizing of a 10MB+ document blocked the
/// main thread for seconds. A bounded head renders instantly; the full content
/// is always available through Copy/Paste.
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    static let previewCharacterLimit = 100_000

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
        textView.string = Self.bounded(text)
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
        let display = Self.bounded(text)
        if textView.string != display {
            textView.string = display
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    private static func bounded(_ text: String) -> String {
        // utf16.count is O(1) (native/NSString-backed), so the truncation check
        // itself never scans a multi-MB buffer; only the bounded prefix copy runs.
        text.utf16.count > previewCharacterLimit ? String(text.prefix(previewCharacterLimit)) : text
    }
}

/// Bounded text preview with a truncation footer for the detail panes.
/// Rendering a multi-MB string in the panel (initial layout + scroll-view
/// content sizing) blocks the main thread for seconds, so the preview shows a
/// head and the footer makes the truncation explicit. The full content is
/// still what gets copied/pasted.
struct TextPreviewPane: View {
    let text: String
    let charCount: Int

    private var isTruncated: Bool {
        charCount > ReadOnlyTextView.previewCharacterLimit
    }

    var body: some View {
        VStack(spacing: 0) {
            ReadOnlyTextView(text: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isTruncated {
                Divider()
                Text("Preview shows the first \(ReadOnlyTextView.previewCharacterLimit.formatted()) of \(charCount.formatted()) characters — the full content is copied on paste")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
    }
}

/// Downsampled, cached image preview. Selecting a large screenshot previously
/// decoded the full-resolution bitmap on the main thread during body
/// evaluation — and re-decoded it on every re-render. This thumbnails via
/// CGImageSource (bounded pixels, far less memory) off the main thread and
/// caches per item, so switching between items never re-pays the decode cost.
struct DetailImagePreview: View {
    let id: UUID
    let data: Data

    @State private var image: NSImage?
    @State private var failed = false

    private nonisolated(unsafe) static let cache = NSCache<NSUUID, NSImage>()
    private nonisolated static let maxPixelSize = 1600

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if failed {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Preview unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .padding(20)
        .task(id: id) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        let key = id as NSUUID
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }
        let cgImage = await Task.detached(priority: .userInitiated) {
            Self.downsampledCGImage(from: data)
        }.value
        if let cgImage {
            let nsImage = NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            )
            Self.cache.setObject(nsImage, forKey: key)
            image = nsImage
        } else {
            failed = true
        }
    }

    private nonisolated static func downsampledCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
