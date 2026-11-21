import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'classifier.dart';
import 'ignore_rules.dart';
import 'prefs.dart';
import 'search.dart';
import 'snapshot_codec.dart';
import 'text_analytics.dart';
import 'time_filter.dart';

String newId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
  return '${h(0)}${h(1)}${h(2)}${h(3)}-'
      '${h(4)}${h(5)}-${h(6)}${h(7)}-'
      '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}'
      .toUpperCase();
}

double _now() => DateTime.now().millisecondsSinceEpoch / 1000.0;

/// One history row (port of `HistoryItem`).
class HistoryItem {
  HistoryItem({
    required this.id,
    required this.contentData,
    this.plainText,
    required this.contentType,
    required this.category,
    this.pasteboardTypes,
    this.applicationBundleId,
    required this.firstCopiedAt,
    required this.lastCopiedAt,
    this.copyCount = 1,
    this.pasteCount = 0,
    this.lastPastedAt,
    this.isPinned = false,
    this.isBookmarked = false,
    this.wordCount = 0,
    this.lineCount = 0,
    this.charCount = 0,
    this.readingTimeSeconds = 0,
    this.imageData,
    this.title,
  });

  final String id;
  Uint8List contentData;
  String? plainText;
  ClipContentType contentType;
  String category;
  List<String>? pasteboardTypes;
  String? applicationBundleId;
  double firstCopiedAt;
  double lastCopiedAt;
  int copyCount;
  int pasteCount;
  double? lastPastedAt;
  bool isPinned;
  bool isBookmarked;
  int wordCount;
  int lineCount;
  int charCount;
  int readingTimeSeconds;
  Uint8List? imageData;
  String? title;

  ClipContentType get type => contentType;
  ClipboardCategory? get categoryEnum => ClipboardCategory.parse(category);

  String get displayTitle {
    final t = title;
    if (t != null && t.isNotEmpty) return t;
    final text = plainText;
    if (text != null && text.isNotEmpty) {
      final head = text.substring(0, min(200, text.length)).trim();
      if (head.isEmpty) {
        final trimmed = text.trim();
        if (trimmed.isEmpty) return type.label;
        return trimmed.length > 80 ? '${trimmed.substring(0, 80)}…' : trimmed;
      }
      return head.length > 80 ? '${head.substring(0, 80)}…' : head;
    }
    return type.label;
  }
}

/// One bookmark (independent copy — survives history prune).
class BookmarkItem {
  BookmarkItem({
    required this.id,
    required this.contentData,
    this.plainText,
    required this.contentType,
    required this.category,
    this.pasteboardTypes,
    this.applicationBundleId,
    required this.bookmarkedAt,
    required this.sourceCopiedAt,
    this.wordCount = 0,
    this.lineCount = 0,
    this.charCount = 0,
    this.readingTimeSeconds = 0,
    this.imageData,
    this.title,
    this.folderId,
  });

  factory BookmarkItem.from(HistoryItem item) => BookmarkItem(
        id: newId(),
        contentData: item.contentData,
        plainText: item.plainText,
        contentType: item.contentType,
        category: item.category,
        pasteboardTypes: item.pasteboardTypes,
        applicationBundleId: item.applicationBundleId,
        bookmarkedAt: _now(),
        sourceCopiedAt: item.lastCopiedAt,
        wordCount: item.wordCount,
        lineCount: item.lineCount,
        charCount: item.charCount,
        readingTimeSeconds: item.readingTimeSeconds,
        imageData: item.imageData,
        title: item.title,
      );

  final String id;
  Uint8List contentData;
  String? plainText;
  ClipContentType contentType;
  String category;
  List<String>? pasteboardTypes;
  String? applicationBundleId;
  double bookmarkedAt;
  double sourceCopiedAt;
  int wordCount;
  int lineCount;
  int charCount;
  int readingTimeSeconds;
  Uint8List? imageData;
  String? title;
  String? folderId;

  String get displayTitle {
    final t = title;
    if (t != null && t.isNotEmpty) return t;
    final text = plainText;
    if (text != null && text.isNotEmpty) {
      final head = text.substring(0, min(200, text.length)).trim();
      if (head.isEmpty) {
        final trimmed = text.trim();
        if (trimmed.isEmpty) return contentType.label;
        return trimmed.length > 80 ? '${trimmed.substring(0, 80)}…' : trimmed;
      }
      return head.length > 80 ? '${head.substring(0, 80)}…' : head;
    }
    return contentType.label;
  }
}

class BookmarkFolder {
  BookmarkFolder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.sortIndex,
  });
  final String id;
  String name;
  double createdAt;
  int sortIndex;
}

class ItemActivity {
  const ItemActivity({
    required this.id,
    required this.kind,
    required this.date,
    this.applicationBundleId,
    this.isSynthesized = false,
  });
  final String id;
  final String kind; // 'copied' | 'pasted'
  final double date;
  final String? applicationBundleId;
  final bool isSynthesized;
}

