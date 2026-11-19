import 'dart:ui';

class ClipPrefs {
  ClipPrefs({
    this.launchAtLogin = false,
    this.pasteAutomatically = true,
    this.pasteWithoutFormatting = false,
    this.searchMode = 'mixed',
    this.popupPosition = 'center',
    this.saveText = true,
    this.saveImages = true,
    this.saveFiles = true,
    this.loadLinkPreviews = true,
    this.historySize = 0,
    this.historyRetention = 'unlimited',
    this.sortOrder = 'lastCopied',
    this.ignoredApps = const [],
    this.allowedAppsOnly = false,
    this.ignoredPasteboardTypes = const [],
    this.ignoredRegexPatterns = const [],
    this.clearOnQuit = false,
    this.clearSystemClipboard = false,
  });

  final bool launchAtLogin;
  final bool pasteAutomatically;
  final bool pasteWithoutFormatting;
  final String searchMode;
  final String popupPosition;
  final bool saveText;
  final bool saveImages;
  final bool saveFiles;
  final bool loadLinkPreviews;
  final int historySize;
  final String historyRetention;
  final String sortOrder;
  final List<String> ignoredApps;
  final bool allowedAppsOnly;
  final List<String> ignoredPasteboardTypes;
  final List<String> ignoredRegexPatterns;
  final bool clearOnQuit;
  final bool clearSystemClipboard;

  factory ClipPrefs.fromJson(Map<Object?, Object?> json) {
    return ClipPrefs(
      launchAtLogin: json['launchAtLogin'] as bool? ?? false,
      pasteAutomatically: json['pasteAutomatically'] as bool? ?? true,
      pasteWithoutFormatting: json['pasteWithoutFormatting'] as bool? ?? false,
      searchMode: json['searchMode'] as String? ?? 'mixed',
      popupPosition: json['popupPosition'] as String? ?? 'center',
      saveText: json['saveText'] as bool? ?? true,
      saveImages: json['saveImages'] as bool? ?? true,
      saveFiles: json['saveFiles'] as bool? ?? true,
      loadLinkPreviews: json['loadLinkPreviews'] as bool? ?? true,
      historySize: json['historySize'] as int? ?? 0,
      historyRetention: json['historyRetention'] as String? ?? 'unlimited',
      sortOrder: json['sortOrder'] as String? ?? 'lastCopied',
      ignoredApps: (json['ignoredApps'] as List?)?.cast<String>() ?? const [],
      allowedAppsOnly: json['allowedAppsOnly'] as bool? ?? false,
      ignoredPasteboardTypes:
          (json['ignoredPasteboardTypes'] as List?)?.cast<String>() ?? const [],
      ignoredRegexPatterns:
          (json['ignoredRegexPatterns'] as List?)?.cast<String>() ?? const [],
      clearOnQuit: json['clearOnQuit'] as bool? ?? false,
      clearSystemClipboard: json['clearSystemClipboard'] as bool? ?? false,
    );
  }
}

class HistoryRow {
  HistoryRow(this.json);
  final Map<Object?, Object?> json;
  String get id => json['id'] as String;
  String get title => json['title'] as String? ?? '';
  String get contentType => json['contentType'] as String? ?? 'text';
  String get category => json['category'] as String? ?? 'plainText';
  String? get applicationBundleId => json['applicationBundleId'] as String?;
  double get lastCopiedAt => (json['lastCopiedAt'] as num?)?.toDouble() ?? 0;
  int get copyCount => json['copyCount'] as int? ?? 0;
  int get pasteCount => json['pasteCount'] as int? ?? 0;
  bool get isPinned => json['isPinned'] as bool? ?? false;
  bool get isBookmarked => json['isBookmarked'] as bool? ?? false;
  int get wordCount => json['wordCount'] as int? ?? 0;
  int get charCount => json['charCount'] as int? ?? 0;
  String get icon => json['icon'] as String? ?? 'doc.text';
}

class HistoryPage {
  HistoryPage({
    required this.items,
    required this.itemCount,
    required this.listRevision,
  });

  final List<HistoryRow> items;
  final int itemCount;
  final int listRevision;
}

class BookmarkRow {
  BookmarkRow(this.json);
  final Map<Object?, Object?> json;
  String get id => json['id'] as String;
  String get title => json['title'] as String? ?? '';
  String get contentType => json['contentType'] as String? ?? 'text';
  String get category => json['category'] as String? ?? 'plainText';
  String? get applicationBundleId => json['applicationBundleId'] as String?;
  String? get folderId => json['folderId'] as String?;
  double get bookmarkedAt => (json['bookmarkedAt'] as num?)?.toDouble() ?? 0;
  double get sourceCopiedAt => (json['sourceCopiedAt'] as num?)?.toDouble() ?? 0;
  int get wordCount => json['wordCount'] as int? ?? 0;
  int get charCount => json['charCount'] as int? ?? 0;
  String get icon => json['icon'] as String? ?? 'bookmark';
}

class FolderRow {
  FolderRow(this.json);
  final Map<Object?, Object?> json;
  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? 'Untitled';
}

class AppFilter {
  AppFilter(this.json);
  final Map<Object?, Object?> json;
  String get bundleId => json['bundleId'] as String;
  String get name => json['name'] as String? ?? bundleId;
  int get count => json['count'] as int? ?? 0;
}

