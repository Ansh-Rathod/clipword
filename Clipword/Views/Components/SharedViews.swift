import AppKit
import ImageIO
import SwiftUI

// MARK: - Arrow focus (web-style tabbing via arrows)

enum ArrowFocusExitDirection {
    /// Leave content toward the left column: the sidebar when it's open,
    /// otherwise the sidebar-toggle button in the chrome bar.
    case previous, next
    /// ↑ from content top-left, or ← from the left edge when the sidebar is hidden.
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

private struct ListRevealTokenKey: EnvironmentKey {
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

    /// True when the sidebar is visible. ← from a page's left edge then focuses
    /// the sidebar; when false, the same key focuses the sidebar toggle instead.
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

    /// Bumped on keyboard list movement so AppKit can scroll the selection
    /// into view without also jumping when the mouse clicks or the panel reopens.
    var listRevealToken: Int {
        get { self[ListRevealTokenKey.self] }
        set { self[ListRevealTokenKey.self] = newValue }
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

/// Sidebar-style selection pill. Fill only — no stroke, no focus ring.
/// Horizontal inset matches Finder/Mail; the list's own row insets stay intact.
struct KeyboardListRowChrome: View {
    let isSelected: Bool
    let isActive: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fillColor)
            .padding(.horizontal, 8)
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

/// Invisible first-responder stand-in so a List can be the logical keyboard
/// target without AppKit's table view intercepting arrows and Delete.
private struct KeyboardFocusSink: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// Pixel scroll offset for a named pane. Not `@Observable` so tracking
/// while the user drags a scroller doesn't rebuild SwiftUI. AppKit callbacks
/// always hop to the main queue before touching this.
final class PaletteScrollStore: @unchecked Sendable {
    private var offsets: [String: CGPoint] = [:]

    func offset(for key: String) -> CGPoint {
        offsets[key] ?? .zero
    }

    func setOffset(_ offset: CGPoint, for key: String) {
        offsets[key] = offset
    }
}

enum PaletteScrollKey {
    static func list(_ source: PaletteSource) -> String { "list-\(source.rawValue)" }
    static func preview(_ id: UUID) -> String { "preview-\(id.uuidString)" }
    static func info(_ id: UUID) -> String { "info-\(id.uuidString)" }
}

/// Re-applies a saved `NSScrollView` origin after the panel is ordered out
/// (SwiftUI Lists and ScrollViews often jump to top on the next appear).
struct PersistentScrollOffset: NSViewRepresentable {
    let store: PaletteScrollStore
    let key: String
    var restoreToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, key: key)
    }

    func makeNSView(context: Context) -> PersistentScrollProbe {
        let view = PersistentScrollProbe()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: PersistentScrollProbe, context: Context) {
        let keyChanged = context.coordinator.key != key
        context.coordinator.store = store
        context.coordinator.key = key
        nsView.coordinator = context.coordinator
        context.coordinator.attach(nsView.nearestScrollView())
        context.coordinator.restore(token: restoreToken, keyChanged: keyChanged)
    }

    final class Coordinator: @unchecked Sendable {
        var store: PaletteScrollStore
        var key: String
        var lastRestoreToken = -1
        var isRestoring = false
        weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?

        init(store: PaletteScrollStore, key: String) {
            self.store = store
            self.key = key
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(_ scrollView: NSScrollView?) {
            guard let scrollView else { return }
            let isNew = self.scrollView !== scrollView
            if isNew {
                detach()
                self.scrollView = scrollView
                scrollView.contentView.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    self?.capture()
                }
            }
            if isNew {
                restoreNow()
            }
        }

        func restore(token: Int, keyChanged: Bool = false) {
            let tokenChanged = token != lastRestoreToken
            lastRestoreToken = token
            guard tokenChanged || keyChanged else { return }
            restoreNow()
        }

        func restoreNow() {
            isRestoring = true
            applySaved()
            DispatchQueue.main.async { [weak self] in
                self?.applySaved()
                DispatchQueue.main.async {
                    self?.isRestoring = false
                }
            }
        }

