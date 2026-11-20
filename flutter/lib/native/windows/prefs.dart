import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// JSON-backed port of the macOS `Defaults` store (`AppPreferences.swift`).
/// Same key names and defaults; persisted to prefs.json in the app support dir.
class AppDirs {
  AppDirs._();

  static Directory? _support;

  /// `%LOCALAPPDATA%\Clipword` — falls back to the exe directory when the
  /// environment variable is missing.
  static Directory get support {
    _support ??= () {
      final local = Platform.environment['LOCALAPPDATA'];
      final base = (local != null && local.isNotEmpty)
          ? local
          : File(Platform.resolvedExecutable).parent.path;
      final dir = Directory(p.join(base, 'Clipword'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    }();
    return _support!;
  }

  static File get storeFile => File(p.join(support.path, 'Storage.sqlite'));
  static File get prefsFile => File(p.join(support.path, 'prefs.json'));
  static Directory get previewCache =>
      Directory(p.join(support.path, 'LinkPreviews'));
}

/// Simple point pair for `popupLastFrame` persistence.
class PopupFrame {
  const PopupFrame(this.x, this.y);
  final double x;
  final double y;
}

class Prefs {
  Prefs._();

  static final Map<String, Object?> _values = {};
  static bool _loaded = false;
  static Timer? _saveTimer;

  static const popupPositions = ['cursor', 'menuBar', 'center', 'lastPosition'];
  static const pinPositions = ['top', 'bottom'];
  static const sortOrders = ['lastCopied', 'firstCopied', 'copyCount'];
  static const retentions = [
    'day', 'week', 'month', 'threeMonths', 'sixMonths', 'year', 'unlimited'
  ];
  static const searchModes = ['exact', 'fuzzy', 'regex', 'mixed'];
  static const historySizePresets = [0, 100, 200, 500, 1000];

  /// Windows equivalents of the macOS concealed/transient pasteboard types.
  static const defaultIgnoredFormats = [
    'ExcludeClipboardContentFromMonitorProcessing',
    'CanIncludeInClipboardHistory',
    'CanUploadToCloudClipboard',
    'Clipboard Viewer Ignore',
    'KeePass',
    'application/x-1password',
  ];

  /// Apps whose copies are ignored by default (password managers, secrets).
  static const defaultIgnoredApps = [
    '1password.exe',
    'keepass.exe',
    'keepassxc.exe',
    'bitwarden.exe',
  ];

  static final Map<String, Object?> _defaults = {
    'launchAtLogin': false,
    'pasteAutomatically': true,
    'pasteWithoutFormatting': false,
    'searchMode': 'mixed',
    'popupPosition': 'center',
    'popupLastFrame': '',
    'collapsedFolderIDs': <String>[],
    'pinPosition': 'top',
    'imageMaxHeight': 40.0,
    'autoPreview': true,
    'autoPreviewDelay': 1.5,
    'showAppIcons': true,
    'showFooter': true,
    'showSearchField': true,
    'showFilterSidebar': false,
    'saveText': true,
    'saveImages': true,
    'saveFiles': true,
    'loadLinkPreviews': true,
    'historySize': 0,
    'historyRetention': 'unlimited',
    'sortOrder': 'lastCopied',
    'ignoredApps': defaultIgnoredApps,
    'allowedAppsOnly': false,
    'ignoredPasteboardTypes': const [
      'ExcludeClipboardContentFromMonitorProcessing',
      'CanIncludeInClipboardHistory',
      'CanUploadToCloudClipboard',
    ],
    'ignoredRegexPatterns': <String>[],
    'ignoreEvents': false,
    'ignoreNextEvent': false,
    'clearOnQuit': false,
    'clearSystemClipboard': false,
    'clipboardCheckInterval': 0.5,
    'didBackfillCategories': false,
    'didReclassifyHTMLLinks': false,
    'didSetDefaultIgnoredApps': false,
    'openShortcut': 'Ctrl+Alt+Shift+V',
    'openPaletteShortcut': <String, Object?>{},
    'windowBackdrop': 'mica',
  };

  static void load() {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = AppDirs.prefsFile;
      if (file.existsSync()) {
        final raw = jsonDecode(file.readAsStringSync());
        if (raw is Map) {
          raw.forEach((key, value) => _values[key as String] = value);
        }
      }
    } catch (_) {
      // Corrupt prefs file: keep defaults rather than crash at startup.
    }
    if (_values['didSetDefaultIgnoredApps'] != true) {
      final apps = list('ignoredApps');
      for (final app in defaultIgnoredApps) {
        if (!apps.contains(app)) apps.add(app);
      }
      _values['ignoredApps'] = apps;
      _values['didSetDefaultIgnoredApps'] = true;
      _scheduleSave();
    }
  }

  static T get<T>(String key) {
    load();
    final v = _values[key];
    if (v is T) return v;
    final d = _defaults[key];
    if (d is T) return d;
    throw ArgumentError('Pref $key: expected $T, got ${v ?? d}');
  }

  static List<String> list(String key) {
    load();
    final v = _values[key] ?? _defaults[key];
    if (v is List) return v.map((e) => '$e').toList();
    return [];
  }

  static void set(String key, Object? value) {
    load();
    _values[key] = value;
    _scheduleSave();
  }

  static void apply(Map<String, Object?> values) {
    load();
    values.forEach((key, value) => _values[key] = value);
    _scheduleSave();
  }

  static void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), saveNow);
  }

  static void saveNow() {
    if (!_loaded) return;
    try {
      AppDirs.prefsFile.writeAsStringSync(jsonEncode(_values));
    } catch (_) {}
  }

  /// Snapshot dict for the channel — only the keys ClipPrefs reads.
  static Map<String, Object?> toPrefsDict() => {
        'launchAtLogin': get<bool>('launchAtLogin'),
        'pasteAutomatically': get<bool>('pasteAutomatically'),
        'pasteWithoutFormatting': get<bool>('pasteWithoutFormatting'),
        'searchMode': get<String>('searchMode'),
        'popupPosition': get<String>('popupPosition'),
        'saveText': get<bool>('saveText'),
        'saveImages': get<bool>('saveImages'),
        'saveFiles': get<bool>('saveFiles'),
        'loadLinkPreviews': get<bool>('loadLinkPreviews'),
        'historySize': get<int>('historySize'),
        'historyRetention': get<String>('historyRetention'),
        'sortOrder': get<String>('sortOrder'),
        'ignoredApps': list('ignoredApps'),
        'allowedAppsOnly': get<bool>('allowedAppsOnly'),
        'ignoredPasteboardTypes': list('ignoredPasteboardTypes'),
        'ignoredRegexPatterns': list('ignoredRegexPatterns'),
        'clearOnQuit': get<bool>('clearOnQuit'),
        'clearSystemClipboard': get<bool>('clearSystemClipboard'),
        'windowBackdrop': get<String>('windowBackdrop'),
      };

  /// Last palette frame (x,y) for the `lastPosition` popup mode.
  static PopupFrame? popupLastFrame() {
    final raw = get<String>('popupLastFrame');
    if (raw.isEmpty) return null;
    final parts = raw.split(',');
    if (parts.length != 2) return null;
    final x = double.tryParse(parts[0]);
    final y = double.tryParse(parts[1]);
    if (x == null || y == null) return null;
    return PopupFrame(x, y);
  }

  static void setPopupLastFrame(PopupFrame frame) {
    set('popupLastFrame', '${frame.x},${frame.y}');
  }

  /// Recorded global-shortcut map `{key, modifiers[]}`; empty = use default.
  static Map<String, Object?> openShortcutRecording() {
    final v = _values['openPaletteShortcut'];
    if (v is Map && v.isNotEmpty) return v.cast<String, Object?>();
    return const {};
  }

  static void setOpenShortcutRecording(Map<String, Object?> rec) {
    set('openPaletteShortcut', rec);
  }

  /// Retention cutoff (port of `HistoryRetention.cutoffDate`); null = keep all.
  static DateTime? retentionCutoff() {
    final now = DateTime.now();
    switch (get<String>('historyRetention')) {
      case 'day':
        return now.subtract(const Duration(days: 1));
      case 'week':
        return now.subtract(const Duration(days: 7));
      case 'month':
        return DateTime(now.year, now.month - 1, now.day, now.hour, now.minute);
      case 'threeMonths':
        return DateTime(now.year, now.month - 3, now.day, now.hour, now.minute);
      case 'sixMonths':
        return DateTime(now.year, now.month - 6, now.day, now.hour, now.minute);
      case 'year':
        return DateTime(now.year - 1, now.month, now.day, now.hour, now.minute);
      default:
        return null;
    }
  }
}
