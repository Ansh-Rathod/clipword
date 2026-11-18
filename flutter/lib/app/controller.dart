import 'dart:async';

import 'package:flutter/widgets.dart';

import '../native/channel.dart';
import '../native/models.dart';

class ClipwordController extends ChangeNotifier {
  ClipwordController(this.channel);

  final ClipwordChannel channel;
  ClipSnapshot snapshot = ClipSnapshot(const {});
  String windowMode = 'hidden';
  bool listFocused = false;
  String? overlay; // edit | folder | none
  String? editKind;
  String? editId;
  String editText = '';
  String folderName = '';
  String? folderHistoryId;
  String? folderBookmarkId;
  String? renameFolderId;
  Map<Object?, Object?>? detail;
  Map<Object?, Object?>? preview;
  int toastToken = 0;
  String? toastKind;
  String? recentlyActedID;
  Selection? _localSelection;
  List<HistoryRow> _historyItems = [];
  int itemCount = 0;
  int listRevision = -1;
  bool _loadingMore = false;
  Timer? _detailTimer;
  Timer? _toastTimer;
  Timer? _menuGuardTimer;
  int _detailGen = 0;
  String? _loadedDetailKey;
  bool menuTracking = false;
  double historyScrollOffset = 0;
  double bookmarksScrollOffset = 0;
  bool holdScrollUpdates = false;

  Selection? get selection => _localSelection ?? snapshot.selection;
  bool get hasMore => snapshot.source == 'history' && _historyItems.length < itemCount;
  bool get dialogOpen => overlay == 'edit' || overlay == 'folder';

  double get listScrollOffset =>
      snapshot.source == 'bookmarks' ? bookmarksScrollOffset : historyScrollOffset;

  void setListScrollOffset(double offset) {
    if (holdScrollUpdates) return;
    if (snapshot.source == 'bookmarks') {
      bookmarksScrollOffset = offset;
    } else {
      historyScrollOffset = offset;
    }
  }

  Future<void> start() async {
    channel.listenNativeEvents();
    channel.snapshots.listen((value) {
      _applySnapshot(value);
      notifyListeners();
    });
    channel.windowModes.listen((mode) {
      windowMode = mode;
      if (mode == 'hidden') {
        overlay = null;
      }
      notifyListeners();
    });
    channel.menuTracking.listen((tracking) {
      _menuGuardTimer?.cancel();
      if (tracking) {
        menuTracking = true;
      } else {
        menuTracking = true;
        _menuGuardTimer = Timer(const Duration(milliseconds: 250), () {
          menuTracking = false;
          notifyListeners();
        });
      }
      notifyListeners();
    });
    channel.edits.listen((args) async {
      editKind = args['kind'] as String?;
      editId = args['id'] as String?;
      final detail = await channel.itemDetail(editKind ?? 'history', editId ?? '');
      editText = detail?['plainText'] as String? ?? '';
      overlay = 'edit';
      notifyListeners();
    });
    channel.newFolders.listen((args) {
      folderHistoryId = args['historyId'] as String?;
      folderBookmarkId = args['bookmarkId'] as String?;
      renameFolderId = null;
      folderName = '';
      overlay = 'folder';
      notifyListeners();
    });
    channel.renameFolders.listen((args) {
      renameFolderId = args['id'] as String?;
      folderName = args['name'] as String? ?? '';
      folderHistoryId = null;
      folderBookmarkId = null;
      overlay = 'folder';
      notifyListeners();
    });
    snapshot = await channel.snapshot();
    _applySnapshot(snapshot);
    windowMode = snapshot.windowMode;
    notifyListeners();
  }

  void _applySnapshot(ClipSnapshot value) {
    if (snapshot.source != value.source) {
      _localSelection = null;
    }
    snapshot = value;
    windowMode = value.windowMode;
    if (windowMode == 'hidden') {
      overlay = null;
    }
    if (_localSelection != null &&
        value.selection?.kind == _localSelection!.kind &&
        value.selection?.id == _localSelection!.id) {
      _localSelection = null;
    }
    final actionToken = value.actionToken;
    if (actionToken != toastToken && value.actionKind != null) {
      toastToken = actionToken;
      _presentToast(value.actionKind!, value.actionItemID);
    }
    itemCount = value.itemCount;
    _adoptHistoryPage(value.items, value.listRevision);
    final actedId = value.actionItemID;
    if (actedId != null) {
      if (value.actionKind == 'bookmarked') {
        _setHistoryFlag(actedId, 'isBookmarked', true);
      } else if (value.actionKind == 'unbookmarked') {
        _setHistoryFlag(actedId, 'isBookmarked', false);
      }
    }
    _scheduleDetail();
  }