        private func capture() {
            guard !isRestoring, let scrollView else { return }
            store.setOffset(scrollView.contentView.bounds.origin, for: key)
        }

        private func applySaved() {
            guard let scrollView else { return }
            ScrollOffsetSupport.apply(store.offset(for: key), to: scrollView)
        }

        private func detach() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            scrollView = nil
        }
    }
}

final class PersistentScrollProbe: NSView {
    var coordinator: PersistentScrollOffset.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.attach(nearestScrollView())
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        coordinator?.attach(nearestScrollView())
    }

    override func layout() {
        super.layout()
        coordinator?.attach(nearestScrollView())
    }

    /// `enclosingScrollView` is nil when this probe is a List background
    /// sibling of the table scroller. Prefer the table's scroller so we don't
    /// latch onto the preview pane.
    func nearestScrollView() -> NSScrollView? {
        if let scroll = enclosingScrollView { return scroll }
        var node: NSView? = self
        var depth = 0
        while let view = node, depth < 8 {
            if let table = Self.firstTable(in: view) {
                return table.enclosingScrollView
            }
            if let scroll = view as? NSScrollView { return scroll }
            node = view.superview
            depth += 1
        }
        node = self
        depth = 0
        while let view = node, depth < 6 {
            if let scroll = Self.firstScrollView(in: view) { return scroll }
            node = view.superview
            depth += 1
        }
        return nil
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let scroll = firstScrollView(in: subview) { return scroll }
        }
        return nil
    }
}

enum ScrollOffsetSupport {
    static func apply(_ offset: CGPoint, to scrollView: NSScrollView) {
        guard let document = scrollView.documentView else { return }
        let clip = scrollView.contentView.bounds.size
        let doc = document.bounds.size
        let x = min(max(0, offset.x), max(0, doc.width - clip.width))
        let y = min(max(0, offset.y), max(0, doc.height - clip.height))
        var bounds = scrollView.contentView.bounds
        bounds.origin = NSPoint(x: x, y: y)
        scrollView.contentView.bounds = bounds
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

}

/// Scrolls a selected list row into view via AppKit. `ScrollViewReader` often
/// no-ops on the `NSTableView` behind a SwiftUI `List`.
private struct KeepSelectedRowVisibleHost: View {
    var selected: Bool
    @Environment(\.listRevealToken) private var token

    var body: some View {
        KeepSelectedRowVisible(selected: selected, token: token)
    }
}

private struct KeepSelectedRowVisible: NSViewRepresentable {
    var selected: Bool
    var token: Int

    func makeNSView(context: Context) -> KeepSelectedRowVisibleView {
        let view = KeepSelectedRowVisibleView()
        view.selected = selected
        view.lastToken = token
        return view
    }

    func updateNSView(_ nsView: KeepSelectedRowVisibleView, context: Context) {
        nsView.selected = selected
        let shouldReveal = selected && token != 0 && token != nsView.lastToken
        nsView.lastToken = token
        if shouldReveal {
            nsView.scheduleReveal()
        }
    }
}

final class KeepSelectedRowVisibleView: NSView {
    var selected = false
    var lastToken = 0
    private var attempts = 0

    func scheduleReveal() {
        attempts = 0
        reveal()
    }

    private func reveal() {
        guard selected else { return }
        if scrollIntoView() { return }
        attempts += 1
        guard attempts < 8 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reveal()
        }
    }

    @discardableResult
    private func scrollIntoView() -> Bool {
        guard selected, window != nil else { return false }
        if let table = enclosingTableView() {
            let row = table.row(for: self)
            if row >= 0 {
                if row > 0 { table.scrollRowToVisible(row - 1) }
                table.scrollRowToVisible(row)
                return true
            }
        }
        if enclosingScrollView != nil {
            scrollToVisible(bounds.insetBy(dx: 0, dy: -6))
            return true
        }
        return false
    }