class AppFilterOption {
  const AppFilterOption({required this.bundleId, required this.name, required this.count});
  final String bundleId;
  final String name;
  final int count;
}

class HistoryAction {
  const HistoryAction({required this.kind, required this.itemId, required this.token});
  final String kind;
  final String itemId;
  final int token;
}

/// Sqlite-backed port of `HistoryStore`.
class HistoryStore {
  HistoryStore({
    required this.db,
    required this.appNameFor,
    this.onNewItem,
  }) {
    pruneByRetention();
    reload();
    reloadBookmarks();
    reloadFolders();
    reclassifyHTMLLinksIfNeeded();
    _retentionTimer = Timer.periodic(const Duration(hours: 6), (_) => pruneByRetention());
  }

  final Database db;
  final String Function(String bundleId) appNameFor;

  /// Called after a new image item lands so the backend can OCR-fill its title.
  final void Function(HistoryItem item)? onNewItem;

  List<HistoryItem> items = [];
  List<BookmarkItem> bookmarks = [];
  List<BookmarkFolder> folders = [];
  List<HistoryItem> displayedItems = [];

  String searchQuery = '';
  ClipboardCategory? activeCategory;
  String? activeAppBundleId;
  HistoryTimeFilter timeFilter = HistoryTimeFilter.any;
  final pasteStack = <HistoryItem>[];

  HistoryAction? lastAction;
  int _actionToken = 0;
  int listRevision = 0;
  Timer? _retentionTimer;

  static const _retentionBatch = 1000;
  static const _maxEventsPerItem = 200;
  static const _backfillMaxBytes = 512 * 1024;

  // ---------- schema ----------

  static Database open(File file) {
    final db = sqlite3.open(file.path);
    db.execute('''
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS history (
        id TEXT PRIMARY KEY,
        contentData BLOB NOT NULL,
        plainText TEXT,
        contentType TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'plainText',
        pasteboardTypes BLOB,
        applicationBundleId TEXT,
        firstCopiedAt REAL NOT NULL,
        lastCopiedAt REAL NOT NULL,
        copyCount INTEGER NOT NULL DEFAULT 1,
        pasteCount INTEGER NOT NULL DEFAULT 0,
        lastPastedAt REAL,
        isPinned INTEGER NOT NULL DEFAULT 0,
        isBookmarked INTEGER NOT NULL DEFAULT 0,
        wordCount INTEGER NOT NULL DEFAULT 0,
        lineCount INTEGER NOT NULL DEFAULT 0,
        charCount INTEGER NOT NULL DEFAULT 0,
        readingTimeSeconds INTEGER NOT NULL DEFAULT 0,
        imageData BLOB,
        title TEXT
      );
      CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        occurredAt REAL NOT NULL,
        applicationBundleId TEXT,
        itemId TEXT NOT NULL REFERENCES history(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS events_item ON events(itemId);
      CREATE TABLE IF NOT EXISTS folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        createdAt REAL NOT NULL,
        sortIndex INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS bookmarks (
        id TEXT PRIMARY KEY,
        contentData BLOB NOT NULL,
        plainText TEXT,
        contentType TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'plainText',
        pasteboardTypes BLOB,
        applicationBundleId TEXT,
        bookmarkedAt REAL NOT NULL,
        sourceCopiedAt REAL NOT NULL,
        wordCount INTEGER NOT NULL DEFAULT 0,
        lineCount INTEGER NOT NULL DEFAULT 0,
        charCount INTEGER NOT NULL DEFAULT 0,
        readingTimeSeconds INTEGER NOT NULL DEFAULT 0,
        imageData BLOB,
        title TEXT,
        folderId TEXT REFERENCES folders(id) ON DELETE SET NULL
      );
      CREATE INDEX IF NOT EXISTS bookmarks_folder ON bookmarks(folderId);
    ''');
    return db;
  }

  // ---------- loading ----------

  int? get _itemCap {
    final size = Prefs.get<int>('historySize');
    return size <= 0 ? null : size;
  }

  String get _sortColumn => switch (Prefs.get<String>('sortOrder')) {
        'firstCopied' => 'firstCopiedAt',
        'copyCount' => 'copyCount',
        _ => 'lastCopiedAt',
      };

  void reload() {
    final cap = _itemCap;
    final rows = db.select(
      'SELECT * FROM history ORDER BY $_sortColumn DESC${cap != null ? ' LIMIT $cap' : ''}',
    );
    items = rows.map(_historyFromRow).toList();
    _scheduleCategoryBackfill();
    applyFilters();
  }

  static List<String>? _typesFromBlob(Object? blob) {
    if (blob is! List<int>) return null;
    try {
      return (jsonDecode(utf8.decode(blob)) as List).cast<String>();
    } catch (_) {
      return null;
    }
  }

