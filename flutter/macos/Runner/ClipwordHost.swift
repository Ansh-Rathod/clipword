import AppKit
import ClipwordCore
import Cocoa
import Defaults
import FlutterMacOS
import KeyboardShortcuts
import SwiftData
import UniformTypeIdentifiers

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ClipwordHost: NSObject, NSWindowDelegate, NSMenuDelegate {
    static let shared = ClipwordHost()

    static let paletteSize = NSSize(width: 720, height: 520)
    static let settingsSize = NSSize(width: 820, height: 580)
    static let cornerRadius: CGFloat = 24
    static let pageSize = 80

    private var container: ModelContainer?
    private(set) var historyStore: HistoryStore?
    private let searchService = SearchService()
    private let clipboardMonitor = ClipboardMonitor()
    private var channel: FlutterMethodChannel?
    private var events: FlutterEventSink?
    private var settingsChannel: FlutterMethodChannel?
    fileprivate var settingsEvents: FlutterEventSink?
    private var statusItem: NSStatusItem?
    private weak var flutterWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsViewController: FlutterViewController?
    private var settingsEngine: FlutterEngine?
    private lazy var settingsStreamHandler = SettingsStreamHandler(host: self)
    private var settingsSection = "general"
    private var windowMode = "hidden"
    private var paletteSource = "history"
    private var collapsedFolderIDs: Set<UUID> = []
    private var historySelection: [String: String]?
    private var bookmarksSelection: [String: String]?
    private var selection: [String: String]? {
        get { paletteSource == "bookmarks" ? bookmarksSelection : historySelection }
        set {
            if paletteSource == "bookmarks" {
                bookmarksSelection = newValue
            } else {
                historySelection = newValue
            }
        }
    }
    private var suppressFocusLossHide = false
    private var lastLeftClick = Date.distantPast
    private var pasteStackMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var outsideClickMonitor: Any?
    private var lastToggleAt = Date.distantPast
    private var pendingMenuAction: (() -> Void)?
    private var iconCache: [String: FlutterStandardTypedData] = [:]
    private var menuKeepAlive: MenuActions?

    func attach(window: NSWindow, messenger: FlutterBinaryMessenger) {
        flutterWindow = window
        let channel = FlutterMethodChannel(name: "clipword", binaryMessenger: messenger)
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                self?.handle(call, result: result)
            }
        }
        let eventChannel = FlutterEventChannel(name: "clipword/events", binaryMessenger: messenger)
        eventChannel.setStreamHandler(self)
        bootstrap()
        installStatusItem()
        configureWindow(window)
        registerHotkey()
        NSApp.setActivationPolicy(.accessory)
        hidePalette()
    }

    private func bootstrap() {
        if !Defaults[.didSetDefaultIgnoredApps] {
            var apps = Defaults[.ignoredApps]
            for bundleId in Defaults.Keys.defaultIgnoredAppBundleIDs where !apps.contains(bundleId) {
                apps.append(bundleId)
            }
            Defaults[.ignoredApps] = apps
            Defaults[.didSetDefaultIgnoredApps] = true
        }

        let schema = Schema([
            HistoryItem.self,
            ClipboardEvent.self,
            WordFrequency.self,
            DailyStats.self,
            BookmarkItem.self,
            BookmarkFolder.self,
        ])
        let url = AppSupport.directory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: AppSupport.storeURL)
        let container = try! ModelContainer(for: schema, configurations: config)
        self.container = container
        let store = HistoryStore(modelContext: container.mainContext)
        historyStore = store
        store.applyFilters(using: searchService)
        collapsedFolderIDs = Set(Defaults[.collapsedFolderIDs].compactMap(UUID.init(uuidString:)))

        clipboardMonitor.onNewCopy = { [weak self] pasteboard in
            store.addFromPasteboard(pasteboard)
            store.applyFilters(using: self?.searchService)
            self?.emitSnapshot()
        }
        clipboardMonitor.start()
        registerPasteStackMonitor()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hideBecauseFocusLeft()
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.windowMode == "palette", !self.suppressFocusLossHide else { return }
                self.hidePalette()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setMenuTracking(true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setMenuTracking(false)
            }
        }
    }

    private func setMenuTracking(_ tracking: Bool) {
        events?(["type": "menuTracking", "payload": tracking])
        channel?.invokeMethod("onMenuTracking", arguments: tracking)
    }

    private func registerHotkey() {
        if let value = UserDefaults.clipword.object(forKey: "KeyboardShortcuts_openClipword") {
            UserDefaults.standard.set(value, forKey: "KeyboardShortcuts_openClipword")
        }
        KeyboardShortcuts.onKeyUp(for: .openClipword) { [weak self] in
            Task { @MainActor in
                self?.togglePalette()
            }
        }
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.windowMode == "palette" || self.settingsWindow?.isVisible == true else {
                return event
            }
            guard let pressed = KeyboardShortcuts.Shortcut(event: event),
                  pressed == KeyboardShortcuts.getShortcut(for: .openClipword)
            else {
                return event
            }
            self.togglePalette()
            return nil
        }
    }

    private func registerPasteStackMonitor() {
        guard PasteService.isAccessibilityTrusted else { return }
        pasteStackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let self else { return }
            Task { @MainActor in
                if let store = self.historyStore, !store.pasteStack.isEmpty {
                    store.handlePasteStackPop()
                    self.emitSnapshot()
                }
            }
        }
    }

    // MARK: Window

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        applyPaletteChrome(window)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window.setFrame(centeredFrame(size: Self.paletteSize, on: screen.visibleFrame), display: false)
        window.orderOut(nil)
    }

    private func applyPaletteChrome(_ window: NSWindow) {
        window.styleMask = [.borderless, .fullSizeContentView]
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(Self.paletteSize)
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = Self.cornerRadius
        window.contentView?.layer?.cornerCurve = .continuous
        window.contentView?.layer?.masksToBounds = true
        if let panel = window as? NSPanel {
            panel.isFloatingPanel = true
        }
    }

    private func applySettingsChrome(_ window: NSWindow) {
        window.level = .normal
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.setContentSize(Self.settingsSize)
        window.contentView?.layer?.cornerRadius = 0
        window.center()
    }

    func togglePalette(source: String? = nil) {
        let now = Date()
        guard now.timeIntervalSince(lastToggleAt) > 0.2 else { return }
        lastToggleAt = now
        if windowMode == "palette" {
            if let source, source != paletteSource {
                paletteSource = source
                emitSnapshot()
                return
            }
            hidePalette()
            return
        }
        showPalette(source: source)
    }

    func showPalette(source: String? = nil, fromStatusItem: Bool = false) {
        NSApp.setActivationPolicy(.accessory)
        if let source { paletteSource = source }
        guard let window = flutterWindow else { return }
        PasteSession.captureFrontmost()
        suppressFocusLossHide = true
        windowMode = "palette"
        applyPaletteChrome(window)
        positionPalette(window, fromStatusItem: fromStatusItem)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        focusFlutter(window)
        emitWindowMode()
        emitSnapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.positionPalette(window, fromStatusItem: fromStatusItem)
            self.focusFlutter(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.suppressFocusLossHide = false
        }
    }

    private func focusFlutter(_ window: NSWindow) {
        window.makeKey()
        if let view = window.contentViewController?.view {
            window.makeFirstResponder(view)
        }
    }

    func showSettings(section: String = "general") {
        settingsSection = section
        hidePalette()
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            emitSnapshot()
            return
        }

        let engine = FlutterEngine(name: "clipword.settings", project: nil)
        bindSettings(engine.binaryMessenger)
        engine.run(withEntrypoint: "settingsMain")
        let settingsController = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
        RegisterGeneratedPlugins(registry: settingsController)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.settingsSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 640, height: 420)
        window.contentViewController = settingsController
        window.delegate = self
        applySettingsChrome(window)
        settingsEngine = engine
        settingsViewController = settingsController
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        emitSnapshot()
    }

    private func bindSettings(_ messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "clipword", binaryMessenger: messenger)
        settingsChannel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                self?.handle(call, result: result)
            }
        }
        let eventChannel = FlutterEventChannel(name: "clipword/events", binaryMessenger: messenger)
        eventChannel.setStreamHandler(settingsStreamHandler)
    }

    func hidePalette() {
        if let window = flutterWindow {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
        }
        windowMode = "hidden"
        emitWindowMode()
    }

    private func hideBecauseFocusLeft() {
        guard !suppressFocusLossHide else { return }
        guard windowMode == "palette" else { return }
        hidePalette()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === flutterWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.windowMode == "palette" else { return }
            if self.flutterWindow?.attachedSheet != nil { return }
            guard !self.suppressFocusLossHide else { return }
            guard !NSApp.isActive else { return }
            self.hideBecauseFocusLeft()
        }
    }

    private func positionPalette(_ window: NSWindow, fromStatusItem: Bool) {
        let size = Self.paletteSize
        let screen = screenForPlacement(preferStatusItem: fromStatusItem)
        let visible = screen.visibleFrame
        let frame: NSRect
        if fromStatusItem, let nearMenu = frameNearStatusItem(size: size) {
            frame = nearMenu
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
            case .lastPosition:
                let stored = NSRectFromString(Defaults[.popupLastFrame])
                if stored.width > 0 && stored.height > 0 {
                    frame = clamped(stored, size: size, to: visible)
                } else {
                    frame = centeredFrame(size: size, on: visible)
                }
            case .center:
                frame = centeredFrame(size: size, on: visible)
            }
        }
        window.setFrame(frame, display: true)
    }

    private func screenForPlacement(preferStatusItem: Bool) -> NSScreen {
        if preferStatusItem, let screen = statusItem?.button?.window?.screen {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func frameNearStatusItem(size: NSSize) -> NSRect? {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return nil }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = buttonRect.midX - size.width / 2
        var y = buttonRect.minY - size.height - 8
        if let screen {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            if y < visible.minY {
                y = buttonRect.maxY + 8
            }
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func centeredFrame(size: NSSize, on visible: NSRect) -> NSRect {
        NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func clamped(_ frame: NSRect, size: NSSize, to visible: NSRect) -> NSRect {
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(origin: origin, size: size)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow {
            sender.orderOut(nil)
            return false
        }
        sender.orderOut(nil)
        windowMode = "hidden"
        emitWindowMode()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === flutterWindow else { return }
        guard windowMode == "palette", let window = flutterWindow else { return }
        Defaults[.popupLastFrame] = NSStringFromRect(window.frame)
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipword")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let type = NSApp.currentEvent?.type
        if type == .rightMouseDown || type == .rightMouseUp {
            showStatusMenu()
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastLeftClick) < 0.3 { return }
        lastLeftClick = now
        togglePalette()
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(statusItem("Clipboard", "doc.on.clipboard", #selector(openClipboard)))
        menu.addItem(statusItem("Bookmarks", "bookmark", #selector(openBookmarks)))
        menu.addItem(.separator())
        menu.addItem(statusItem("Settings…", "gear", #selector(openSettings)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Clipword", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        statusItem?.menu = nil
        let action = pendingMenuAction
        pendingMenuAction = nil
        DispatchQueue.main.async {
            action?()
        }
    }

    private func statusItem(_ title: String, _ image: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: image, accessibilityDescription: title)
        return item
    }

    @objc private func openClipboard() {
        pendingMenuAction = { [weak self] in self?.showPalette(source: "history") }
    }
    @objc private func openBookmarks() {
        pendingMenuAction = { [weak self] in self?.showPalette(source: "bookmarks") }
    }
    @objc private func openSettings() {
        pendingMenuAction = { [weak self] in self?.showSettings() }
    }
    @objc private func quitApp() {
        if Defaults[.clearOnQuit] {
            historyStore?.clear(unpinnedOnly: false)
        }
        NSApp.terminate(nil)
    }

    // MARK: Channel

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let store = historyStore else {
            result(FlutterError(code: "no_store", message: "Store not ready", details: nil))
            return
        }
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "snapshot":
            result(snapshotDict())
        case "loadItems":
            let offset = max(0, args["offset"] as? Int ?? 0)
            let limit = min(500, max(1, args["limit"] as? Int ?? Self.pageSize))
            let displayed = store.displayedItems
            let page = displayed.dropFirst(min(offset, displayed.count)).prefix(limit)
            result([
                "items": page.map(Self.encodeHistory),
                "itemCount": displayed.count,
                "listRevision": store.listRevision,
            ])
        case "setSearch":
            store.searchQuery = args["query"] as? String ?? ""
            store.applyFilters(using: searchService)
            emitSnapshot()
            result(nil)
        case "setCategory":
            let raw = args["category"] as? String
            store.setCategoryFilter(raw.flatMap(ClipboardCategory.init(rawValue:)))
            store.applyFilters(using: searchService)
            emitSnapshot()
            result(nil)
        case "setAppFilter":
            store.setAppFilter(args["bundleId"] as? String)
            store.applyFilters(using: searchService)
            emitSnapshot()
            result(nil)
        case "setTimeFilter":
            store.setTimeFilter(Self.decodeTimeFilter(args))
            store.applyFilters(using: searchService)
            emitSnapshot()
            result(nil)
        case "setSource":
            paletteSource = args["source"] as? String ?? "history"
            pruneSelection()
            emitSnapshot()
            result(nil)
        case "select":
            selection = [
                "kind": args["kind"] as? String ?? "",
                "id": args["id"] as? String ?? "",
            ]
            result(nil)
        case "setCollapsedFolders":
            let ids = (args["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            collapsedFolderIDs = Set(ids)
            persistCollapsedFolders()
            emitSnapshot()
            result(nil)
        case "activate":
            let paste = args["paste"] as? Bool ?? false
            let unformatted = args["withoutFormatting"] as? Bool ?? false
            activateSelection(store: store, paste: paste, withoutFormatting: unformatted)
            result(nil)
        case "togglePin":
            if let item = historyItem(store, args["id"] as? String) {
                store.togglePin(item)
                emitSnapshot()
            }
            result(nil)
        case "toggleBookmark":
            if let item = historyItem(store, args["id"] as? String) {
                store.toggleBookmark(item)
                emitSnapshot()
            } else if let bookmark = bookmarkItem(store, args["id"] as? String) {
                store.deleteBookmark(bookmark)
                emitSnapshot()
            }
            result(nil)
        case "delete":
            deleteSelection(store: store, args: args)
            result(nil)
        case "addToStack":
            if let item = historyItem(store, args["id"] as? String) {
                store.addToPasteStack(item)
            }
            result(nil)
        case "editContent":
            let content = args["content"] as? String ?? ""
            if let item = historyItem(store, args["id"] as? String) {
                store.updateContent(item, content: content)
            } else if let bookmark = bookmarkItem(store, args["id"] as? String) {
                store.updateBookmarkContent(bookmark, content: content)
            }
            emitSnapshot()
            result(nil)
        case "createFolder":
            let folder = store.createFolder(named: args["name"] as? String ?? "Untitled")
            if let historyID = args["historyId"] as? String, let item = historyItem(store, historyID) {
                store.bookmark(item, in: folder)
            } else if let bookmarkID = args["bookmarkId"] as? String, let item = bookmarkItem(store, bookmarkID) {
                store.moveBookmark(item, to: folder)
            }
            emitSnapshot()
            result(folder.id.uuidString)
        case "renameFolder":
            if let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)),
               let folder = store.folder(id: id) {
                store.renameFolder(folder, to: args["name"] as? String ?? "")
                emitSnapshot()
            }
            result(nil)
        case "deleteFolder":
            if let id = (args["id"] as? String).flatMap(UUID.init(uuidString:)),
               let folder = store.folder(id: id) {
                store.deleteFolder(folder)
                emitSnapshot()
            }
            result(nil)
        case "bookmarkInFolder":
            if let item = historyItem(store, args["historyId"] as? String) {
                let folder = (args["folderId"] as? String).flatMap(UUID.init(uuidString:)).flatMap(store.folder(id:))
                store.bookmark(item, in: folder)
                emitSnapshot()
            }
            result(nil)
        case "moveBookmark":
            if let item = bookmarkItem(store, args["bookmarkId"] as? String) {
                let folder = (args["folderId"] as? String).flatMap(UUID.init(uuidString:)).flatMap(store.folder(id:))
                store.moveBookmark(item, to: folder)
                emitSnapshot()
            }
            result(nil)
        case "showItemMenu":
            showItemMenu(store: store, args: args)
            result(nil)
        case "showFilterMenu":
            showFilterMenu(store: store)
            result(nil)
        case "showChoices":
            showChoices(args: args, result: result)
        case "showSettings":
            showSettings(section: args["section"] as? String ?? settingsSection)
            result(nil)
        case "hideWindow":
            hidePalette()
            result(nil)
        case "showWindow":
            showPalette(source: args["source"] as? String)
            result(nil)
        case "quit":
            quitApp()
            result(nil)
        case "prefsSet":
            applyPrefs(args)
            store.applyFilters(using: searchService)
            if args["historyRetention"] != nil { store.pruneByRetention(); store.reload() }
            if args["historySize"] != nil { store.prune(); store.reload() }
            emitSnapshot()
            result(nil)
        case "requestAccessibility":
            PasteService.requestAccessibility()
            result(PasteService.isAccessibilityTrusted)
        case "pickIgnoredApps":
            result(pickIgnoredApps())
        case "clearPreviewCache":
            Task {
                await LinkPreviewService.shared.clearCache()
                result(LinkPreviewService.cacheSizeDescription)
            }
        case "itemDetail":
            result(itemDetail(store: store, args: args))
        case "linkPreview":
            guard let urlString = args["url"] as? String, let url = URL(string: urlString) else {
                result(nil)
                return
            }
            Task {
                let record = await LinkPreviewService.shared.preview(for: url)
                result(Self.encodePreview(record))
            }
        case "symbolImage":
            result(symbolPNG(args["name"] as? String ?? "", size: args["size"] as? Double ?? 16))
        case "appIcon":
            result(appIconPNG(args["bundleId"] as? String, size: args["size"] as? Double ?? 16))
        case "openUrl":
            if let urlString = args["url"] as? String, let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
            result(nil)
        case "setSettingsSection":
            settingsSection = args["section"] as? String ?? "general"
            emitSnapshot()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func activateSelection(store: HistoryStore, paste: Bool, withoutFormatting: Bool) {
        guard let selection else { return }
        let kind = selection["kind"]
        let id = selection["id"]
        if kind == "history", let item = historyItem(store, id) {
            store.select(item, paste: paste, withoutFormatting: withoutFormatting)
            emitSnapshot()
            if paste { hidePalette() }
        } else if kind == "bookmark", let item = bookmarkItem(store, id) {
            store.selectBookmark(item, paste: paste, withoutFormatting: withoutFormatting)
            emitSnapshot()
            if paste { hidePalette() }
        }
    }

    private func deleteSelection(store: HistoryStore, args: [String: Any]) {
        let kind = args["kind"] as? String ?? selection?["kind"]
        let id = args["id"] as? String ?? selection?["id"]
        if kind == "history", let item = historyItem(store, id) {
            store.delete(item)
        } else if kind == "bookmark", let item = bookmarkItem(store, id) {
            store.deleteBookmark(item)
        } else if kind == "folder", let uuid = id.flatMap(UUID.init(uuidString:)), let folder = store.folder(id: uuid) {
            store.deleteFolder(folder)
        }
        emitSnapshot()
    }

    private func historyItem(_ store: HistoryStore, _ id: String?) -> HistoryItem? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return store.items.first { $0.id == uuid } ?? store.displayedItems.first { $0.id == uuid }
    }

    private func bookmarkItem(_ store: HistoryStore, _ id: String?) -> BookmarkItem? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return store.bookmarks.first { $0.id == uuid }
    }

    // MARK: Menus

    private func showItemMenu(store: HistoryStore, args: [String: Any]) {
        let kind = args["kind"] as? String ?? selection?["kind"] ?? ""
        let id = args["id"] as? String ?? selection?["id"]
        let folders = store.folders.map { (id: $0.id, name: $0.name) }
        let origin: NSPoint?
        if let x = args["x"] as? Double, let y = args["y"] as? Double {
            origin = NSPoint(x: x, y: y)
        } else {
            origin = nil
        }
        if kind == "history", let item = historyItem(store, id) {
            let currentFolder = store.folder(forHistoryItem: item)?.id
            popHistoryMenu(item: item, store: store, folders: folders, currentFolderID: currentFolder, at: origin)
        } else if kind == "bookmark", let item = bookmarkItem(store, id) {
            popBookmarkMenu(item: item, store: store, folders: folders, at: origin)
        } else if kind == "folder", let uuid = id.flatMap(UUID.init(uuidString:)), let folder = store.folder(id: uuid) {
            popFolderMenu(folder: folder, store: store, at: origin)
        }
    }

    private func popHistoryMenu(
        item: HistoryItem,
        store: HistoryStore,
        folders: [(id: UUID, name: String)],
        currentFolderID: UUID?,
        at origin: NSPoint?
    ) {
        popMenu(at: origin) { add, separator, submenu in
            add("Copy", "c", .command) { store.select(item, paste: false); self.emitSnapshot() }
            add("Paste", "", []) {
                store.select(item, paste: true)
                self.emitSnapshot()
                self.hidePalette()
            }
            add("Add to Paste Stack", "v", [.command, .shift]) { store.addToPasteStack(item) }
            separator()
            add("Edit…", "e", .command) { self.channel?.invokeMethod("edit", arguments: ["kind": "history", "id": item.id.uuidString]) }
            add(item.isBookmarked ? "Remove Bookmark" : "Bookmark", "b", .option) {
                store.toggleBookmark(item)
                self.emitSnapshot()
            }
            submenu("Add to Folder") { addItem, sep in
                for folder in folders {
                    let title = folder.id == currentFolderID ? "✓ \(folder.name)" : folder.name
                    addItem(title, "", []) {
                        store.bookmark(item, in: store.folder(id: folder.id))
                        self.emitSnapshot()
                    }
                }
                if !folders.isEmpty { sep() }
                addItem("New Folder…", "", []) {
                    self.channel?.invokeMethod("newFolder", arguments: ["historyId": item.id.uuidString])
                }
            }
            add(item.isPinned ? "Unpin" : "Pin", "p", .option) {
                store.togglePin(item)
                self.emitSnapshot()
            }
            separator()
            add("Delete", "\u{08}", .command) {
                store.delete(item)
                self.emitSnapshot()
            }
        }
    }

    private func popBookmarkMenu(
        item: BookmarkItem,
        store: HistoryStore,
        folders: [(id: UUID, name: String)],
        at origin: NSPoint?
    ) {
        popMenu(at: origin) { add, separator, submenu in
            add("Copy", "c", .command) { store.selectBookmark(item, paste: false) }
            add("Paste", "", []) {
                store.selectBookmark(item, paste: true)
                self.hidePalette()
            }
            separator()
            add("Edit…", "e", .command) {
                self.channel?.invokeMethod("edit", arguments: ["kind": "bookmark", "id": item.id.uuidString])
            }
            submenu("Move to Folder") { addItem, sep in
                addItem(item.folder == nil ? "✓ Unfiled" : "Unfiled", "", []) {
                    store.moveBookmark(item, to: nil)
                    self.emitSnapshot()
                }
                if !folders.isEmpty { sep() }
                for folder in folders {
                    let title = folder.id == item.folder?.id ? "✓ \(folder.name)" : folder.name
                    addItem(title, "", []) {
                        store.moveBookmark(item, to: store.folder(id: folder.id))
                        self.emitSnapshot()
                    }
                }
                sep()
                addItem("New Folder…", "", []) {
                    self.channel?.invokeMethod("newFolder", arguments: ["bookmarkId": item.id.uuidString])
                }
            }
            add("Remove Bookmark", "\u{08}", .command) {
                store.deleteBookmark(item)
                self.emitSnapshot()
            }
        }
    }

    private func popFolderMenu(folder: BookmarkFolder, store: HistoryStore, at origin: NSPoint?) {
        let collapsed = collapsedFolderIDs.contains(folder.id)
        popMenu(at: origin) { add, separator, _ in
            add(collapsed ? "Expand" : "Collapse", "", []) {
                if self.collapsedFolderIDs.contains(folder.id) {
                    self.collapsedFolderIDs.remove(folder.id)
                } else {
                    self.collapsedFolderIDs.insert(folder.id)
                }
                self.persistCollapsedFolders()
                self.emitSnapshot()
            }
            add("Rename…", "", []) {
                self.channel?.invokeMethod("renameFolder", arguments: ["id": folder.id.uuidString, "name": folder.name])
            }
            separator()
            add("Delete Folder", "", []) {
                store.deleteFolder(folder)
                self.emitSnapshot()
            }
        }
    }

    private func showFilterMenu(store: HistoryStore) {
        popMenu { add, separator, submenu in
            if store.activeCategory != nil || store.activeAppBundleId != nil || store.timeFilter.isActive {
                add("Clear Filters", "", []) {
                    store.activeCategory = nil
                    store.activeAppBundleId = nil
                    store.timeFilter = .any
                    store.applyFilters(using: self.searchService)
                    self.emitSnapshot()
                }
                separator()
            }
            submenu("When") { addItem, sep in
                let options: [(String, HistoryTimeFilter)] = [
                    ("Any time", .any),
                    ("Today", .today),
                    ("Yesterday", .yesterday),
                    ("Last 7 days", .last7Days),
                    ("This month", .thisMonth),
                ]
                for (index, option) in options.enumerated() {
                    if index == 1 { sep() }
                    let selected = store.timeFilter == option.1
                    addItem(selected ? "✓ \(option.0)" : option.0, "", []) {
                        store.timeFilter = option.1
                        store.applyFilters(using: self.searchService)
                        self.emitSnapshot()
                    }
                }
            }
            submenu("Type") { addItem, sep in
                addItem(store.activeCategory == nil ? "✓ All Types" : "All Types", "", []) {
                    store.setCategoryFilter(nil)
                    store.applyFilters(using: self.searchService)
                    self.emitSnapshot()
                }
                sep()
                for category in ClipboardCategory.allCases {
                    let title = category == store.activeCategory ? "✓ \(category.label)" : category.label
                    addItem(title, "", []) {
                        store.setCategoryFilter(category)
                        store.applyFilters(using: self.searchService)
                        self.emitSnapshot()
                    }
                }
            }
            submenu("App") { addItem, sep in
                addItem(store.activeAppBundleId == nil ? "✓ All Apps" : "All Apps", "", []) {
                    store.setAppFilter(nil)
                    store.applyFilters(using: self.searchService)
                    self.emitSnapshot()
                }
                let apps = store.availableApps
                if !apps.isEmpty { sep() }
                for app in apps {
                    let label = "\(app.name) (\(app.count))"
                    let title = app.bundleId == store.activeAppBundleId ? "✓ \(label)" : label
                    addItem(title, "", []) {
                        store.setAppFilter(app.bundleId)
                        store.applyFilters(using: self.searchService)
                        self.emitSnapshot()
                    }
                }
            }
        }
    }

    private func showChoices(args: [String: Any], result: @escaping FlutterResult) {
        let items = args["items"] as? [String] ?? []
        let current = args["current"] as? String
        var picked: String?
        popMenu { add, _, _ in
            for item in items {
                let title = item == current ? "✓ \(item)" : item
                add(title, "", []) { picked = item }
            }
        }
        result(picked)
    }

    private func popMenu(
        at origin: NSPoint? = nil,
        builder: (
            @escaping (String, String, NSEvent.ModifierFlags, @escaping () -> Void) -> Void,
            @escaping () -> Void,
            @escaping (String, (@escaping (String, String, NSEvent.ModifierFlags, @escaping () -> Void) -> Void, @escaping () -> Void) -> Void) -> Void
        ) -> Void
    ) {
        let actions = MenuActions()
        menuKeepAlive = actions
        let menu = NSMenu()
        menu.autoenablesItems = false
        var tag = 1
        func add(_ title: String, _ key: String, _ flags: NSEvent.ModifierFlags, _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuActions.invoke(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.target = actions
            item.tag = tag
            actions.handlers[tag] = handler
            tag += 1
            menu.addItem(item)
        }
        func separator() { menu.addItem(.separator()) }
        func submenu(_ title: String, _ body: (@escaping (String, String, NSEvent.ModifierFlags, @escaping () -> Void) -> Void, @escaping () -> Void) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu()
            child.autoenablesItems = false
            func addChild(_ title: String, _ key: String, _ flags: NSEvent.ModifierFlags, _ handler: @escaping () -> Void) {
                let childItem = NSMenuItem(title: title, action: #selector(MenuActions.invoke(_:)), keyEquivalent: key)
                childItem.keyEquivalentModifierMask = flags
                childItem.target = actions
                childItem.tag = tag
                actions.handlers[tag] = handler
                tag += 1
                child.addItem(childItem)
            }
            func sep() { child.addItem(.separator()) }
            body(addChild, sep)
            item.submenu = child
            menu.addItem(item)
        }
        builder(add, separator, submenu)
        setMenuTracking(true)
        let hostWindow = NSApp.keyWindow ?? flutterWindow
        if let origin, let view = hostWindow?.contentViewController?.view ?? hostWindow?.contentView {
            let point = NSPoint(x: origin.x, y: view.bounds.height - origin.y)
            menu.popUp(positioning: nil, at: point, in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
        setMenuTracking(false)
    }

    private func pickIgnoredApps() -> [String] {
        let panel = NSOpenPanel()
        panel.title = "Choose App to Ignore"
        panel.message = "Clipword will ignore clipboard content copied from the selected app(s)."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return Defaults[.ignoredApps] }
        var apps = Defaults[.ignoredApps]
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else { continue }
            if !apps.contains(bundleId) { apps.append(bundleId) }
        }
        Defaults[.ignoredApps] = apps
        emitSnapshot()
        return apps
    }

    private func applyPrefs(_ args: [String: Any]) {
        if let v = args["launchAtLogin"] as? Bool {
            Defaults[.launchAtLogin] = v
            LaunchAtLoginHelper.setEnabled(v)
        }
        if let v = args["pasteAutomatically"] as? Bool { Defaults[.pasteAutomatically] = v }
        if let v = args["pasteWithoutFormatting"] as? Bool { Defaults[.pasteWithoutFormatting] = v }
        if let v = args["searchMode"] as? String, let mode = SearchMode(rawValue: v) { Defaults[.searchMode] = mode }
        if let v = args["popupPosition"] as? String, let pos = PopupPosition(rawValue: v) { Defaults[.popupPosition] = pos }
        if let v = args["saveText"] as? Bool { Defaults[.saveText] = v }
        if let v = args["saveImages"] as? Bool { Defaults[.saveImages] = v }
        if let v = args["saveFiles"] as? Bool { Defaults[.saveFiles] = v }
        if let v = args["loadLinkPreviews"] as? Bool { Defaults[.loadLinkPreviews] = v }
        if let v = args["historySize"] as? Int { Defaults[.historySize] = v }
        if let v = args["historyRetention"] as? String, let r = HistoryRetention(rawValue: v) { Defaults[.historyRetention] = r }
        if let v = args["sortOrder"] as? String, let o = SortOrder(rawValue: v) { Defaults[.sortOrder] = o }
        if let v = args["ignoredApps"] as? [String] { Defaults[.ignoredApps] = v }
        if let v = args["allowedAppsOnly"] as? Bool { Defaults[.allowedAppsOnly] = v }
        if let v = args["ignoredPasteboardTypes"] as? [String] { Defaults[.ignoredPasteboardTypes] = v }
        if let v = args["ignoredRegexPatterns"] as? [String] { Defaults[.ignoredRegexPatterns] = v }
        if let v = args["clearOnQuit"] as? Bool { Defaults[.clearOnQuit] = v }
        if let v = args["clearSystemClipboard"] as? Bool { Defaults[.clearSystemClipboard] = v }
    }

    // MARK: Snapshot

    func emitSnapshot() {
        pruneSelection()
        let payload: [String: Any] = ["type": "snapshot", "payload": snapshotDict()]
        events?(payload)
        settingsEvents?(payload)
    }

    private func pruneSelection() {
        guard let store = historyStore, let current = selection else { return }
        let kind = current["kind"]
        let id = current["id"]
        let valid: Bool
        switch kind {
        case "history":
            valid = historyItem(store, id) != nil
        case "bookmark":
            valid = bookmarkItem(store, id) != nil
        case "folder":
            valid = id.flatMap(UUID.init(uuidString:)).flatMap { store.folder(id: $0) } != nil
        default:
            valid = false
        }
        if !valid { selection = nil }
    }

    private func persistCollapsedFolders() {
        Defaults[.collapsedFolderIDs] = collapsedFolderIDs.map(\.uuidString)
    }

    private func emitWindowMode() {
        events?(["type": "windowMode", "payload": windowMode])
        channel?.invokeMethod("onWindowMode", arguments: windowMode)
    }

    private func snapshotDict() -> [String: Any] {
        guard let store = historyStore else { return [:] }
        return [
            "windowMode": windowMode,
            "source": paletteSource,
            "settingsSection": settingsSection,
            "searchQuery": store.searchQuery,
            "category": store.activeCategory?.rawValue as Any,
            "appBundleId": store.activeAppBundleId as Any,
            "timeFilter": Self.encodeTimeFilter(store.timeFilter),
            "selection": selection as Any,
            "collapsedFolderIDs": collapsedFolderIDs.map(\.uuidString),
            "items": Array(store.displayedItems.prefix(Self.pageSize)).map(Self.encodeHistory),
            "itemCount": store.displayedItems.count,
            "listRevision": store.listRevision,
            "bookmarks": store.bookmarks.map(Self.encodeBookmark),
            "folders": store.folders.map { ["id": $0.id.uuidString, "name": $0.name, "sortIndex": $0.sortIndex] },
            "apps": store.availableApps.map { ["bundleId": $0.bundleId, "name": $0.name, "count": $0.count] },
            "prefs": prefsDict(),
            "accessibility": PasteService.isAccessibilityTrusted,
            "databaseSize": store.databaseSize,
            "previewCacheSize": LinkPreviewService.cacheSizeDescription,
            "action": store.lastAction.map { ["kind": "\($0.kind)", "itemID": $0.itemID.uuidString, "token": $0.token] } as Any,
        ]
    }

    private func prefsDict() -> [String: Any] {
        [
            "launchAtLogin": Defaults[.launchAtLogin],
            "pasteAutomatically": Defaults[.pasteAutomatically],
            "pasteWithoutFormatting": Defaults[.pasteWithoutFormatting],
            "searchMode": Defaults[.searchMode].rawValue,
            "popupPosition": Defaults[.popupPosition].rawValue,
            "saveText": Defaults[.saveText],
            "saveImages": Defaults[.saveImages],
            "saveFiles": Defaults[.saveFiles],
            "loadLinkPreviews": Defaults[.loadLinkPreviews],
            "historySize": Defaults[.historySize],
            "historyRetention": Defaults[.historyRetention].rawValue,
            "sortOrder": Defaults[.sortOrder].rawValue,
            "ignoredApps": Defaults[.ignoredApps],
            "allowedAppsOnly": Defaults[.allowedAppsOnly],
            "ignoredPasteboardTypes": Defaults[.ignoredPasteboardTypes],
            "ignoredRegexPatterns": Defaults[.ignoredRegexPatterns],
            "clearOnQuit": Defaults[.clearOnQuit],
            "clearSystemClipboard": Defaults[.clearSystemClipboard],
        ]
    }

    private func itemDetail(store: HistoryStore, args: [String: Any]) -> [String: Any]? {
        let kind = args["kind"] as? String ?? ""
        let id = args["id"] as? String
        if kind == "history", let item = historyItem(store, id) {
            var dict = Self.encodeHistory(item)
            dict["plainText"] = item.plainText as Any
            dict["image"] = item.imageData.map { FlutterStandardTypedData(bytes: $0) } as Any
            dict["applicationBundleId"] = item.applicationBundleId as Any
            dict["contentType"] = item.contentTypeRaw
            dict["copyCount"] = item.copyCount
            dict["pasteCount"] = item.pasteCount
            dict["wordCount"] = item.wordCount
            dict["charCount"] = item.charCount
            dict["events"] = item.activityTimeline.map {
                [
                    "id": $0.id.uuidString,
                    "kind": $0.kind.rawValue,
                    "date": $0.date.timeIntervalSince1970,
                    "bundleId": $0.applicationBundleId as Any,
                ]
            }
            dict["appName"] = appName(item.applicationBundleId)
            dict["linkURL"] = ContentClassifier.linkPreviewURL(from: item.plainText)?.absoluteString as Any
            return dict
        }
        if kind == "bookmark", let item = bookmarkItem(store, id) {
            var dict = Self.encodeBookmark(item)
            dict["plainText"] = item.plainText as Any
            dict["image"] = item.imageData.map { FlutterStandardTypedData(bytes: $0) } as Any
            dict["contentType"] = item.contentTypeRaw
            dict["wordCount"] = item.wordCount
            dict["charCount"] = item.charCount
            dict["appName"] = appName(item.applicationBundleId)
            dict["linkURL"] = ContentClassifier.linkPreviewURL(from: item.plainText)?.absoluteString as Any
            dict["folderName"] = item.folder?.name as Any
            return dict
        }
        return nil
    }

    private static func encodeHistory(_ item: HistoryItem) -> [String: Any] {
        [
            "id": item.id.uuidString,
            "title": item.displayTitle,
            "category": item.contentCategoryRaw,
            "lastCopiedAt": item.lastCopiedAt.timeIntervalSince1970,
            "isPinned": item.isPinned,
            "isBookmarked": item.isBookmarked,
            "icon": rowIcon(item.contentType, item.category),
        ]
    }

    private static func encodeBookmark(_ item: BookmarkItem) -> [String: Any] {
        [
            "id": item.id.uuidString,
            "title": item.displayTitle,
            "category": item.contentCategoryRaw,
            "applicationBundleId": item.applicationBundleId as Any,
            "folderId": item.folder?.id.uuidString as Any,
            "icon": rowIcon(item.contentType, item.category),
        ]
    }

    private static func rowIcon(_ type: ContentType, _ category: ClipboardCategory) -> String {
        if type == .image { return "photo" }
        if type == .file { return "doc" }
        return category.systemImage
    }

    private static func encodeTimeFilter(_ filter: HistoryTimeFilter) -> [String: Any] {
        switch filter {
        case .any: return ["kind": "any"]
        case .today: return ["kind": "today"]
        case .yesterday: return ["kind": "yesterday"]
        case .last7Days: return ["kind": "last7Days"]
        case .thisMonth: return ["kind": "thisMonth"]
        case .days(let from, let to):
            return ["kind": "days", "from": from.timeIntervalSince1970, "to": to.timeIntervalSince1970]
        }
    }

    private static func decodeTimeFilter(_ args: [String: Any]) -> HistoryTimeFilter {
        switch args["kind"] as? String {
        case "today": return .today
        case "yesterday": return .yesterday
        case "last7Days": return .last7Days
        case "thisMonth": return .thisMonth
        case "days":
            let from = Date(timeIntervalSince1970: args["from"] as? Double ?? 0)
            let to = Date(timeIntervalSince1970: args["to"] as? Double ?? 0)
            return .spanning(from, to: to)
        default: return .any
        }
    }

    private static func encodePreview(_ record: LinkPreviewRecord) -> [String: Any] {
        [
            "url": record.url.absoluteString,
            "title": record.title as Any,
            "detail": record.detail as Any,
            "siteName": record.siteName as Any,
            "failed": record.failed,
            "image": record.imageData.map { FlutterStandardTypedData(bytes: $0) } as Any,
            "icon": record.iconData.map { FlutterStandardTypedData(bytes: $0) } as Any,
        ]
    }

    private func symbolPNG(_ name: String, size: Double) -> FlutterStandardTypedData? {
        let key = "\(name)-\(size)"
        if let cached = iconCache[key] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        image.isTemplate = true
        let data = pngData(image, size: size)
        if let data { iconCache[key] = data }
        return data
    }

    private func appIconPNG(_ bundleId: String?, size: Double) -> FlutterStandardTypedData? {
        guard let bundleId, bundleId != "unknown",
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        return pngData(image, size: size)
    }

    private func pngData(_ image: NSImage, size: Double) -> FlutterStandardTypedData? {
        let scaled = NSImage(size: NSSize(width: size, height: size))
        scaled.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        scaled.unlockFocus()
        guard let tiff = scaled.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return FlutterStandardTypedData(bytes: png)
    }

    private func appName(_ bundleId: String?) -> String {
        guard let bundleId, bundleId != "unknown" else { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId
    }
}

extension ClipwordHost: FlutterStreamHandler {
    nonisolated func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        Task { @MainActor in
            self.events = events
            self.emitSnapshot()
            self.emitWindowMode()
        }
        return nil
    }

    nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
        Task { @MainActor in
            self.events = nil
        }
        return nil
    }
}

private final class SettingsStreamHandler: NSObject, FlutterStreamHandler {
    weak var host: ClipwordHost?

    init(host: ClipwordHost) {
        self.host = host
    }

    nonisolated func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        Task { @MainActor in
            self.host?.settingsEvents = events
            self.host?.emitSnapshot()
        }
        return nil
    }

    nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
        Task { @MainActor in
            self.host?.settingsEvents = nil
        }
        return nil
    }
}

private final class MenuActions: NSObject {
    var handlers: [Int: () -> Void] = [:]

    @objc func invoke(_ sender: NSMenuItem) {
        handlers[sender.tag]?()
    }
}

private extension HistoryStore {
    func handlePasteStackPop() {
        if let item = popPasteStack() {
            select(item, paste: true)
        }
    }
}