    private func enclosingTableView() -> NSTableView? {
        var node: NSView? = self
        while let view = node {
            if let table = view as? NSTableView { return table }
            node = view.superview
        }
        return nil
    }
}

/// List-level fallback for jumps to rows that aren't materialized yet.
private struct ListTableScrollerHost: View {
    var row: Int?
    @Environment(\.listRevealToken) private var token

    var body: some View {
        ListTableScroller(row: row, token: token)
    }
}

private struct ListTableScroller: NSViewRepresentable {
    var row: Int?
    var token: Int

    func makeNSView(context: Context) -> ListTableScrollerView {
        let view = ListTableScrollerView()
        view.row = row
        view.lastToken = token
        return view
    }

    func updateNSView(_ nsView: ListTableScrollerView, context: Context) {
        nsView.row = row
        let shouldScroll = token != 0 && token != nsView.lastToken
        nsView.lastToken = token
        if shouldScroll {
            nsView.scheduleScroll()
        }
    }
}

final class ListTableScrollerView: NSView {
    var row: Int?
    var lastToken = 0
    private var attempts = 0

    func scheduleScroll() {
        attempts = 0
        scroll()
    }

    private func scroll() {
        guard let row else { return }
        if let table = nearestTable(), row >= 0, row < table.numberOfRows {
            if row > 0 { table.scrollRowToVisible(row - 1) }
            table.scrollRowToVisible(row)
            return
        }
        attempts += 1
        guard attempts < 8 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scroll()
        }
    }

    private func nearestTable() -> NSTableView? {
        var node: NSView? = self
        var depth = 0
        while let view = node, depth < 10 {
            if let table = firstTable(in: view) { return table }
            node = view.superview
            depth += 1
        }
        return nil
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }
}

/// Stops the AppKit table behind a SwiftUI `List` from becoming first responder
/// on click, which would swallow arrow keys and Delete.
struct RefuseListFirstResponder: NSViewRepresentable {
    func makeNSView(context: Context) -> RefuseListFirstResponderView {
        RefuseListFirstResponderView()
    }

    func updateNSView(_ nsView: RefuseListFirstResponderView, context: Context) {
        nsView.disableTableFirstResponder()
    }
}

final class RefuseListFirstResponderView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disableTableFirstResponder()
    }

    override func layout() {
        super.layout()
        disableTableFirstResponder()
    }

    func disableTableFirstResponder() {
        var node: NSView? = self
        while let view = node {
            if let table = Self.firstTable(in: view) {
                table.refusesFirstResponder = true
                table.selectionHighlightStyle = .none
                table.focusRingType = .none
                table.backgroundColor = .clear
                table.enclosingScrollView?.drawsBackground = false
                table.enclosingScrollView?.backgroundColor = .clear
                return
            }
            node = view.superview
        }
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }
}

extension View {
    func arrowFocus<F: Hashable>(_ focus: FocusState<F?>.Binding, equals value: F) -> some View {
        self
            .focusable()
            .focused(focus, equals: value)
            .modifier(ArrowFocusRingModifier())
    }