  static Uint8List _blob(Object? v) =>
      v is Uint8List ? v : (v is List<int> ? Uint8List.fromList(v) : Uint8List(0));

  static Uint8List? _blobOrNull(Object? v) =>
      v is Uint8List ? v : (v is List<int> ? Uint8List.fromList(v) : null);

  HistoryItem _historyFromRow(Row r) => HistoryItem(
        id: r['id'] as String,
        contentData: _blob(r['contentData']),
        plainText: r['plainText'] as String?,
        contentType: ClipContentType.values.firstWhere(
          (t) => t.raw == r['contentType'],
          orElse: () => ClipContentType.text,
        ),
        category: r['category'] as String? ?? 'plainText',
        pasteboardTypes: _typesFromBlob(r['pasteboardTypes']),
        applicationBundleId: r['applicationBundleId'] as String?,
        firstCopiedAt: (r['firstCopiedAt'] as num).toDouble(),
        lastCopiedAt: (r['lastCopiedAt'] as num).toDouble(),
        copyCount: (r['copyCount'] as num).toInt(),
        pasteCount: (r['pasteCount'] as num).toInt(),
        lastPastedAt: (r['lastPastedAt'] as num?)?.toDouble(),
        isPinned: (r['isPinned'] as num) != 0,
        isBookmarked: (r['isBookmarked'] as num) != 0,
        wordCount: (r['wordCount'] as num).toInt(),
        lineCount: (r['lineCount'] as num).toInt(),
        charCount: (r['charCount'] as num).toInt(),
        readingTimeSeconds: (r['readingTimeSeconds'] as num).toInt(),
        imageData: _blobOrNull(r['imageData']),
        title: r['title'] as String?,
      );

  BookmarkItem _bookmarkFromRow(Row r) => BookmarkItem(
        id: r['id'] as String,
        contentData: _blob(r['contentData']),
        plainText: r['plainText'] as String?,
        contentType: ClipContentType.values.firstWhere(
          (t) => t.raw == r['contentType'],
          orElse: () => ClipContentType.text,
        ),
        category: r['category'] as String? ?? 'plainText',
        pasteboardTypes: _typesFromBlob(r['pasteboardTypes']),
        applicationBundleId: r['applicationBundleId'] as String?,
        bookmarkedAt: (r['bookmarkedAt'] as num).toDouble(),
        sourceCopiedAt: (r['sourceCopiedAt'] as num).toDouble(),
        wordCount: (r['wordCount'] as num).toInt(),
        lineCount: (r['lineCount'] as num).toInt(),
        charCount: (r['charCount'] as num).toInt(),
        readingTimeSeconds: (r['readingTimeSeconds'] as num).toInt(),
        imageData: _blobOrNull(r['imageData']),
        title: r['title'] as String?,
        folderId: r['folderId'] as String?,
      );

  static Uint8List? _typesBlob(List<String>? types) =>
      types == null ? null : Uint8List.fromList(utf8.encode(jsonEncode(types)));