  void _presentToast(String kind, String? itemId) {
    toastKind = kind;
    recentlyActedID = itemId;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 1400), () {
      toastKind = null;
      notifyListeners();
      _toastTimer = Timer(const Duration(milliseconds: 350), () {
        if (recentlyActedID == itemId) {
          recentlyActedID = null;
          notifyListeners();
        }
      });
    });
  }

  void _adoptHistoryPage(List<HistoryRow> page, int revision) {
    listRevision = revision;
    if (_historyItems.isEmpty || page.isEmpty) {
      _historyItems = List<HistoryRow>.of(page);
      return;
    }
    final prefixLen = page.length;
    var sameOrder = _historyItems.length >= prefixLen;
    if (sameOrder) {
      for (var i = 0; i < prefixLen; i++) {
        if (_historyItems[i].id != page[i].id) {
          sameOrder = false;
          break;
        }
      }
    }
    if (sameOrder) {
      _historyItems = [
        ...page,
        ..._historyItems.skip(prefixLen),
      ];
      if (_historyItems.length > itemCount) {
        _historyItems = _historyItems.sublist(0, itemCount);
      }
    } else {
      _historyItems = List<HistoryRow>.of(page);
    }
  }

  void _setHistoryFlag(String id, String key, bool value) {
    for (var i = 0; i < _historyItems.length; i++) {
      final item = _historyItems[i];
      if (item.id != id) continue;
      _historyItems[i] = HistoryRow({...item.json, key: value});
      return;
    }
  }

  Future<void> loadMore() async {
    if (_loadingMore || !hasMore) return;
    _loadingMore = true;
    final offset = _historyItems.length;
    final revision = listRevision;
    try {
      final page = await channel.loadItems(offset: offset, limit: 80);
      if (revision != listRevision) return;
      _appendPage(page);
      notifyListeners();
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> loadRemaining() async {
    if (_loadingMore || !hasMore) return;
    _loadingMore = true;
    final revision = listRevision;
    try {
      while (_historyItems.length < itemCount) {
        final page = await channel.loadItems(offset: _historyItems.length, limit: 250);
        if (revision != listRevision) return;
        if (page.items.isEmpty) break;
        _appendPage(page);
        notifyListeners();
      }
    } finally {
      _loadingMore = false;
    }
  }

  void _appendPage(HistoryPage page) {
    final seen = {for (final item in _historyItems) item.id};
    for (final item in page.items) {
      if (seen.add(item.id)) {
        _historyItems.add(item);
      }
    }
    itemCount = page.itemCount;
  }

  Future<void> reloadSelectedItem() async {
    _detailTimer?.cancel();
    _loadedDetailKey = null;
    detail = null;
    preview = null;
    notifyListeners();
    final selection = this.selection;
    if (selection == null || selection.kind == 'folder') return;
    final key = '${selection.kind}:${selection.id}';
    await _loadDetail(++_detailGen, key);
    final loaded = detail;
    if (loaded == null || selection.kind != 'history') return;
    for (var i = 0; i < _historyItems.length; i++) {
      if (_historyItems[i].id != selection.id) continue;
      _historyItems[i] = HistoryRow({..._historyItems[i].json, ...loaded});
      notifyListeners();
      return;
    }
  }

  void _scheduleDetail() {
    final selection = this.selection;
    if (selection == null || selection.kind == 'folder') {
      _detailTimer?.cancel();
      detail = null;
      preview = null;
      _loadedDetailKey = null;
      return;
    }
    final key = '${selection.kind}:${selection.id}';
    if (_loadedDetailKey == key && detail != null) {
      _detailTimer?.cancel();
      return;
    }
    if (_loadedDetailKey != key) {
      detail = null;
      preview = null;
    }
    _detailTimer?.cancel();
    final gen = ++_detailGen;
    _detailTimer = Timer(const Duration(seconds: 1), () {
      _loadDetail(gen, key);
    });
  }

  Future<void> _loadDetail(int gen, String key) async {
    final selection = this.selection;
    if (gen != _detailGen) return;
    if (selection == null || selection.kind == 'folder') return;
    if ('${selection.kind}:${selection.id}' != key) return;
    final loaded = await channel.itemDetail(selection.kind, selection.id);
    if (gen != _detailGen) return;
    detail = loaded;
    _loadedDetailKey = key;
    final url = loaded?['linkURL'] as String?;
    if (url != null && snapshot.prefs.loadLinkPreviews) {
      final loadedPreview = await channel.linkPreview(url);
      if (gen != _detailGen) return;
      preview = loadedPreview;
    } else {
      preview = null;
    }
    notifyListeners();
  }

  List<PaletteEntry> get entries {
    if (snapshot.source == 'bookmarks') {
      return _bookmarkEntries();
    }
    return _historyEntries();
  }

  List<PaletteEntry> _historyEntries() {
    final items = _historyItems;
    final extractPins = !snapshot.timeFilter.isActive;
    final pinned = <HistoryRow>[];
    final buckets = <DateTime, List<HistoryRow>>{};
    for (final item in items) {
      if (extractPins && item.isPinned) {
        pinned.add(item);
        continue;
      }
      final day = DateTime.fromMillisecondsSinceEpoch(
        (item.lastCopiedAt * 1000).round(),
      );
      final start = DateTime(day.year, day.month, day.day);
      buckets.putIfAbsent(start, () => []).add(item);
    }
    final result = <PaletteEntry>[];
    if (extractPins && pinned.isNotEmpty) {
      result.add(PaletteEntry.section('pinned', 'Pinned'));
      for (final item in pinned) {
        result.add(PaletteEntry.history(item));
      }
    }
    final days = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final day in days) {
      result.add(PaletteEntry.section('day-${day.millisecondsSinceEpoch}', _dayTitle(day)));
      for (final item in buckets[day]!) {
        result.add(PaletteEntry.history(item));
      }
    }
    return result;
  }

  List<PaletteEntry> _bookmarkEntries() {
    final items = snapshot.bookmarks.where((item) {
      if (snapshot.category != null && item.category != snapshot.category) {
        return false;
      }
      if (snapshot.appBundleId != null &&
          (item.applicationBundleId ?? 'unknown') != snapshot.appBundleId) {
        return false;
      }
      if (snapshot.searchQuery.isNotEmpty) {
        final q = snapshot.searchQuery.toLowerCase();
        return item.title.toLowerCase().contains(q);
      }
      return true;
    }).toList();
    final result = <PaletteEntry>[];
    if (snapshot.folders.isEmpty) {
      for (final item in items) {
        result.add(PaletteEntry.bookmark(item, false));
      }
      return result;
    }
    for (final folder in snapshot.folders) {
      final folderItems = items.where((item) => item.folderId == folder.id).toList();
      final collapsed = snapshot.collapsedFolderIDs.contains(folder.id);
      result.add(PaletteEntry.folder(folder, folderItems.length, collapsed));
      if (!collapsed) {
        if (folderItems.isEmpty) {
          result.add(PaletteEntry.empty(folder.id));
        } else {
          for (final item in folderItems) {
            result.add(PaletteEntry.bookmark(item, true));
          }
        }
      }
    }
    final unfiled = items.where((item) => item.folderId == null).toList();
    if (unfiled.isNotEmpty) {
      result.add(PaletteEntry.section('unfiled', 'Unfiled'));
      for (final item in unfiled) {
        result.add(PaletteEntry.bookmark(item, false));
      }
    }
    return result;
  }

  List<PaletteEntry> get selectable =>
      entries.where((e) => e.kind == 'history' || e.kind == 'bookmark' || e.kind == 'folder').toList();

  /// Returns the index in [entries] of the newly selected row, or -1.
  int move(int delta) {
    final rows = selectable;
    if (rows.isEmpty) return -1;
    final current = selection;
    var index = rows.indexWhere(
      (row) => row.kind == current?.kind && row.id == current?.id,
    );
    if (index < 0) {
      index = delta > 0 ? 0 : rows.length - 1;
    } else {
      index = (index + delta).clamp(0, rows.length - 1);
    }
    final row = rows[index];
    _localSelection = Selection(row.kind, row.id!);
    channel.select(row.kind, row.id!);
    listFocused = true;
    _scheduleDetail();
    notifyListeners();
    if (delta > 0 && index >= rows.length - 12) {
      loadMore();
    }
    return entries.indexWhere((entry) => entry.kind == row.kind && entry.id == row.id);
  }

  Future<void> activatePrimary({bool secondary = false, bool shift = false}) async {
    final selection = this.selection;
    if (selection == null) return;
    if (selection.kind == 'folder') {
      if (secondary) return;
      final ids = {...snapshot.collapsedFolderIDs};
      if (ids.contains(selection.id)) {
        ids.remove(selection.id);
      } else {
        ids.add(selection.id);
      }
      await channel.setCollapsedFolders(ids);
      return;
    }
    final enterPastes = snapshot.prefs.pasteAutomatically;
    final paste = secondary ? !enterPastes : enterPastes;
    await channel.activate(paste: paste, withoutFormatting: shift);
  }

  Selection? get _itemSelection {
    final current = selection;
    if (current == null || current.kind == 'folder') return null;
    return current;
  }

  Future<void> copySelection() async {
    if (_itemSelection == null) return;
    await channel.activate(paste: false);
  }

  Future<void> editSelection() async {
    final current = _itemSelection;
    if (current == null || dialogOpen) return;
    editKind = current.kind;
    editId = current.id;
    final loaded = await channel.itemDetail(current.kind, current.id);
    editText = loaded?['plainText'] as String? ?? '';
    overlay = 'edit';
    notifyListeners();
  }

  Future<void> deleteSelection() async {
    final current = selection;
    if (current == null) return;
    await channel.delete(kind: current.kind, id: current.id);
  }

  Future<void> toggleBookmarkSelection() async {
    final current = selection;
    if (current?.kind != 'history') return;
    await channel.toggleBookmark(current!.id);
  }

  Future<void> togglePinSelection() async {
    final current = selection;
    if (current?.kind != 'history') return;
    await channel.togglePin(current!.id);
  }

  Future<void> addSelectionToStack() async {
    final current = selection;
    if (current?.kind != 'history') return;
    await channel.addToStack(current!.id);
  }

  void selectEntry(String kind, String id) {
    _localSelection = Selection(kind, id);
    listFocused = true;
    channel.select(kind, id);
    _scheduleDetail();
    notifyListeners();
  }

  PaletteEntry? get selectedEntry {
    final index = selectedIndex;
    if (index < 0) return null;
    return entries[index];
  }

  int get selectedIndex {
    final current = selection;
    if (current == null) return -1;
    return entries.indexWhere((entry) => entry.kind == current.kind && entry.id == current.id);
  }

  void refresh() => notifyListeners();

  String _dayTitle(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    if (day == today) return 'Today';
    if (day == yesterday) return 'Yesterday';
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final weekday = weekdays[day.weekday - 1];
    return '$weekday ${months[day.month - 1]} ${day.day}';
  }
}

class PaletteEntry {
  PaletteEntry._(this.kind, {this.id, this.title, this.history, this.bookmark, this.count = 0, this.collapsed = false, this.indented = false});

  factory PaletteEntry.section(String id, String title) =>
      PaletteEntry._('section', id: id, title: title);
  factory PaletteEntry.history(HistoryRow item) =>
      PaletteEntry._('history', id: item.id, history: item);
  factory PaletteEntry.bookmark(BookmarkRow item, bool indented) =>
      PaletteEntry._('bookmark', id: item.id, bookmark: item, indented: indented);
  factory PaletteEntry.folder(FolderRow folder, int count, bool collapsed) =>
      PaletteEntry._('folder', id: folder.id, title: folder.name, count: count, collapsed: collapsed);
  factory PaletteEntry.empty(String id) => PaletteEntry._('empty', id: id);

  final String kind;
  final String? id;
  final String? title;
  final HistoryRow? history;
  final BookmarkRow? bookmark;
  final int count;
  final bool collapsed;
  final bool indented;
}