    /// Marks a List as the logical keyboard target without making the List
    /// itself first responder. Focusing the `List` hands keys to AppKit's
    /// table view, which swallows arrows (fighting SwiftUI navigation) and
    /// Delete (with no native selection to remove).
    func arrowListFocus<F: Hashable>(_ focus: FocusState<F?>.Binding, equals value: F) -> some View {
        self
            .focusEffectDisabled()
            .background(RefuseListFirstResponder().frame(width: 0, height: 0))
            .overlay(alignment: .topLeading) {
                KeyboardFocusSink()
                    .focused(focus, equals: value)
            }
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
            .background {
                KeepSelectedRowVisibleHost(selected: selected)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .focusEffectDisabled()
            .listRowBackground(KeyboardListRowChrome(isSelected: selected, isActive: active))
            .listRowSeparator(.hidden)
            .pointerStyle(.default)
    }

    func persistScrollOffset(store: PaletteScrollStore, key: String, restoreToken: Int) -> some View {
        background {
            PersistentScrollOffset(store: store, key: key, restoreToken: restoreToken)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Keeps the row identified by `target` visible whenever it changes.
    ///
    /// `List` doesn't support `.scrollPosition(id:)` — that modifier is
    /// `ScrollView`-only and is a silent no-op on a `List`. SwiftUI's
    /// `ScrollViewReader.scrollTo` is also unreliable on the AppKit table behind
    /// a macOS `List`, so this combines it with `NSTableView.scrollRowToVisible`.
    func scrollToVisible<T: Hashable>(
        target: T?,
        tableRow: Int? = nil,
        anchor: UnitPoint? = nil
    ) -> some View {
        ScrollViewReader { proxy in
            self
                .background {
                    ListTableScrollerHost(row: tableRow)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .onChange(of: target) { _, newValue in
                    guard let newValue else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(newValue, anchor: anchor)
                    }
                }
        }
    }

    func pointingHandCursor() -> some View {
        modifier(PointingHandOnHover())
    }

    /// Delete / ⌘Delete while `enabled` (typically: the list is the active stop
    /// and a text field is not editing). Disabled so the key reaches text fields.
    func keyboardDeleteFallback(enabled: Bool, action: @escaping () -> Void) -> some View {
        background {
            Group {
                Button(action: action) { EmptyView() }
                    .keyboardShortcut(.delete)
                Button(action: action) { EmptyView() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            .disabled(!enabled)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
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

/// ← from a page's left edge: sidebar when it's showing, otherwise the toggle.
func arrowExitForLeadingEdge(sidebarOpen: Bool) -> ArrowFocusExitDirection {
    sidebarOpen ? .previous : .chromeLeading
}

/// Maps a spatial-grid miss at the top or left edge onto chrome / sidebar.
func applyArrowEdgeExit(
    direction: SpatialDirection,
    currentIsLeading: Bool,
    sidebarOpen: Bool,
    exit: ((ArrowFocusExitDirection) -> Void)?
) {
    switch direction {
    case .up:
        exit?(currentIsLeading ? .chromeLeading : .chromeTrailing)
    case .left:
        exit?(arrowExitForLeadingEdge(sidebarOpen: sidebarOpen))
    default:
        break
    }
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
        .padding(.horizontal, LiquidGlassMetrics.pillPaddingH)
        .padding(.vertical, LiquidGlassMetrics.pillPaddingV)
        .liquidGlass(
            .interactive,
            in: Capsule(),
            fallback: .quaternary.opacity(0.55)
        )
        .contentShape(Capsule())
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
        folders: [(id: UUID, name: String)],
        currentFolderID: UUID?,
        addToFolder: @escaping (UUID) -> Void,
        addToNewFolder: @escaping () -> Void,
        togglePin: @escaping () -> Void,
        pinTitle: String,
        delete: @escaping () -> Void,
        relativeTo view: NSView? = nil
    ) {
        pop(buildMenu { add, separator, submenu in
            add("Copy", "c", .command, copy)
            add("Paste", "\r", [], paste)
            add("Add to Paste Stack", "v", [.command, .shift], addToStack)
            separator()
            add("Edit…", "e", .command, edit)
            add(bookmarkTitle, "b", .option, toggleBookmark)
            submenu("Add to Folder") { addItem, sep in
                appendFolderItems(
                    add: addItem,
                    separator: sep,
                    folders: folders,
                    currentFolderID: currentFolderID,
                    includeUnfiled: false,
                    select: { id in
                        if let id { addToFolder(id) }
                    },
                    newFolder: addToNewFolder
                )
            }
            add(pinTitle, "p", .option, togglePin)
            separator()
            add("Delete", "\u{08}", .command, delete)
        }, relativeTo: view)
    }

    static func popBookmark(
        copy: @escaping () -> Void,
        paste: @escaping () -> Void,
        edit: @escaping () -> Void,
        folders: [(id: UUID, name: String)],
        currentFolderID: UUID?,
        moveToFolder: @escaping (UUID?) -> Void,
        moveToNewFolder: @escaping () -> Void,
        remove: @escaping () -> Void,
        relativeTo view: NSView? = nil
    ) {
        pop(buildMenu { add, separator, submenu in
            add("Copy", "c", .command, copy)
            add("Paste", "\r", [], paste)
            separator()
            add("Edit…", "e", .command, edit)
            submenu("Move to Folder") { addItem, sep in
                appendFolderItems(
                    add: addItem,
                    separator: sep,
                    folders: folders,
                    currentFolderID: currentFolderID,
                    includeUnfiled: true,
                    select: moveToFolder,
                    newFolder: moveToNewFolder
                )
            }
            add("Remove Bookmark", "\u{08}", .command, remove)
        }, relativeTo: view)
    }

    static func popFolderMenu(
        folders: [(id: UUID, name: String)],
        currentFolderID: UUID?,
        includeUnfiled: Bool,
        select: @escaping (UUID?) -> Void,
        newFolder: @escaping () -> Void,
        relativeTo view: NSView? = nil
    ) {
        pop(buildMenu { add, separator, _ in
            appendFolderItems(
                add: add,
                separator: separator,
                folders: folders,
                currentFolderID: currentFolderID,
                includeUnfiled: includeUnfiled,
                select: select,
                newFolder: newFolder
            )
        }, relativeTo: view)
    }

    private static func appendFolderItems(
        add: (String, String, NSEvent.ModifierFlags, @escaping () -> Void) -> Void,
        separator: () -> Void,
        folders: [(id: UUID, name: String)],
        currentFolderID: UUID?,
        includeUnfiled: Bool,
        select: @escaping (UUID?) -> Void,
        newFolder: @escaping () -> Void
    ) {
        if includeUnfiled {
            add(currentFolderID == nil ? "✓ Unfiled" : "Unfiled", "", [], { select(nil) })
            if !folders.isEmpty { separator() }
        }
        for folder in folders {
            let title = folder.id == currentFolderID ? "✓ \(folder.name)" : folder.name
            add(title, "", [], { select(folder.id) })
        }
        if includeUnfiled || !folders.isEmpty { separator() }
        add("New Folder…", "", [], newFolder)
    }

    static func popCategoryFilter(
        current: ClipboardCategory?,
        select: @escaping (ClipboardCategory?) -> Void,
        relativeTo view: NSView? = nil
    ) {
        pop(buildMenu { add, separator, _ in
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
        pop(buildMenu { add, separator, _ in
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
        pop(buildMenu { add, _, _ in
            for choice in choices {
                let label = title(choice)
                add(current == choice ? "✓ \(label)" : label, "", [], { select(choice) })
            }
        }, relativeTo: view)
    }

    private static func buildMenu(
        _ build: (
            _ add: (String, String, NSEvent.ModifierFlags, @escaping () -> Void) -> Void,
            _ separator: () -> Void,
            _ submenu: (String, (
                _ add: (String, String, NSEvent.ModifierFlags, @escaping () -> Void) -> Void,
                _ separator: () -> Void
            ) -> Void) -> Void
        ) -> Void
    ) -> NSMenu {
        let actions = MenuActions()
        keepAlive = actions
        let menu = NSMenu()
        menu.autoenablesItems = false
        var tag = 1

        func addItem(
            to target: NSMenu,
            _ title: String,
            _ key: String,
            _ mask: NSEvent.ModifierFlags,
            _ handler: @escaping () -> Void
        ) {
            let item = NSMenuItem(title: title, action: #selector(MenuActions.invoke(_:)), keyEquivalent: key)
            item.target = actions
            item.keyEquivalentModifierMask = mask
            item.tag = tag
            actions.handlers[tag] = handler
            tag += 1
            target.addItem(item)
        }

        func add(_ title: String, _ key: String, _ mask: NSEvent.ModifierFlags, _ handler: @escaping () -> Void) {
            addItem(to: menu, title, key, mask, handler)
        }

        func submenu(
            _ title: String,
            _ nest: (
                _ add: (String, String, NSEvent.ModifierFlags, @escaping () -> Void) -> Void,
                _ separator: () -> Void
            ) -> Void
        ) {
            let child = NSMenu()
            child.autoenablesItems = false
            nest(
                { title, key, mask, handler in addItem(to: child, title, key, mask, handler) },
                { child.addItem(.separator()) }
            )
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = child
            menu.addItem(item)
        }

        build(add, { menu.addItem(.separator()) }, submenu)
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

struct BookmarkFolderPickerButtons: View {
    let folders: [BookmarkFolder]
    var currentFolderID: UUID?
    var allowUnfiled: Bool = false
    let onPick: (BookmarkFolder?) -> Void
    let onNew: () -> Void

    var body: some View {
        if allowUnfiled {
            Button {
                onPick(nil)
            } label: {
                folderLabel("Unfiled", selected: currentFolderID == nil)
            }
            if !folders.isEmpty { Divider() }
        }
        ForEach(folders) { folder in
            Button {
                onPick(folder)
            } label: {
                folderLabel(folder.name, selected: folder.id == currentFolderID)
            }
        }
        if allowUnfiled || !folders.isEmpty { Divider() }
        Button("New Folder…", action: onNew)
    }

    @ViewBuilder
    private func folderLabel(_ name: String, selected: Bool) -> some View {
        if selected {
            Text("✓ \(name)")
        } else {
            Text(name)
        }
    }
}

struct FolderNameAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    var title: String
    @Binding var name: String
    var confirmTitle: String = "Create"
    var onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            TextField("Folder name", text: $name)
            Button(confirmTitle, action: onConfirm)
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
    }
}

extension View {
    func folderNameAlert(
        isPresented: Binding<Bool>,
        title: String,
        name: Binding<String>,
        confirmTitle: String = "Create",
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(
            FolderNameAlertModifier(
                isPresented: isPresented,
                title: title,
                name: name,
                confirmTitle: confirmTitle,
                onConfirm: onConfirm
            )
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
///
/// The input is still bounded to `previewCharacterLimit`: in the real panel the
/// initial layout + scroll-view content sizing of a 10MB+ document blocked the
/// main thread for seconds. A bounded head renders instantly; the full content
/// is always available through Copy/Paste.
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String
    var scrollStore: PaletteScrollStore? = nil
    var scrollKey: String? = nil
    var restoreToken: Int = 0

    static let previewCharacterLimit = 100_000

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
        context.coordinator.attach(scrollView, store: scrollStore, key: scrollKey)
        context.coordinator.restore(scrollView, store: scrollStore, key: scrollKey)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.attach(scrollView, store: scrollStore, key: scrollKey)
        // Only replace when the item actually changed — avoids relayout churn on
        // every SwiftUI body evaluation.
        let display = Self.bounded(text)
        let textChanged = textView.string != display
        if textChanged {
            textView.string = display
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        let tokenChanged = context.coordinator.lastRestoreToken != restoreToken
        context.coordinator.lastRestoreToken = restoreToken
        if textChanged || tokenChanged {
            context.coordinator.restore(scrollView, store: scrollStore, key: scrollKey)
        }
    }

    final class Coordinator: @unchecked Sendable {
        var lastRestoreToken = -1
        var isRestoring = false
        private var observer: NSObjectProtocol?
        private var key: String?

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(_ scrollView: NSScrollView, store: PaletteScrollStore?, key: String?) {
            self.key = key
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            guard let store, let key else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView, !self.isRestoring else { return }
                store.setOffset(scrollView.contentView.bounds.origin, for: key)
            }
        }

        func restore(_ scrollView: NSScrollView, store: PaletteScrollStore?, key: String?) {
            let offset = (store != nil && key != nil) ? store!.offset(for: key!) : .zero
            isRestoring = true
            if offset == .zero {
                (scrollView.documentView as? NSTextView)?.scrollToBeginningOfDocument(nil)
            } else {
                ScrollOffsetSupport.apply(offset, to: scrollView)
            }
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                if offset == .zero {
                    (scrollView.documentView as? NSTextView)?.scrollToBeginningOfDocument(nil)
                } else {
                    ScrollOffsetSupport.apply(offset, to: scrollView)
                }
                DispatchQueue.main.async {
                    self.isRestoring = false
                }
            }
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
    var scrollStore: PaletteScrollStore? = nil
    var scrollKey: String? = nil
    var restoreToken: Int = 0

    private var isTruncated: Bool {
        charCount > ReadOnlyTextView.previewCharacterLimit
    }

    var body: some View {
        VStack(spacing: 0) {
            ReadOnlyTextView(
                text: text,
                scrollStore: scrollStore,
                scrollKey: scrollKey,
                restoreToken: restoreToken
            )
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

// MARK: - Detail action buttons & toasts

struct ScaleOnPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

struct DetailIconButton: View {
    let systemName: String
    let help: String
    var tint: Color? = nil
    var isActive: Bool = false
    var flashSuccess: Bool = false
    let action: () -> Void

    @State private var hovering = false

    private var iconName: String {
        flashSuccess ? "checkmark" : systemName
    }

    private var iconTint: Color {
        if flashSuccess { return .green }
        if let tint { return tint }
        return Color.primary.opacity(0.85)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: LiquidGlassMetrics.iconFont, weight: .semibold))
                .foregroundStyle(iconTint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isActive)
                .frame(width: LiquidGlassMetrics.iconButtonSize, height: LiquidGlassMetrics.iconButtonSize)
                .liquidGlass(
                    .interactive,
                    in: RoundedRectangle(cornerRadius: LiquidGlassMetrics.iconRadius, style: .continuous),
                    fallback: isActive || flashSuccess ? iconTint.opacity(0.18) : Color.primary.opacity(0.10)
                )
                .overlay {
                    if !LiquidGlass.isSupported {
                        RoundedRectangle(cornerRadius: LiquidGlassMetrics.iconRadius, style: .continuous)
                            .strokeBorder(isActive || flashSuccess ? iconTint.opacity(0.4) : Color.primary.opacity(0.08))
                    }
                }
                .scaleEffect(hovering ? 1.08 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.62), value: hovering)
                .animation(.spring(response: 0.3, dampingFraction: 0.68), value: isActive)
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: flashSuccess)
        }
        .buttonStyle(ScaleOnPressButtonStyle())
        .pointingHandCursor()
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

struct ActionFeedbackToast: View {
    let kind: HistoryActionKind

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.systemImage)
                .foregroundStyle(kind.tint)
                .symbolEffect(.bounce, value: kind)
            Text(kind.title)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liquidGlass(.regular, in: Capsule())
        .overlay {
            if !LiquidGlass.isSupported {
                Capsule().strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .shadow(color: .black.opacity(LiquidGlass.isSupported ? 0.12 : 0.2), radius: LiquidGlass.isSupported ? 8 : 10, y: 3)
    }
}

extension HistoryActionKind {
    var title: String {
        switch self {
        case .copied: "Copied to clipboard"
        case .pasted: "Pasted"
        case .bookmarked: "Bookmarked"
        case .unbookmarked: "Bookmark removed"
        case .pinned: "Pinned to top"
        case .unpinned: "Unpinned"
        }
    }

    var systemImage: String {
        switch self {
        case .copied, .pasted: "checkmark.circle.fill"
        case .bookmarked: "bookmark.fill"
        case .unbookmarked: "bookmark"
        case .pinned: "pin.fill"
        case .unpinned: "pin"
        }
    }

    var tint: Color {
        switch self {
        case .copied, .pasted: .green
        case .bookmarked: .accentColor
        case .unbookmarked: .secondary
        case .pinned: .orange
        case .unpinned: .secondary
        }
    }
}