class TimeFilter {
  TimeFilter(this.kind, {this.from, this.to});
  final String kind;
  final double? from;
  final double? to;
  bool get isActive => kind != 'any';
  String get chipTitle => isActive ? label : 'When';
  String get label {
    switch (kind) {
      case 'today':
        return 'Today';
      case 'yesterday':
        return 'Yesterday';
      case 'last7Days':
        return 'Last 7 days';
      case 'thisMonth':
        return 'This month';
      case 'days':
        return 'Custom';
      default:
        return 'Any time';
    }
  }

  Map<String, Object?> toArgs() => {
        'kind': kind,
        if (from != null) 'from': from,
        if (to != null) 'to': to,
      };

  factory TimeFilter.fromJson(Map<Object?, Object?>? json) {
    if (json == null) return TimeFilter('any');
    return TimeFilter(
      json['kind'] as String? ?? 'any',
      from: (json['from'] as num?)?.toDouble(),
      to: (json['to'] as num?)?.toDouble(),
    );
  }
}

class Selection {
  Selection(this.kind, this.id);
  final String kind;
  final String id;
}

class ClipSnapshot {
  ClipSnapshot(this.json);

  final Map<Object?, Object?> json;

  String get windowMode => json['windowMode'] as String? ?? 'hidden';
  String get source => json['source'] as String? ?? 'history';
  String get settingsSection => json['settingsSection'] as String? ?? 'general';
  String get searchQuery => json['searchQuery'] as String? ?? '';
  String? get category => json['category'] as String?;
  String? get appBundleId => json['appBundleId'] as String?;
  TimeFilter get timeFilter =>
      TimeFilter.fromJson(json['timeFilter'] as Map<Object?, Object?>?);
  Selection? get selection {
    final raw = json['selection'] as Map<Object?, Object?>?;
    if (raw == null) return null;
    final kind = raw['kind'] as String?;
    final id = raw['id'] as String?;
    if (kind == null || id == null || kind.isEmpty || id.isEmpty) return null;
    return Selection(kind, id);
  }

  Set<String> get collapsedFolderIDs =>
      (json['collapsedFolderIDs'] as List?)?.cast<String>().toSet() ?? {};

  List<HistoryRow> get items =>
      ((json['items'] as List?) ?? const []).whereType<Map<Object?, Object?>>().map(HistoryRow.new).toList();

  int get itemCount => json['itemCount'] as int? ?? items.length;

  int get listRevision => json['listRevision'] as int? ?? 0;

  List<BookmarkRow> get bookmarks =>
      ((json['bookmarks'] as List?) ?? const []).whereType<Map<Object?, Object?>>().map(BookmarkRow.new).toList();

  List<FolderRow> get folders =>
      ((json['folders'] as List?) ?? const []).whereType<Map<Object?, Object?>>().map(FolderRow.new).toList();

  List<AppFilter> get apps =>
      ((json['apps'] as List?) ?? const []).whereType<Map<Object?, Object?>>().map(AppFilter.new).toList();

  ClipPrefs get prefs => ClipPrefs.fromJson(
        (json['prefs'] as Map<Object?, Object?>?) ?? const {},
      );

  bool get accessibility => json['accessibility'] as bool? ?? false;
  String get databaseSize => json['databaseSize'] as String? ?? '—';
  String get previewCacheSize => json['previewCacheSize'] as String? ?? 'Empty';
  String? get actionItemID =>
      (json['action'] as Map<Object?, Object?>?)?['itemID'] as String?;
  int get actionToken =>
      (json['action'] as Map<Object?, Object?>?)?['token'] as int? ?? 0;
  String? get actionKind =>
      (json['action'] as Map<Object?, Object?>?)?['kind'] as String?;

  Color? get accentColor => _color(json['accentColor']);
  Color? get accentFill => _color(json['accentFill']);
  Color? get accentForeground => _color(json['accentForeground']);

  static Color? _color(Object? raw) {
    if (raw is! List || raw.length < 3) return null;
    double component(int i) {
      if (i >= raw.length) return i == 3 ? 1 : 0;
      return (raw[i] as num?)?.toDouble() ?? (i == 3 ? 1 : 0);
    }

    return Color.fromARGB(
      (component(3) * 255).round().clamp(0, 255),
      (component(0) * 255).round().clamp(0, 255),
      (component(1) * 255).round().clamp(0, 255),
      (component(2) * 255).round().clamp(0, 255),
    );
  }

  List<String> get openShortcut {
    final raw = json['openShortcut'];
    if (raw is! List) return const ['⇧', '⌘', 'C'];
    final keys = raw.map((item) => '$item').where((item) => item.isNotEmpty).toList();
    return keys.isEmpty ? const ['⇧', '⌘', 'C'] : keys;
  }
}

const categoryLabels = {
  'plainText': 'Plain Text',
  'link': 'Links',
  'code': 'Code',
  'styledText': 'Styled Text',
  'image': 'Images',
  'file': 'Files',
  'color': 'Colors',
};

const categoryIcons = {
  'plainText': 'doc.text',
  'link': 'link',
  'code': 'chevron.left.forwardslash.chevron.right',
  'styledText': 'doc.richtext',
  'image': 'photo',
  'file': 'doc',
  'color': 'paintpalette',
};

const categoryOrder = [
  'plainText',
  'link',
  'code',
  'styledText',
  'image',
  'file',
  'color',
];