  void _insertItem(HistoryItem i) {
    db.execute(
      '''INSERT INTO history (id, contentData, plainText, contentType, category,
           pasteboardTypes, applicationBundleId, firstCopiedAt, lastCopiedAt,
           copyCount, pasteCount, lastPastedAt, isPinned, isBookmarked,
           wordCount, lineCount, charCount, readingTimeSeconds, imageData, title)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        i.id, i.contentData, i.plainText, i.contentType.raw, i.category,
        _typesBlob(i.pasteboardTypes), i.applicationBundleId, i.firstCopiedAt,
        i.lastCopiedAt, i.copyCount, i.pasteCount, i.lastPastedAt,
        i.isPinned ? 1 : 0, i.isBookmarked ? 1 : 0,
        i.wordCount, i.lineCount, i.charCount, i.readingTimeSeconds,
        i.imageData, i.title,
      ],
    );
  }

  void _updateItem(HistoryItem i) {
    db.execute(
      '''UPDATE history SET contentData=?, plainText=?, contentType=?, category=?,
           pasteboardTypes=?, applicationBundleId=?, firstCopiedAt=?, lastCopiedAt=?,
           copyCount=?, pasteCount=?, lastPastedAt=?, isPinned=?, isBookmarked=?,
           wordCount=?, lineCount=?, charCount=?, readingTimeSeconds=?, imageData=?,
           title=? WHERE id=?''',
      [
        i.contentData, i.plainText, i.contentType.raw, i.category,
        _typesBlob(i.pasteboardTypes), i.applicationBundleId, i.firstCopiedAt,
        i.lastCopiedAt, i.copyCount, i.pasteCount, i.lastPastedAt,
        i.isPinned ? 1 : 0, i.isBookmarked ? 1 : 0,
        i.wordCount, i.lineCount, i.charCount, i.readingTimeSeconds,
        i.imageData, i.title, i.id,
      ],
    );
  }

  // ---------- capture ----------

  /// Port of `addFromPasteboard`. Returns the new/updated item or null when
  /// the clip was ignored.
  HistoryItem? addFromSnapshot(
    ClipSnapshotData snapshot, {
    required String? applicationBundleId,
    bool hasMarker = false,
  }) {
    if (IgnoreRules.shouldIgnore(
      formats: snapshot.pasteboardTypes ?? const [],
      sourceApp: applicationBundleId,
      plainText: snapshot.plainText,
      hasMarker: hasMarker,
    )) {
      return null;
    }
    if (!IgnoreRules.shouldSave(snapshot)) return null;

    final data = snapshot.encode();
    final existing = _findDuplicate(data, snapshot);
    if (existing != null) {
      existing.lastCopiedAt = _now();
      existing.copyCount += 1;
      recordEvent('copied', existing, applicationBundleId: applicationBundleId);
      _updateItem(existing);
      refreshWithoutFetch();
      return existing;
    }

    final category = ContentClassifier.classify(
      snapshot,
      formats: snapshot.pasteboardTypes ?? const [],
      hasColor: snapshot.hasColorOnPasteboard ?? false,
    );
    final metrics = snapshot.plainText != null
        ? TextAnalytics.metrics(snapshot.plainText!)
        : null;
    final item = HistoryItem(
      id: newId(),
      contentData: data,
      plainText: snapshot.plainText,
      contentType: snapshot.contentType,
      category: category.raw,
      pasteboardTypes: snapshot.pasteboardTypes,
      applicationBundleId: applicationBundleId,
      firstCopiedAt: _now(),
      lastCopiedAt: _now(),
      wordCount: metrics?.wordCount ?? 0,
      lineCount: metrics?.lineCount ?? 0,
      charCount: metrics?.charCount ?? 0,
      readingTimeSeconds: metrics?.readingTimeSeconds ?? 0,
      imageData: snapshot.imageData,
      title: snapshot.plainText != null ? _boundedTitle(snapshot.plainText!) : null,
    );
    _insertItem(item);
    recordEvent('copied', item, applicationBundleId: applicationBundleId);
    final removed = prune();
    items.removeWhere((i) => removed.contains(i.id));
    items.add(item);
    refreshWithoutFetch(removing: removed.toSet());
    _scheduleCategoryBackfill();

    if (snapshot.contentType == ClipContentType.image && snapshot.imageData != null) {
      onNewItem?.call(item);
    }
    return item;
  }

  /// Fill an item's text from OCR (called once the recognizer returns).
  void fillOcrText(HistoryItem item, String text) {
    item.title = text;
    item.plainText = text;
    final m = TextAnalytics.metrics(text);
    item.wordCount = m.wordCount;
    item.lineCount = m.lineCount;
    item.charCount = m.charCount;
    item.readingTimeSeconds = m.readingTimeSeconds;
    _updateItem(item);
    reload();
  }

  String _boundedTitle(String text) {
    final head = text.substring(0, min(200, text.length));
    final nl = head.indexOf(RegExp(r'[\r\n]'));
    return nl >= 0 ? head.substring(0, nl) : head;
  }

  HistoryItem? _findDuplicate(Uint8List data, ClipSnapshotData snapshot) {
    for (final i in items) {
      if (_bytesEqual(i.contentData, data)) return i;
    }
    for (final i in items) {
      if (i.contentType == snapshot.contentType &&
          i.plainText == snapshot.plainText &&
          _listEquals(i.pasteboardTypes, snapshot.pasteboardTypes) &&
          _bytesEqual(i.imageData, snapshot.imageData)) {
        return i;
      }
    }
    return null;
  }

  static bool _bytesEqual(List<int>? a, List<int>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _listEquals(List<String>? a, List<String>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---------- filtering / sorting ----------

  void applyFilters({SearchService? searchService}) {
    var result = _sortedDisplayItems();

    final cat = activeCategory;
    if (cat != null) {
      result = result.where((i) => i.category == cat.raw).toList();
    }
    final appId = activeAppBundleId;
    if (appId != null) {
      result = result.where((i) => i.applicationBundleId == appId).toList();
    }
    if (timeFilter.isActive) {
      result = result
          .where((i) => timeFilter.contains(
              DateTime.fromMillisecondsSinceEpoch((i.lastCopiedAt * 1000).round())))
          .toList();
    }
    if (searchQuery.isNotEmpty) {
      if (searchService != null) {
        result = searchService.search(searchQuery, result);
      } else {
        final q = searchQuery.toLowerCase();
        result = result
            .where((i) =>
                (i.plainText?.toLowerCase().contains(q) ?? false) ||
                (i.title?.toLowerCase().contains(q) ?? false))
            .toList();
      }
    }
    displayedItems = result;
    listRevision += 1;
  }

  List<HistoryItem> _sortedDisplayItems() {
    final pinned = items.where((i) => i.isPinned).toList();
    final unpinned = items.where((i) => !i.isPinned).toList();
    return Prefs.get<String>('pinPosition') == 'bottom'
        ? [...unpinned, ...pinned]
        : [...pinned, ...unpinned];
  }

  void refreshWithoutFetch({Set<String> removing = const {}}) {
    items = items.where((i) => !removing.contains(i.id)).toList();
    final col = _sortColumn;
    items.sort((a, b) {
      final av = col == 'firstCopiedAt'
          ? a.firstCopiedAt
          : col == 'copyCount'
              ? a.copyCount
              : a.lastCopiedAt;
      final bv = col == 'firstCopiedAt'
          ? b.firstCopiedAt
          : col == 'copyCount'
              ? b.copyCount
              : b.lastCopiedAt;
      return bv.compareTo(av);
    });
    applyFilters();
  }

  void setCategoryFilter(ClipboardCategory? category) {
    activeCategory = category;
    applyFilters();
  }

  void setAppFilter(String? bundleId) {
    activeAppBundleId = bundleId;
    applyFilters();
  }

  void setTimeFilter(HistoryTimeFilter filter) {
    timeFilter = filter;
    applyFilters();
  }

  int count(ClipboardCategory category) =>
      items.where((i) => i.category == category.raw).length;

  List<AppFilterOption> get availableApps {
    final counts = <String, int>{};
    for (final i in items) {
      final key = i.applicationBundleId ?? 'unknown';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final list = counts.entries
        .map((e) => AppFilterOption(
            bundleId: e.key, name: appNameFor(e.key), count: e.value))
        .toList();
    list.sort((a, b) => b.count.compareTo(a.count));
    return list;
  }

  // ---------- mutations ----------

  /// Port of `select` — writes the clip back to the system clipboard via the
  /// provided writer, bumps counters, optionally pastes.
  void select(
    HistoryItem item, {
    required bool paste,
    bool withoutFormatting = false,
    required void Function(ClipSnapshotData snapshot, {required bool strip}) copyToClipboard,
    void Function(HistoryItem item)? performPaste,
  }) {
    final snapshot = ClipSnapshotData.decode(item.contentData);
    if (snapshot == null) return;
    final strip = withoutFormatting || Prefs.get<bool>('pasteWithoutFormatting');
    Prefs.set('ignoreNextEvent', true);
    copyToClipboard(snapshot, strip: strip);
    item.lastCopiedAt = _now();
    item.copyCount += 1;
    recordEvent('copied', item);
    if (paste) {
      item.pasteCount += 1;
      item.lastPastedAt = _now();
      recordEvent('pasted', item);
      _updateItem(item);
      _publishAction('pasted', item.id);
      Timer(const Duration(milliseconds: 50), () => performPaste?.call(item));
    } else {
      _updateItem(item);
      _publishAction('copied', item.id);
    }
    refreshWithoutFetch();
  }

  void selectBookmark(
    BookmarkItem item, {
    required bool paste,
    bool withoutFormatting = false,
    required void Function(ClipSnapshotData snapshot, {required bool strip}) copyToClipboard,
    void Function()? performPaste,
  }) {
    final snapshot = ClipSnapshotData.decode(item.contentData);
    if (snapshot == null) return;
    final strip = withoutFormatting || Prefs.get<bool>('pasteWithoutFormatting');
    Prefs.set('ignoreNextEvent', true);
    copyToClipboard(snapshot, strip: strip);
    if (paste) {
      Timer(const Duration(milliseconds: 50), () => performPaste?.call());
    }
  }

  void recordEvent(String kind, HistoryItem item, {String? applicationBundleId}) {
    db.execute(
      'INSERT INTO events (id, kind, occurredAt, applicationBundleId, itemId) VALUES (?,?,?,?,?)',
      [newId(), kind, _now(), applicationBundleId, item.id],
    );
    // Cap per-item log at 200 entries (newest kept).
    db.execute(
      '''DELETE FROM events WHERE itemId = ? AND id NOT IN
           (SELECT id FROM events WHERE itemId = ? ORDER BY occurredAt DESC LIMIT ?)''',
      [item.id, item.id, _maxEventsPerItem],
    );
  }

  List<ItemActivity> activityTimeline(HistoryItem item) {
    final rows = db.select(
      'SELECT * FROM events WHERE itemId = ? ORDER BY occurredAt DESC',
      [item.id],
    );
    if (rows.isNotEmpty) {
      return rows
          .map((r) => ItemActivity(
                id: r['id'] as String,
                kind: r['kind'] as String,
                date: (r['occurredAt'] as num).toDouble(),
                applicationBundleId: r['applicationBundleId'] as String?,
              ))
          .toList();
    }
    // Synthesized timeline for items that predate per-event tracking.
    final result = <ItemActivity>[
      ItemActivity(
        id: item.id,
        kind: 'copied',
        date: item.firstCopiedAt,
        applicationBundleId: item.applicationBundleId,
        isSynthesized: true,
      ),
    ];
    if (item.copyCount > 1 && item.lastCopiedAt != item.firstCopiedAt) {
      result.add(ItemActivity(
        id: newId(),
        kind: 'copied',
        date: item.lastCopiedAt,
        applicationBundleId: item.applicationBundleId,
        isSynthesized: true,
      ));
    }
    if (item.lastPastedAt != null && item.pasteCount > 0) {
      result.add(ItemActivity(
        id: newId(),
        kind: 'pasted',
        date: item.lastPastedAt!,
        isSynthesized: true,
      ));
    }
    result.sort((a, b) => b.date.compareTo(a.date));
    return result;
  }

  void updateContent(HistoryItem item, String content) {
    final snapshot = ClipSnapshotData.decode(item.contentData);
    if (snapshot != null) {
      snapshot.plainText = content;
      item.contentData = snapshot.encode();
    }
    item.plainText = content;
    item.title = _boundedTitle(content);
    item.category = ContentClassifier.classifyStored(
      existingCategory: null,
      contentType: item.contentType,
      plainText: content,
      formats: item.pasteboardTypes ?? const [],
    ).raw;
    final m = TextAnalytics.metrics(content);
    item.wordCount = m.wordCount;
    item.lineCount = m.lineCount;
    item.charCount = m.charCount;
    item.readingTimeSeconds = m.readingTimeSeconds;
    _updateItem(item);
    refreshWithoutFetch();
  }

  void togglePin(HistoryItem item) {
    item.isPinned = !item.isPinned;
    _updateItem(item);
    _publishAction(item.isPinned ? 'pinned' : 'unpinned', item.id);
    refreshWithoutFetch();
  }

  void toggleBookmark(HistoryItem item) {
    final existing = findBookmark(matching: item.contentData);
    if (existing != null) {
      db.execute('DELETE FROM bookmarks WHERE id = ?', [existing.id]);
      item.isBookmarked = false;
    } else {
      _insertBookmark(BookmarkItem.from(item));
      item.isBookmarked = true;
    }
    _updateItem(item);
    reloadBookmarks();
    reloadFolders();
    _publishAction(item.isBookmarked ? 'bookmarked' : 'unbookmarked', item.id);
    refreshWithoutFetch();
  }

  void bookmark(HistoryItem item, BookmarkFolder? folder) {
    final existing = findBookmark(matching: item.contentData);
    if (existing != null) {
      db.execute('UPDATE bookmarks SET folderId = ? WHERE id = ?', [folder?.id, existing.id]);
      item.isBookmarked = true;
    } else {
      final b = BookmarkItem.from(item)..folderId = folder?.id;
      _insertBookmark(b);
      item.isBookmarked = true;
    }
    _updateItem(item);
    reloadBookmarks();
    reloadFolders();
    _publishAction('bookmarked', item.id);
    refreshWithoutFetch();
  }

  BookmarkFolder? folderForHistoryItem(HistoryItem item) =>
      findBookmark(matching: item.contentData)?.folderId != null
          ? folder(id: findBookmark(matching: item.contentData)!.folderId!)
          : null;

  BookmarkFolder? folder({required String id}) {
    for (final f in folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  bool isContentBookmarked(Uint8List contentData) =>
      bookmarks.any((b) => _bytesEqual(b.contentData, contentData));

  void _insertBookmark(BookmarkItem b) {
    db.execute(
      '''INSERT INTO bookmarks (id, contentData, plainText, contentType, category,
           pasteboardTypes, applicationBundleId, bookmarkedAt, sourceCopiedAt,
           wordCount, lineCount, charCount, readingTimeSeconds, imageData, title, folderId)
         VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        b.id, b.contentData, b.plainText, b.contentType.raw, b.category,
        _typesBlob(b.pasteboardTypes), b.applicationBundleId, b.bookmarkedAt,
        b.sourceCopiedAt, b.wordCount, b.lineCount, b.charCount,
        b.readingTimeSeconds, b.imageData, b.title, b.folderId,
      ],
    );
  }

  void reloadBookmarks() {
    final rows = db.select('SELECT * FROM bookmarks ORDER BY bookmarkedAt DESC');
    bookmarks = rows.map(_bookmarkFromRow).toList();
    _migrateLegacyBookmarksIfNeeded();
    listRevision += 1;
  }

  void reloadFolders() {
    final rows =
        db.select('SELECT * FROM folders ORDER BY sortIndex ASC, createdAt ASC');
    folders = rows
        .map((r) => BookmarkFolder(
              id: r['id'] as String,
              name: r['name'] as String,
              createdAt: (r['createdAt'] as num).toDouble(),
              sortIndex: (r['sortIndex'] as num).toInt(),
            ))
        .toList();
    listRevision += 1;
  }

  BookmarkFolder createFolder({required String name}) {
    final trimmed = name.trim();
    final nextIndex =
        folders.isEmpty ? 0 : folders.map((f) => f.sortIndex).reduce(max) + 1;
    final folder = BookmarkFolder(
      id: newId(),
      name: trimmed.isEmpty ? 'Untitled' : trimmed,
      createdAt: _now(),
      sortIndex: nextIndex,
    );
    db.execute(
      'INSERT INTO folders (id, name, createdAt, sortIndex) VALUES (?,?,?,?)',
      [folder.id, folder.name, folder.createdAt, folder.sortIndex],
    );
    reloadFolders();
    return folder;
  }

  void renameFolder(BookmarkFolder folder, String name) {
    final trimmed = name.trim();
    folder.name = trimmed.isEmpty ? 'Untitled' : trimmed;
    db.execute('UPDATE folders SET name = ? WHERE id = ?', [folder.name, folder.id]);
    reloadFolders();
    reloadBookmarks();
  }

  void deleteFolder(BookmarkFolder folder) {
    db.execute('DELETE FROM folders WHERE id = ?', [folder.id]);
    reloadFolders();
    reloadBookmarks();
  }

  void moveBookmark(BookmarkItem item, BookmarkFolder? folder) {
    item.folderId = folder?.id;
    db.execute('UPDATE bookmarks SET folderId = ? WHERE id = ?', [item.folderId, item.id]);
    reloadBookmarks();
    reloadFolders();
  }

  bool _didMigrateBookmarks = false;

  void _migrateLegacyBookmarksIfNeeded() {
    if (_didMigrateBookmarks) return;
    _didMigrateBookmarks = true;
    var added = false;
    for (final item in items.where((i) => i.isBookmarked)) {
      if (findBookmark(matching: item.contentData) == null) {
        _insertBookmark(BookmarkItem.from(item));
        added = true;
      }
    }
    if (added) {
      final rows = db.select('SELECT * FROM bookmarks ORDER BY bookmarkedAt DESC');
      bookmarks = rows.map(_bookmarkFromRow).toList();
    }
  }

  BookmarkItem? findBookmark({required Uint8List matching}) {
    for (final b in bookmarks) {
      if (_bytesEqual(b.contentData, matching)) return b;
    }
    final rows = db.select('SELECT contentData, id FROM bookmarks');
    for (final r in rows) {
      if (_bytesEqual(_blob(r['contentData']), matching)) {
        final full = db.select('SELECT * FROM bookmarks WHERE id = ?', [r['id']]);
        return full.isEmpty ? null : _bookmarkFromRow(full.first);
      }
    }
    return null;
  }

  void updateBookmarkContent(BookmarkItem item, String content) {
    final snapshot = ClipSnapshotData.decode(item.contentData);
    if (snapshot != null) {
      snapshot.plainText = content;
      item.contentData = snapshot.encode();
    }
    item.plainText = content;
    item.title = _boundedTitle(content);
    final m = TextAnalytics.metrics(content);
    item.wordCount = m.wordCount;
    item.lineCount = m.lineCount;
    item.charCount = m.charCount;
    item.readingTimeSeconds = m.readingTimeSeconds;
    _updateBookmark(item);
    reloadBookmarks();
  }

  void _updateBookmark(BookmarkItem b) {
    db.execute(
      '''UPDATE bookmarks SET contentData=?, plainText=?, contentType=?, category=?,
           pasteboardTypes=?, applicationBundleId=?, bookmarkedAt=?, sourceCopiedAt=?,
           wordCount=?, lineCount=?, charCount=?, readingTimeSeconds=?, imageData=?,
           title=?, folderId=? WHERE id=?''',
      [
        b.contentData, b.plainText, b.contentType.raw, b.category,
        _typesBlob(b.pasteboardTypes), b.applicationBundleId, b.bookmarkedAt,
        b.sourceCopiedAt, b.wordCount, b.lineCount, b.charCount,
        b.readingTimeSeconds, b.imageData, b.title, b.folderId, b.id,
      ],
    );
  }

  void deleteBookmark(BookmarkItem item) {
    final match = items.where((i) => _bytesEqual(i.contentData, item.contentData));
    if (match.isNotEmpty) {
      match.first.isBookmarked = false;
      _updateItem(match.first);
    }
    db.execute('DELETE FROM bookmarks WHERE id = ?', [item.id]);
    reloadBookmarks();
    reloadFolders();
    refreshWithoutFetch();
  }

  void delete(HistoryItem item) {
    db.execute('DELETE FROM history WHERE id = ?', [item.id]);
    refreshWithoutFetch(removing: {item.id});
  }

  void clear({required bool unpinnedOnly}) {
    final removed = items.where((i) => unpinnedOnly ? !i.isPinned : true).toList();
    final stmt = db.prepare('DELETE FROM history WHERE id = ?');
    for (final i in removed) {
      stmt.execute([i.id]);
    }
    stmt.close();
    refreshWithoutFetch(removing: removed.map((i) => i.id).toSet());
  }

  void addToPasteStack(HistoryItem item) {
    if (!pasteStack.any((i) => i.id == item.id)) {
      pasteStack.add(item);
    }
  }

  HistoryItem? popPasteStack() =>
      pasteStack.isEmpty ? null : pasteStack.removeAt(0);

  // ---------- prune / retention ----------

  List<String> prune() {
    final limit = _itemCap;
    if (limit == null) return [];
    final removable = items.where((i) => !i.isPinned).toList()
      ..sort((a, b) => b.lastCopiedAt.compareTo(a.lastCopiedAt));
    if (removable.length <= limit) return [];
    final removed = removable.skip(limit).toList();
    final stmt = db.prepare('DELETE FROM history WHERE id = ?');
    for (final i in removed) {
      stmt.execute([i.id]);
    }
    stmt.close();
    return removed.map((i) => i.id).toList();
  }

  void pruneByRetention() {
    final cutoff = Prefs.retentionCutoff();
    if (cutoff == null) return;
    final cutoffSec = cutoff.millisecondsSinceEpoch / 1000.0;
    while (true) {
      final stale = db.select(
        'SELECT id FROM history WHERE lastCopiedAt < ? AND isPinned = 0 LIMIT ?',
        [cutoffSec, _retentionBatch],
      );
      if (stale.isEmpty) break;
      final stmt = db.prepare('DELETE FROM history WHERE id = ?');
      for (final r in stale) {
        stmt.execute([r['id']]);
      }
      stmt.close();
      if (stale.length < _retentionBatch) break;
    }
  }

  // ---------- one-shot migrations ----------

  void reclassifyHTMLLinksIfNeeded() {
    if (Prefs.get<bool>('didReclassifyHTMLLinks')) return;
    var changed = false;
    for (final item in items) {
      if (item.category == 'styledText' || item.category == 'plainText') {
        if (ContentClassifier.isLinkText(item.plainText)) {
          item.category = 'link';
          _updateItem(item);
          changed = true;
        }
      }
    }
    for (final b in bookmarks) {
      if (b.category == 'styledText' || b.category == 'plainText') {
        if (ContentClassifier.isLinkText(b.plainText)) {
          b.category = 'link';
          _updateBookmark(b);
          changed = true;
        }
      }
    }
    if (changed) applyFilters();
    Prefs.set('didReclassifyHTMLLinks', true);
  }

  void _scheduleCategoryBackfill() {
    if (Prefs.get<bool>('didBackfillCategories')) return;
    scheduleMicrotask(_backfillCategoriesIfNeeded);
  }

  void _backfillCategoriesIfNeeded() {
    if (Prefs.get<bool>('didBackfillCategories')) return;
    var changed = false;
    for (final item in items) {
      if (item.contentData.length > _backfillMaxBytes) continue;
      final snapshot = ClipSnapshotData.decode(item.contentData);
      if (snapshot == null) continue;
      final classified = ContentClassifier.classify(
        snapshot,
        formats: item.pasteboardTypes ?? const [],
      );
      if (item.category != classified.raw) {
        item.category = classified.raw;
        _updateItem(item);
        changed = true;
      }
    }
    Prefs.set('didBackfillCategories', true);
    if (changed) refreshWithoutFetch();
  }

  // ---------- misc ----------

  HistoryItem? historyItem(String? id) {
    if (id == null) return null;
    for (final i in items) {
      if (i.id == id) return i;
    }
    for (final i in displayedItems) {
      if (i.id == id) return i;
    }
    return null;
  }

  BookmarkItem? bookmarkItem(String? id) {
    if (id == null) return null;
    for (final b in bookmarks) {
      if (b.id == id) return b;
    }
    return null;
  }

  void _publishAction(String kind, String itemId) {
    _actionToken += 1;
    lastAction = HistoryAction(kind: kind, itemId: itemId, token: _actionToken);
  }

  String get databaseSize {
    final file = AppDirs.storeFile;
    var bytes = 0;
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('${file.path}$suffix');
      if (f.existsSync()) bytes += f.lengthSync();
    }
    if (bytes <= 0) return '—';
    return _formatBytes(bytes);
  }

  static String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[unit]}';
  }

  void dispose() {
    _retentionTimer?.cancel();
    db.close();
  }
}
