import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

import '../backend.dart';
import '../models.dart';
import 'accent.dart';
import 'apps.dart';
import 'classifier.dart';
import 'clipboard.dart';
import 'hotkeys.dart';
import 'icons.dart';
import 'launch_at_startup.dart';
import 'link_preview.dart';
import 'menus.dart';
import 'monitor.dart';
import 'paste.dart';
import 'prefs.dart';
import 'search.dart';
import 'settings_window.dart';
import 'snapshot_codec.dart';
import 'store.dart';
import 'time_filter.dart';
import 'tray.dart';
import 'windowing.dart';

base class _OsVersionInfo extends Struct {
  @Uint32()
  external int dwOSVersionInfoSize;
  @Uint32()
  external int dwMajorVersion;
  @Uint32()
  external int dwMinorVersion;
  @Uint32()
  external int dwBuildNumber;
  @Uint32()
  external int dwPlatformId;
  @Array(128)
  external Array<Uint16> szCSDVersion;
}

/// Windows 11 (build 22000+) supports the DWMSBT_*/Mica materials; Windows
/// 10 only has the classic acrylic accent — the dropdown is disabled there
/// and the native layer maps every requested mode to acrylic as well.
final bool _micaSupported = () {
  try {
    final ntdll = DynamicLibrary.open('ntdll.dll');
    final rtlGetVersion = ntdll.lookupFunction<
        Int32 Function(Pointer<_OsVersionInfo>),
        int Function(Pointer<_OsVersionInfo>)>('RtlGetVersion');
    final v = calloc<_OsVersionInfo>();
    try {
      v.ref.dwOSVersionInfoSize = sizeOf<_OsVersionInfo>();
      if (rtlGetVersion(v) != 0) return true;
      return v.ref.dwBuildNumber >= 22000;
    } finally {
      calloc.free(v);
    }
  } catch (_) {
    return true;
  }
}();

/// Windows implementation of [ClipwordBackend] — the `ClipwordHost` port.
/// Everything macOS does in Swift is reimplemented here in Dart; only the
/// low-level keyboard hook, WinRT OCR, and exe-icon extraction go through the
/// thin `clipword_win` C++ channel.
class WindowsBackend extends ClipwordBackend {
  static const _win = MethodChannel('clipword_win');
  static const _pageSize = 80;

  late final HistoryStore store;
  final _search = SearchService();
  final _monitor = ClipboardMonitor();
  late final WinWindowing _windowing;
  final WinSettingsWindow _settings =
      WinSettingsWindow(channel: WindowsBackend._win);
  late final WinTray _tray;
  late final WinHotkeys _hotkeys;

  final _snapshot = StreamController<ClipSnapshot>.broadcast();
  final _windowMode = StreamController<String>.broadcast();
  final _viewsChanged = StreamController<void>.broadcast();
  final _edit = StreamController<Map<Object?, Object?>>.broadcast();
  final _newFolder = StreamController<Map<Object?, Object?>>.broadcast();
  final _renameFolder = StreamController<Map<Object?, Object?>>.broadcast();
  final _menuTracking = StreamController<bool>.broadcast();
  final _paletteKey = StreamController<void>.broadcast();
  final _paletteInput = StreamController<String>.broadcast();
  final _paletteNav = StreamController<Map<Object?, Object?>>.broadcast();

  @override
  Stream<ClipSnapshot> get snapshots => _snapshot.stream;
  @override
  Stream<String> get windowModes => _windowMode.stream;
  @override
  Stream<void> get viewsChanged => _viewsChanged.stream;
  @override
  Stream<Map<Object?, Object?>> get edits => _edit.stream;
  @override
  Stream<Map<Object?, Object?>> get newFolders => _newFolder.stream;
  @override
  Stream<Map<Object?, Object?>> get renameFolders => _renameFolder.stream;
  @override
  Stream<bool> get menuTracking => _menuTracking.stream;
  @override
  Stream<void> get paletteKeys => _paletteKey.stream;
  @override
  Stream<String> get paletteInputs => _paletteInput.stream;
  @override
  Stream<Map<Object?, Object?>> get paletteNavs => _paletteNav.stream;

  /// Dedicated settings-window controller — non-null once created; the app
  /// mounts its `Window(controller:)` subtree off this.
  @override
  Object? get settingsWindowController => _settings.controller;

  String _paletteSource = 'history';
  String _settingsSection = 'general';
  Map<String, String>? _historySelection;
  Map<String, String>? _bookmarksSelection;
  Set<String> _collapsedFolderIDs = {};

  Map<String, String>? get _selection =>
      _paletteSource == 'bookmarks' ? _bookmarksSelection : _historySelection;
  set _selection(Map<String, String>? v) {
    if (_paletteSource == 'bookmarks') {
      _bookmarksSelection = v;
    } else {
      _historySelection = v;
    }
  }

  final _symbolCache = <String, Uint8List?>{};
  bool _ready = false;
  Timer? _desktopTracker;

  // ---------------- init ----------------

  @override
  Future<void> init() async {
    if (_ready) return;
    _ready = true;

    Prefs.load();
    _collapsedFolderIDs = Prefs.list('collapsedFolderIDs').toSet();

    _win.setMethodCallHandler(_onWinCall);

    _windowing = WinWindowing(
      onHide: emitSnapshot,
      onFocusLost: _onFocusLost,
      onModeChanged: _emitWindowMode,
      channel: _win,
    );
    await _windowing.init();

    // Dedicated settings window — created lazily on first showSettings;
    // onCreated kicks a snapshot so the app mounts its Window subtree.
    _settings
      ..onCreated = emitSnapshot
      ..onHidden = emitSnapshot;

    // Presence on all virtual desktops: the native layer pins each window's
    // shell view via the shell pinning service (registerTrackedWindow below
    // / in settings_window.dart) — the same flag Task View's "Show this
    // window on all desktops" sets, instant and version-stable since
    // Windows 10. The EVENT_SYSTEM_DESKTOPSWITCH hook + this timer remain
    // as fallback for shells where the pin call fails. Equivalent of the
    // macOS host's canJoinAllSpaces/stationary collectionBehavior.
    _win
        .invokeMethod('registerTrackedWindow', {'hwnd': _windowing.hwnd})
        .catchError((_) => null);
    _desktopTracker =
        Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (_windowing.windowMode == 'palette') {
        moveToCurrentDesktop(_win, _windowing.hwnd);
      }
      if (_settings.isVisible) {
        moveToCurrentDesktop(_win, _settings.hwnd);
      }
    });

    _applyBackdrop();

    _tray = WinTray(
      channel: _win,
      onShowPalette: _togglePalette,
      onShowSettings: () => showSettings(),
      onQuit: quit,
    );
    await _tray.init();

    _hotkeys = WinHotkeys(channel: _win);
    await _hotkeys.apply();

    store = HistoryStore(
      db: HistoryStore.open(AppDirs.storeFile),
      appNameFor: WinApps.appName,
      onNewItem: _scheduleOcr,
    );

    _syncPasteStackArmed();

    _monitor.onChanged = _onClipboardChanged;
    _monitor.start();

    _emitWindowMode(_windowing.windowMode);
    emitSnapshot();
  }

  // ---------------- clipboard ----------------

  void _onClipboardChanged() {
    if (WinPaste.isPasting) return;
    final capture = WinClipboard.capture();
    if (capture.hasMarker) {
      Prefs.set('ignoreNextEvent', false);
      return;
    }
    final snapshot = capture.snapshot;
    if (snapshot == null) {
      // Still consume the one-shot flag even when nothing was capturable.
      Prefs.set('ignoreNextEvent', false);
      return;
    }
    final item = store.addFromSnapshot(
      snapshot,
      applicationBundleId: WinApps.frontmostAppId(),
      hasMarker: capture.hasMarker,
    );
    if (item != null) emitSnapshot();
  }

  void _scheduleOcr(HistoryItem item) {
    final png = item.imageData;
    if (png == null) return;
    () async {
      try {
        final text = await _win.invokeMethod<String>(
            'ocr', {'png': png, 'maxSide': 2048});
        if (text != null && text.trim().isNotEmpty) {
          store.fillOcrText(item, text.trim());
          emitSnapshot();
        }
      } catch (_) {}
    }();
  }

  // ---------------- windowing ----------------

  void _emitWindowMode(String mode) {
    _windowMode.add(mode);
    emitSnapshot();
  }

  void _togglePalette() {
    if (_windowing.windowMode == 'palette') {
      _windowing.hide();
      return;
    }
    WinPaste.saveFrontmost();
    _windowing.showPalette(forSource: _paletteSource);
  }

  void hidePalette() => _windowing.hide();

  // ---------------- snapshot ----------------

  Map<String, Object?> _snapshotDict() {
    final s = store;
    return {
      'windowMode': _windowing.windowMode,
      'source': _paletteSource,
      'settingsSection': _settingsSection,
      'searchQuery': s.searchQuery,
      'category': s.activeCategory?.raw,
      'appBundleId': s.activeAppBundleId,
      'timeFilter': s.timeFilter.encode(),
      'selection': _selection,
      'collapsedFolderIDs': _collapsedFolderIDs.toList(),
      'items': s.displayedItems.take(_pageSize).map(_encodeHistory).toList(),
      'itemCount': s.displayedItems.length,
      'listRevision': s.listRevision,
      'bookmarks': s.bookmarks.map(_encodeBookmark).toList(),
      'folders': s.folders
          .map((f) => {'id': f.id, 'name': f.name, 'sortIndex': f.sortIndex})
          .toList(),
      'apps': s.availableApps
          .map((a) => {'bundleId': a.bundleId, 'name': a.name, 'count': a.count})
          .toList(),
      'prefs': Prefs.toPrefsDict(),
      'accessibility': true,
      'databaseSize': s.databaseSize,
      'previewCacheSize': LinkPreviewService.cacheSize(),
      'action': s.lastAction == null
          ? null
          : {
              'kind': s.lastAction!.kind,
              'itemID': s.lastAction!.itemId,
              'token': s.lastAction!.token,
            },
      'micaSupported': _micaSupported,
      'accentColor': WinAccent.accent(),
      'accentFill': WinAccent.accent(),
      'accentForeground': WinAccent.foreground(),
      'openShortcut': _shortcutTokens(),
    };
  }

  List<String> _shortcutTokens() {
    final rec = Prefs.openShortcutRecording();
    final label = WinHotkeys.labelFor(rec.isEmpty ? null : rec);
    return label.split('+');
  }

  void emitSnapshot() {
    if (!_ready) return;
    _pruneSelection();
    _snapshot.add(ClipSnapshot(_snapshotDict()));
  }

  static Map<String, Object?> _encodeHistory(HistoryItem i) => {
        'id': i.id,
        'title': i.displayTitle,
        'category': i.category,
        'contentType': i.contentType.raw,
        'lastCopiedAt': i.lastCopiedAt,
        'isPinned': i.isPinned,
        'isBookmarked': i.isBookmarked,
        'copyCount': i.copyCount,
        'pasteCount': i.pasteCount,
        'wordCount': i.wordCount,
        'charCount': i.charCount,
        'applicationBundleId': i.applicationBundleId,
        'icon': _rowIcon(i.contentType, i.category),
      };

  static Map<String, Object?> _encodeBookmark(BookmarkItem i) => {
        'id': i.id,
        'title': i.displayTitle,
        'category': i.category,
        'contentType': i.contentType.raw,
        'applicationBundleId': i.applicationBundleId,
        'folderId': i.folderId,
        'bookmarkedAt': i.bookmarkedAt,
        'sourceCopiedAt': i.sourceCopiedAt,
        'wordCount': i.wordCount,
        'charCount': i.charCount,
        'icon': _rowIcon(i.contentType, i.category),
      };

  static String _rowIcon(ClipContentType type, String category) {
    if (type == ClipContentType.image) return 'photo';
    if (type == ClipContentType.file) return 'doc';
    return ClipboardCategory.parse(category)?.systemImage ?? 'doc.text';
  }

  // ---------------- selection bookkeeping ----------------

  List<Map<String, String>> _visibleSelectableRows() {
    if (_paletteSource == 'bookmarks') {
      final bookmarks = store.bookmarks;
      if (store.folders.isEmpty) {
        return [for (final b in bookmarks) {'kind': 'bookmark', 'id': b.id}];
      }
      final rows = <Map<String, String>>[];
      final unfiled = <BookmarkItem>[];
      for (final folder in store.folders) {
        rows.add({'kind': 'folder', 'id': folder.id});
        if (_collapsedFolderIDs.contains(folder.id)) continue;
        for (final b in bookmarks.where((b) => b.folderId == folder.id)) {
          rows.add({'kind': 'bookmark', 'id': b.id});
        }
      }
      for (final b in bookmarks) {
        if (b.folderId == null || store.folder(id: b.folderId!) == null) {
          unfiled.add(b);
        }
      }
      for (final b in unfiled) {
        rows.add({'kind': 'bookmark', 'id': b.id});
      }
      return rows;
    }
    return [for (final i in store.displayedItems) {'kind': 'history', 'id': i.id}];
  }

  void _pruneSelection() {
    final current = _selection;
    if (current == null) return;
    final rows = _visibleSelectableRows();
    final stillThere = rows.any(
        (r) => r['kind'] == current['kind'] && r['id'] == current['id']);
    if (stillThere) return;
    _selection = _neighborSelection(rows, null);
  }

  static Map<String, String>? _neighborSelection(
      List<Map<String, String>> rows, int? index) {
    if (rows.isEmpty) return null;
    if (index == null) return rows.first;
    return rows[index.clamp(0, rows.length - 1)];
  }

  int? _selectionIndex() {
    final current = _selection;
    if (current == null) return null;
    final rows = _visibleSelectableRows();
    for (var i = 0; i < rows.length; i++) {
      if (rows[i]['kind'] == current['kind'] &&
          rows[i]['id'] == current['id']) {
        return i;
      }
    }
    return null;
  }

  void _retargetSelection(int? previousIndex, {required bool followItem}) {
    final rows = _visibleSelectableRows();
    final current = _selection;
    if (followItem &&
        current != null &&
        rows.any((r) =>
            r['kind'] == current['kind'] && r['id'] == current['id'])) {
      return;
    }
    _selection = _neighborSelection(rows, previousIndex);
  }

  void _mutateList(void Function() body, {bool followItem = false}) {
    final index = _selectionIndex();
    body();
    _retargetSelection(index, followItem: followItem);
    emitSnapshot();
  }

  HistoryItem? _historyItem(String? id) => store.historyItem(id);
  BookmarkItem? _bookmarkItem(String? id) => store.bookmarkItem(id);

  // ---------------- channel methods ----------------

  @override
  Future<ClipSnapshot> snapshot() async => ClipSnapshot(_snapshotDict());

  @override
  Future<HistoryPage> loadItems({required int offset, int limit = 80}) async {
    final all = store.displayedItems;
    final slice = all.skip(offset < 0 ? 0 : offset).take(limit).toList();
    return HistoryPage(
      items: slice.map((i) => HistoryRow(_encodeHistory(i))).toList(),
      itemCount: all.length,
      listRevision: store.listRevision,
    );
  }

  @override
  Future<void> setSearch(String query) async {
    store.searchQuery = query;
    store.applyFilters(searchService: _search);
    emitSnapshot();
  }

  @override
  Future<void> setCategory(String? category) async {
    store.setCategoryFilter(ClipboardCategory.parse(category));
    store.applyFilters(searchService: _search);
    emitSnapshot();
  }

  @override
  Future<void> setAppFilter(String? bundleId) async {
    store.setAppFilter(bundleId);
    store.applyFilters(searchService: _search);
    emitSnapshot();
  }

  @override
  Future<void> setTimeFilter(TimeFilter filter) async {
    store.setTimeFilter(HistoryTimeFilter.decode(filter.toArgs()));
    store.applyFilters(searchService: _search);
    emitSnapshot();
  }

  @override
  Future<void> setSource(String source) async {
    if (source != 'history' && source != 'bookmarks') return;
    _paletteSource = source;
    emitSnapshot();
  }

  @override
  Future<void> select(String kind, String id) async {
    _selection = {'kind': kind, 'id': id};
    emitSnapshot();
  }

  @override
  Future<void> setCollapsedFolders(Iterable<String> ids) async {
    _collapsedFolderIDs = ids.toSet();
    Prefs.set('collapsedFolderIDs', _collapsedFolderIDs.toList());
    emitSnapshot();
  }

  void _copyToClipboard(ClipSnapshotData snapshot, {required bool strip}) =>
      WinClipboard.write(snapshot, withoutFormatting: strip);

  void _performPaste(HistoryItem _) {
    if (Prefs.get<bool>('pasteAutomatically')) {
      WinPaste.restoreAndPaste();
    }
  }

  @override
  Future<void> activate(
      {required bool paste, bool withoutFormatting = false}) async {
    final sel = _selection;
    if (sel == null) return;
    final kind = sel['kind'];
    final id = sel['id'];
    if (kind == 'history') {
      final item = _historyItem(id);
      if (item == null) return;
      store.select(item,
          paste: paste,
          withoutFormatting: withoutFormatting,
          copyToClipboard: _copyToClipboard,
          performPaste: _performPaste);
      emitSnapshot();
      if (paste) hidePalette();
    } else if (kind == 'bookmark') {
      final item = _bookmarkItem(id);
      if (item == null) return;
      store.selectBookmark(item,
          paste: paste,
          withoutFormatting: withoutFormatting,
          copyToClipboard: _copyToClipboard,
          performPaste: () {
            if (Prefs.get<bool>('pasteAutomatically')) {
              WinPaste.restoreAndPaste();
            }
          });
      emitSnapshot();
      if (paste) hidePalette();
    }
  }

  @override
  Future<void> togglePin(String id) async {
    final item = _historyItem(id);
    if (item == null) return;
    store.togglePin(item);
    emitSnapshot();
  }

  @override
  Future<void> toggleBookmark(String id) async {
    final item = _historyItem(id);
    if (item == null) return;
    store.toggleBookmark(item);
    emitSnapshot();
  }

  @override
  Future<void> delete({required String kind, required String id}) async {
    _mutateList(() {
      if (kind == 'history') {
        final item = _historyItem(id);
        if (item != null) store.delete(item);
      } else if (kind == 'bookmark') {
        final item = _bookmarkItem(id);
        if (item != null) store.deleteBookmark(item);
      } else if (kind == 'folder') {
        final folder = store.folder(id: id);
        if (folder != null) store.deleteFolder(folder);
      }
    });
  }

  @override
  Future<void> addToStack(String id) async {
    final item = _historyItem(id);
    if (item == null) return;
    store.addToPasteStack(item);
    _syncPasteStackArmed();
  }

  void _syncPasteStackArmed() {
    _win.invokeMethod('setPasteStackArmed', {
      'armed': store.pasteStack.isNotEmpty,
    }).catchError((_) {});
  }

  Future<void> _handlePasteStackPop() async {
    final item = store.popPasteStack();
    _syncPasteStackArmed();
    if (item == null) return;
    // The C++ hook swallowed the original Ctrl+V — write the item and
    // inject a fresh Ctrl+V so ordering is deterministic.
    final snapshot = ClipSnapshotData.decode(item.contentData);
    if (snapshot == null) return;
    _copyToClipboard(snapshot,
        strip: Prefs.get<bool>('pasteWithoutFormatting'));
    item.lastCopiedAt = DateTime.now().millisecondsSinceEpoch / 1000.0;
    item.copyCount += 1;
    store.recordEvent('copied', item);
    item.pasteCount += 1;
    item.lastPastedAt = item.lastCopiedAt;
    store.recordEvent('pasted', item);
    emitSnapshot();
    WinPaste.sendCtrlV();
  }

  @override
  Future<void> editContent(String kind, String id, String content) async {
    if (kind == 'history') {
      final item = _historyItem(id);
      if (item != null) store.updateContent(item, content);
    } else {
      final item = _bookmarkItem(id);
      if (item != null) store.updateBookmarkContent(item, content);
    }
    emitSnapshot();
  }

  @override
  Future<String?> createFolder({
    required String name,
    String? historyId,
    String? bookmarkId,
  }) async {
    final folder = store.createFolder(name: name);
    if (historyId != null) {
      final item = _historyItem(historyId);
      if (item != null) store.bookmark(item, folder);
    }
    if (bookmarkId != null) {
      final item = _bookmarkItem(bookmarkId);
      if (item != null) store.moveBookmark(item, folder);
    }
    emitSnapshot();
    return folder.id;
  }

  @override
  Future<void> renameFolder(String id, String name) async {
    final folder = store.folder(id: id);
    if (folder == null) return;
    store.renameFolder(folder, name);
    emitSnapshot();
  }

  @override
  Future<void> deleteFolder(String id) async {
    final folder = store.folder(id: id);
    if (folder == null) return;
    _mutateList(() => store.deleteFolder(folder));
  }

  // ---------------- menus ----------------

  // While a TrackPopupMenu is open the menu itself takes activation, which
  // delivers WA_INACTIVE to our window — the 'deactivated' event is queued
  // and processed after the menu closes, so suppression needs a short tail
  // past the tracking bracket.
  bool _menuOpen = false;
  DateTime _menuSuppressUntil = DateTime.fromMillisecondsSinceEpoch(0);

  void _setMenuTracking(bool v) {
    _menuOpen = v;
    if (!v) {
      _menuSuppressUntil =
          DateTime.now().add(const Duration(milliseconds: 600));
    }
    _menuTracking.add(v);
  }

  void _onFocusLost() {
    if (_menuOpen || DateTime.now().isBefore(_menuSuppressUntil)) return;
    _windowing.hide();
  }

  /// HWND menus/pickers should anchor to — the settings window while it's
  /// foreground (its own HWND), else the palette. `TrackPopupMenu` needs the
  /// calling window's handle for correct modality.
  int _menuOwnerHwnd() =>
      _settings.isForeground ? _settings.hwnd : _windowing.hwnd;

  /// x/y are Flutter logical px inside the calling window's client area —
  /// convert to physical px via that window's DPI, then to screen coords.
  Future<Offset> _toScreenPoint(double? x, double? y) async {
    final pt = calloc.allocate<POINT>(sizeOf<POINT>());
    try {
      if (x == null || y == null) {
        GetCursorPos(pt);
      } else {
        final owner = _menuOwnerHwnd();
        final scale = GetDpiForWindow(owner) / 96.0;
        pt.ref.x = (x * scale).round();
        pt.ref.y = (y * scale).round();
        ClientToScreen(owner, pt);
      }
      return Offset(pt.ref.x.toDouble(), pt.ref.y.toDouble());
    } finally {
      calloc.free(pt);
    }
  }

  @override
  Future<void> showItemMenu(
      {String? kind, String? id, double? x, double? y}) async {
    kind ??= _selection?['kind'] ?? '';
    id ??= _selection?['id'];
    final point = await _toScreenPoint(x, y);
    final folders = store.folders;

    if (kind == 'history') {
      final item = _historyItem(id);
      if (item == null) return;
      final currentFolder = store.folderForHistoryItem(item)?.id;
      final choice = await WinMenus.popup([
        const MenuChoice('copy', 'Copy'),
        const MenuChoice('paste', 'Paste'),
        const MenuChoice('stack', 'Add to Paste Stack'),
        const MenuChoice('sep1', '—', enabled: false),
        const MenuChoice('edit', 'Edit…'),
        MenuChoice('bookmark', item.isBookmarked ? 'Remove Bookmark' : 'Bookmark'),
        MenuChoice('folder', 'Add to Folder', submenu: [
          for (final f in folders)
            MenuChoice('folder:${f.id}',
                f.id == currentFolder ? '✓ ${f.name}' : f.name),
          if (folders.isNotEmpty) const MenuChoice('sep2', '—', enabled: false),
          const MenuChoice('newfolder', 'New Folder…'),
        ]),
        MenuChoice('pin', item.isPinned ? 'Unpin' : 'Pin'),
        const MenuChoice('sep3', '—', enabled: false),
        const MenuChoice('delete', 'Delete'),
      ],
          screenPoint: point,
          hwnd: _menuOwnerHwnd(),
          onTracking: _setMenuTracking);
      if (choice == null) return;
      switch (choice) {
        case 'copy':
          store.select(item,
              paste: false, copyToClipboard: _copyToClipboard);
          emitSnapshot();
        case 'paste':
          store.select(item,
              paste: true,
              copyToClipboard: _copyToClipboard,
              performPaste: _performPaste);
          emitSnapshot();
          hidePalette();
        case 'stack':
          store.addToPasteStack(item);
          _syncPasteStackArmed();
        case 'edit':
          _edit.add({'kind': 'history', 'id': item.id});
        case 'bookmark':
          store.toggleBookmark(item);
          emitSnapshot();
        case 'newfolder':
          _newFolder.add({'historyId': item.id});
        case 'pin':
          store.togglePin(item);
          emitSnapshot();
        case 'delete':
          _mutateList(() => store.delete(item));
        default:
          if (choice.startsWith('folder:')) {
            final f = store.folder(id: choice.substring(7));
            store.bookmark(item, f);
            emitSnapshot();
          }
      }
      return;
    }

    if (kind == 'bookmark') {
      final item = _bookmarkItem(id);
      if (item == null) return;
      final choice = await WinMenus.popup([
        const MenuChoice('copy', 'Copy'),
        const MenuChoice('paste', 'Paste'),
        const MenuChoice('sep1', '—', enabled: false),
        const MenuChoice('edit', 'Edit…'),
        MenuChoice('move', 'Move to Folder', submenu: [
          MenuChoice(
              'unfiled', item.folderId == null ? '✓ Unfiled' : 'Unfiled'),
          if (folders.isNotEmpty)
            const MenuChoice('sep2', '—', enabled: false),
          for (final f in folders)
            MenuChoice('folder:${f.id}',
                f.id == item.folderId ? '✓ ${f.name}' : f.name),
          const MenuChoice('sep3', '—', enabled: false),
          const MenuChoice('newfolder', 'New Folder…'),
        ]),
        const MenuChoice('remove', 'Remove Bookmark'),
      ],
          screenPoint: point,
          hwnd: _menuOwnerHwnd(),
          onTracking: _setMenuTracking);
      if (choice == null) return;
      switch (choice) {
        case 'copy':
          store.selectBookmark(item,
              paste: false, copyToClipboard: _copyToClipboard);
        case 'paste':
          store.selectBookmark(item,
              paste: true,
              copyToClipboard: _copyToClipboard,
              performPaste: () {
                if (Prefs.get<bool>('pasteAutomatically')) {
                  WinPaste.restoreAndPaste();
                }
              });
          hidePalette();
        case 'edit':
          _edit.add({'kind': 'bookmark', 'id': item.id});
        case 'unfiled':
          _mutateList(() => store.moveBookmark(item, null));
        case 'newfolder':
          _newFolder.add({'bookmarkId': item.id});
        case 'remove':
          _mutateList(() => store.deleteBookmark(item));
        default:
          if (choice.startsWith('folder:')) {
            final f = store.folder(id: choice.substring(7));
            _mutateList(() => store.moveBookmark(item, f));
          }
      }
      return;
    }

    if (kind == 'folder') {
      final folder = store.folder(id: id ?? '');
      if (folder == null) return;
      final collapsed = _collapsedFolderIDs.contains(folder.id);
      final choice = await WinMenus.popup([
        MenuChoice('toggle', collapsed ? 'Expand' : 'Collapse'),
        const MenuChoice('rename', 'Rename…'),
        const MenuChoice('sep1', '—', enabled: false),
        const MenuChoice('delete', 'Delete Folder'),
      ],
          screenPoint: point,
          hwnd: _menuOwnerHwnd(),
          onTracking: _setMenuTracking);
      if (choice == null) return;
      switch (choice) {
        case 'toggle':
          if (collapsed) {
            _collapsedFolderIDs.remove(folder.id);
          } else {
            _collapsedFolderIDs.add(folder.id);
          }
          Prefs.set('collapsedFolderIDs', _collapsedFolderIDs.toList());
          emitSnapshot();
        case 'rename':
          _renameFolder.add({'id': folder.id, 'name': folder.name});
        case 'delete':
          _mutateList(() => store.deleteFolder(folder));
      }
    }
  }

  @override
  Future<void> showFilterMenu() async {
    final s = store;
    final hasActive = s.activeCategory != null ||
        s.activeAppBundleId != null ||
        s.timeFilter.isActive;
    const whenOpts = [
      ('any', 'Any time'),
      ('today', 'Today'),
      ('yesterday', 'Yesterday'),
      ('last7Days', 'Last 7 days'),
      ('thisMonth', 'This month'),
    ];
    final choice = await WinMenus.popup([
      if (hasActive) ...[
        const MenuChoice('clear', 'Clear Filters'),
        const MenuChoice('sep0', '—', enabled: false),
      ],
      MenuChoice('when', 'When', submenu: [
        for (final (kind, label) in whenOpts)
          MenuChoice(
            'when:$kind',
            _timeFilterLabel(s.timeFilter) == label ? '✓ $label' : label,
          ),
      ]),
      MenuChoice('type', 'Type', submenu: [
        MenuChoice('type:',
            s.activeCategory == null ? '✓ All Types' : 'All Types'),
        const MenuChoice('sepT', '—', enabled: false),
        for (final c in ClipboardCategory.values)
          MenuChoice('type:${c.raw}',
              c == s.activeCategory ? '✓ ${c.label}' : c.label),
      ]),
      MenuChoice('app', 'App', submenu: [
        MenuChoice('app:',
            s.activeAppBundleId == null ? '✓ All Apps' : 'All Apps'),
        if (s.availableApps.isNotEmpty)
          const MenuChoice('sepA', '—', enabled: false),
        for (final a in s.availableApps)
          MenuChoice(
              'app:${a.bundleId}',
              a.bundleId == s.activeAppBundleId
                  ? '✓ ${a.name} (${a.count})'
                  : '${a.name} (${a.count})'),
      ]),
    ], hwnd: _menuOwnerHwnd(), onTracking: _setMenuTracking);
    if (choice == null) return;
    if (choice == 'clear') {
      s.activeCategory = null;
      s.activeAppBundleId = null;
      s.timeFilter = HistoryTimeFilter.any;
      s.applyFilters(searchService: _search);
    } else if (choice.startsWith('when:')) {
      s.setTimeFilter(switch (choice.substring(5)) {
        'today' => HistoryTimeFilter.today,
        'yesterday' => HistoryTimeFilter.yesterday,
        'last7Days' => HistoryTimeFilter.last7Days,
        'thisMonth' => HistoryTimeFilter.thisMonth,
        _ => HistoryTimeFilter.any,
      });
    } else if (choice.startsWith('type:')) {
      final raw = choice.substring(5);
      s.setCategoryFilter(raw.isEmpty ? null : ClipboardCategory.parse(raw));
    } else if (choice.startsWith('app:')) {
      final id = choice.substring(4);
      s.setAppFilter(id.isEmpty ? null : id);
    }
    emitSnapshot();
  }

  String _timeFilterLabel(HistoryTimeFilter f) => switch (f.kind) {
        TimeFilterKind.today => 'Today',
        TimeFilterKind.yesterday => 'Yesterday',
        TimeFilterKind.last7Days => 'Last 7 days',
        TimeFilterKind.thisMonth => 'This month',
        _ => 'Any time',
      };

  @override
  Future<String?> showChoices(List<String> items, {String? current}) async {
    final choice = await WinMenus.popup([
      for (final item in items)
        MenuChoice(item, item == current ? '✓ $item' : item),
    ], hwnd: _menuOwnerHwnd(), onTracking: _setMenuTracking);
    return choice;
  }

  // ---------------- settings/window ----------------

  @override
  Future<void> showSettings({String section = 'general'}) async {
    _settingsSection = section;
    emitSnapshot(); // pick up the requested section before the window shows
    await _settings.open();
  }

  @override
  Future<void> hideWindow() async {
    // Hides whichever top-level is active — settings when it's foreground,
    // else the palette.
    if (_settings.isForeground) {
      _settings.hide();
    } else {
      hidePalette();
    }
  }

  @override
  Future<void> showWindow({String? source}) async {
    WinPaste.saveFrontmost();
    await _windowing.showPalette(forSource: source ?? _paletteSource);
  }

  @override
  Future<void> quit() async {
    if (Prefs.get<bool>('clearOnQuit')) {
      store.clear(unpinnedOnly: false);
    }
    if (Prefs.get<bool>('clearSystemClipboard')) {
      WinClipboard.empty();
    }
    Prefs.saveNow();
    _desktopTracker?.cancel();
    store.dispose();
    _settings.dispose();
    try {
      await _tray.dispose();
    } catch (_) {}
    exit(0);
  }

  @override
  Future<void> prefsSet(Map<String, Object?> values) async {
    Prefs.apply(values);
    if (values.containsKey('launchAtLogin')) {
      LaunchAtStartup.setEnabled(Prefs.get<bool>('launchAtLogin'));
    }
    if (values.containsKey('historySize')) {
      store.reload();
    }
    if (values.containsKey('sortOrder')) {
      store.reload();
    }
    if (values.containsKey('historyRetention')) {
      store.pruneByRetention();
      store.reload();
    }
    if (values.containsKey('windowBackdrop')) {
      _applyBackdrop();
    }
    emitSnapshot();
  }

  /// Pushes the persisted backdrop mode ('mica' | 'acrylic' | 'none') to
  /// every live window — palette HWND plus the settings HWND when created.
  void _applyBackdrop() {
    _win
        .invokeMethod('setWindowBackdrop', {'mode': Prefs.get<String>('windowBackdrop')})
        .catchError((_) => null);
    _settings.applyBackdrop();
  }

  @override
  Future<bool> requestAccessibility() async => true;

  @override
  Future<List<String>> pickIgnoredApps() async {
    final paths = _pickExeFiles(_menuOwnerHwnd());
    if (paths.isEmpty) return Prefs.list('ignoredApps');
    final apps = Prefs.list('ignoredApps');
    for (final path in paths) {
      final norm = WinApps.normalizePath(path);
      if (!apps.contains(norm)) apps.add(norm);
    }
    Prefs.set('ignoredApps', apps);
    emitSnapshot();
    return apps;
  }

  /// Multi-select `.exe` picker via `GetOpenFileNameW` — returns absolute
  /// paths, or empty when cancelled.
  static List<String> _pickExeFiles(int ownerHwnd) {
    const flags = OFN_FILEMUSTEXIST | OFN_ALLOWMULTISELECT | OFN_EXPLORER;
    final ofn = calloc.allocate<OPENFILENAME>(sizeOf<OPENFILENAME>());
    // Multi-select: first string is the directory, followed by filenames,
    // all NUL-separated and terminated by a double NUL.
    final buf = calloc.allocate<Utf16>((65536) * 2);
    final filter =
        'Executables (*.exe)${'\u0000'}*.exe${'\u0000'}All Files (*.*)\u0000*.*\u0000'
            .toNativeUtf16(allocator: calloc);
    final title = 'Choose app to ignore'.toNativeUtf16(allocator: calloc);
    try {
      ofn.ref
        ..lStructSize = sizeOf<OPENFILENAME>()
        ..hwndOwner = ownerHwnd
        ..lpstrFilter = filter
        ..lpstrFile = buf
        ..nMaxFile = 65536
        ..lpstrTitle = title
        ..Flags = flags;
      if (GetOpenFileName(ofn) == 0) return const [];

      final buf16 = buf.cast<Uint16>();
      final segments = <String>[];
      var start = 0;
      var i = 0;
      while (true) {
        if (buf16[i] == 0) {
          if (i == start) break;
          final units = <int>[];
          for (var j = start; j < i; j++) {
            units.add(buf16[j]);
          }
          segments.add(String.fromCharCodes(units));
          start = i + 1;
        }
        i++;
      }
      if (segments.isEmpty) return const [];
      if (segments.length == 1) return [segments.single];
      final dir = segments.first;
      return segments
          .skip(1)
          .map((f) => '$dir\\$f')
          .toList();
    } finally {
      calloc.free(ofn);
      calloc.free(buf);
      calloc.free(filter);
      calloc.free(title);
    }
  }

  @override
  Future<String> clearPreviewCache() async {
    LinkPreviewService.clearCache();
    return 'Empty';
  }

  // ---------------- detail / previews / icons ----------------

  @override
  Future<Map<Object?, Object?>?> itemDetail(String kind, String id) async {
    if (kind == 'history') {
      final item = _historyItem(id);
      if (item == null) return null;
      final dict = _encodeHistory(item);
      dict['plainText'] = item.plainText;
      dict['image'] = item.imageData;
      dict['applicationBundleId'] = item.applicationBundleId;
      dict['copyCount'] = item.copyCount;
      dict['pasteCount'] = item.pasteCount;
      dict['events'] = store
          .activityTimeline(item)
          .map((e) => {
                'id': e.id,
                'kind': e.kind,
                'date': e.date,
                'bundleId': e.applicationBundleId,
              })
          .toList();
      dict['appName'] = WinApps.appName(item.applicationBundleId ?? 'unknown');
      dict['linkURL'] =
          ContentClassifier.linkPreviewURL(item.plainText)?.toString();
      return dict;
    }
    if (kind == 'bookmark') {
      final item = _bookmarkItem(id);
      if (item == null) return null;
      final dict = _encodeBookmark(item);
      dict['plainText'] = item.plainText;
      dict['image'] = item.imageData;
      dict['appName'] = WinApps.appName(item.applicationBundleId ?? 'unknown');
      dict['linkURL'] =
          ContentClassifier.linkPreviewURL(item.plainText)?.toString();
      dict['folderName'] = item.folderId != null
          ? store.folder(id: item.folderId!)?.name
          : null;
      return dict;
    }
    return null;
  }

  @override
  Future<Map<Object?, Object?>?> linkPreview(String url) async {
    if (!Prefs.get<bool>('loadLinkPreviews')) {
      return {'url': url, 'failed': true};
    }
    final result = await LinkPreviewService.fetch(url);
    if (result == null) {
      return {'url': url, 'failed': true};
    }
    final uri = Uri.tryParse(url);
    Uint8List? decode(Object? v) =>
        v is String ? Uint8List.fromList(base64Decode(v)) : null;
    return {
      'url': url,
      'title': result['title'],
      'detail': result['description'],
      'siteName': uri?.host,
      'failed': false,
      'image': decode(result['image']),
      'icon': decode(result['icon']),
    };
  }

  @override
  Future<Uint8List?> symbolImage(String name, {double size = 16}) async {
    final key = '$name-${size.round()}';
    if (_symbolCache.containsKey(key)) return _symbolCache[key];
    final bytes = await WinIcons.symbolPng(name, size: size);
    _symbolCache[key] = bytes;
    return bytes;
  }

  final _iconCache = <String, Uint8List?>{};

  @override
  Future<Uint8List?> appIcon(String? bundleId, {double size = 16}) async {
    if (bundleId == null || bundleId == 'unknown') return null;
    final key = '$bundleId-${size.round()}';
    if (_iconCache.containsKey(key)) return _iconCache[key];
    try {
      final bytes = await _win.invokeMethod<Uint8List>(
          'appIcon', {'path': bundleId, 'size': size.round()});
      _iconCache[key] = bytes;
      return bytes;
    } catch (_) {
      _iconCache[key] = null;
      return null;
    }
  }

  @override
  Future<void> openUrl(String url) async {
    final uri = url.toNativeUtf16(allocator: calloc);
    final op = 'open'.toNativeUtf16(allocator: calloc);
    try {
      ShellExecute(0, op, uri, nullptr, nullptr, SW_SHOWNORMAL);
    } finally {
      calloc.free(uri);
      calloc.free(op);
    }
  }

  @override
  Future<void> setSettingsSection(String section) async {
    _settingsSection = section;
    emitSnapshot();
  }

  @override
  Future<void> setOpenShortcut(Map<String, Object?> recording) async {
    Prefs.setOpenShortcutRecording(recording);
    Prefs.set('openShortcut', WinHotkeys.labelFor(recording));
    await _hotkeys.apply();
    emitSnapshot();
  }

  @override
  Future<void> pauseOpenShortcut(bool paused) async {
    await _win.invokeMethod('pauseOpenShortcut', {'paused': paused});
  }

  @override
  Future<void> recordOpenShortcut() async {}

  @override
  Future<void> cancelOpenShortcutRecording() async {
    await pauseOpenShortcut(false);
  }

  @override
  void listenNativeEvents() {
    // Streams are in-process on Windows — nothing extra to subscribe to.
  }

  // ---------------- clipword_win inbound ----------------

  Future<dynamic> _onWinCall(MethodCall call) async {
    switch (call.method) {
      case 'paletteKey':
        await _handlePasteStackPop();
        _paletteKey.add(null);
      case 'openHotkey':
        _togglePalette();
      case 'trayEvent':
        if (call.arguments is String) _tray.dispatchEvent(call.arguments);
      case 'trayMenu':
        if (call.arguments is String) _tray.dispatchMenu(call.arguments);
      case 'windowEvent':
        switch (call.arguments) {
          case 'deactivated':
            _windowing.notifyDeactivated();
          case 'closed':
            _windowing.notifyClosed();
        }
    }
  }
}
