import 'dart:async';

import 'package:flutter/services.dart';

import 'backend.dart';
import 'models.dart';

/// macOS implementation: talks to the Swift `ClipwordHost` over the
/// `clipword` MethodChannel/EventChannel pair.
class MethodChannelBackend extends ClipwordBackend {
  MethodChannelBackend() {
    _methods.setMethodCallHandler(_onMethod);
  }

  static const _methods = MethodChannel('clipword');
  static const _events = EventChannel('clipword/events');

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

  Future<dynamic> _onMethod(MethodCall call) async {
    switch (call.method) {
      case 'onSnapshot':
        final map = Map<Object?, Object?>.from(call.arguments as Map);
        _snapshot.add(ClipSnapshot(map));
      case 'onWindowMode':
        _windowMode.add(call.arguments as String);
      case 'onViewsChanged':
        _viewsChanged.add(null);
      case 'edit':
        _edit.add(Map<Object?, Object?>.from(call.arguments as Map));
      case 'newFolder':
        _newFolder.add(Map<Object?, Object?>.from(call.arguments as Map));
      case 'renameFolder':
        _renameFolder.add(Map<Object?, Object?>.from(call.arguments as Map));
      case 'onMenuTracking':
        _menuTracking.add(call.arguments as bool);
      case 'onPaletteKey':
        _paletteKey.add(null);
      case 'onPaletteInput':
        if (call.arguments is String) _paletteInput.add(call.arguments as String);
      case 'onPaletteNav':
        _paletteNav.add(Map<Object?, Object?>.from(call.arguments as Map));
    }
  }

  @override
  Future<ClipSnapshot> snapshot() async {
    final raw = await _methods.invokeMethod<Map>('snapshot');
    return ClipSnapshot(Map<Object?, Object?>.from(raw ?? const {}));
  }

  @override
  Future<HistoryPage> loadItems({required int offset, int limit = 80}) async {
    final raw = await _methods.invokeMethod<Map>('loadItems', {
      'offset': offset,
      'limit': limit,
    });
    final map = Map<Object?, Object?>.from(raw ?? const {});
    return HistoryPage(
      items: ((map['items'] as List?) ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map(HistoryRow.new)
          .toList(),
      itemCount: map['itemCount'] as int? ?? 0,
      listRevision: map['listRevision'] as int? ?? 0,
    );
  }

  @override
  Future<void> setSearch(String query) =>
      _methods.invokeMethod('setSearch', {'query': query});

  @override
  Future<void> setCategory(String? category) =>
      _methods.invokeMethod('setCategory', {'category': category});

  @override
  Future<void> setAppFilter(String? bundleId) =>
      _methods.invokeMethod('setAppFilter', {'bundleId': bundleId});

  @override
  Future<void> setTimeFilter(TimeFilter filter) =>
      _methods.invokeMethod('setTimeFilter', filter.toArgs());

  @override
  Future<void> setSource(String source) =>
      _methods.invokeMethod('setSource', {'source': source});

  @override
  Future<void> select(String kind, String id) =>
      _methods.invokeMethod('select', {'kind': kind, 'id': id});

  @override
  Future<void> setCollapsedFolders(Iterable<String> ids) =>
      _methods.invokeMethod('setCollapsedFolders', {'ids': ids.toList()});

  @override
  Future<void> activate({required bool paste, bool withoutFormatting = false}) =>
      _methods.invokeMethod('activate', {
        'paste': paste,
        'withoutFormatting': withoutFormatting,
      });

  @override
  Future<void> togglePin(String id) =>
      _methods.invokeMethod('togglePin', {'id': id});

  @override
  Future<void> toggleBookmark(String id) =>
      _methods.invokeMethod('toggleBookmark', {'id': id});

  @override
  Future<void> delete({required String kind, required String id}) =>
      _methods.invokeMethod('delete', {'kind': kind, 'id': id});

  @override
  Future<void> addToStack(String id) =>
      _methods.invokeMethod('addToStack', {'id': id});

  @override
  Future<void> editContent(String kind, String id, String content) =>
      _methods.invokeMethod('editContent', {
        'kind': kind == 'history' ? 'history' : 'bookmark',
        'id': id,
        'content': content,
      });

  @override
  Future<String?> createFolder({
    required String name,
    String? historyId,
    String? bookmarkId,
  }) =>
      _methods.invokeMethod<String>('createFolder', {
        'name': name,
        'historyId': ?historyId,
        'bookmarkId': ?bookmarkId,
      });

  @override
  Future<void> renameFolder(String id, String name) =>
      _methods.invokeMethod('renameFolder', {'id': id, 'name': name});

  @override
  Future<void> deleteFolder(String id) =>
      _methods.invokeMethod('deleteFolder', {'id': id});

  @override
  Future<void> showItemMenu({
    String? kind,
    String? id,
    double? x,
    double? y,
  }) =>
      _methods.invokeMethod('showItemMenu', {
        'kind': ?kind,
        'id': ?id,
        'x': ?x,
        'y': ?y,
      });

  @override
  Future<void> showFilterMenu() => _methods.invokeMethod('showFilterMenu');

  @override
  Future<String?> showChoices(List<String> items, {String? current}) =>
      _methods.invokeMethod<String>('showChoices', {
        'items': items,
        'current': current,
      });

  @override
  Future<void> showSettings({String section = 'general'}) =>
      _methods.invokeMethod('showSettings', {'section': section});

  @override
  Future<void> hideWindow() => _methods.invokeMethod('hideWindow');

  @override
  Future<void> showWindow({String? source}) =>
      _methods.invokeMethod('showWindow', {'source': source});

  @override
  Future<void> quit() => _methods.invokeMethod('quit');

  @override
  Future<void> prefsSet(Map<String, Object?> values) =>
      _methods.invokeMethod('prefsSet', values);

  @override
  Future<bool> requestAccessibility() async =>
      await _methods.invokeMethod<bool>('requestAccessibility') ?? false;

  @override
  Future<List<String>> pickIgnoredApps() async {
    final raw = await _methods.invokeMethod<List>('pickIgnoredApps');
    return raw?.cast<String>() ?? const [];
  }

  @override
  Future<String> clearPreviewCache() async =>
      await _methods.invokeMethod<String>('clearPreviewCache') ?? 'Empty';

  @override
  Future<Map<Object?, Object?>?> itemDetail(String kind, String id) async {
    final raw = await _methods.invokeMethod<Map>('itemDetail', {
      'kind': kind,
      'id': id,
    });
    return raw == null ? null : Map<Object?, Object?>.from(raw);
  }

  @override
  Future<Map<Object?, Object?>?> linkPreview(String url) async {
    final raw = await _methods.invokeMethod<Map>('linkPreview', {'url': url});
    return raw == null ? null : Map<Object?, Object?>.from(raw);
  }

  @override
  Future<Uint8List?> symbolImage(String name, {double size = 16}) async {
    final raw = await _methods.invokeMethod('symbolImage', {
      'name': name,
      'size': size,
    });
    if (raw is Uint8List) return raw;
    return null;
  }

  @override
  Future<Uint8List?> appIcon(String? bundleId, {double size = 16}) async {
    if (bundleId == null) return null;
    final raw = await _methods.invokeMethod('appIcon', {
      'bundleId': bundleId,
      'size': size,
    });
    if (raw is Uint8List) return raw;
    return null;
  }

  @override
  Future<void> openUrl(String url) =>
      _methods.invokeMethod('openUrl', {'url': url});

  @override
  Future<void> setSettingsSection(String section) =>
      _methods.invokeMethod('setSettingsSection', {'section': section});

  @override
  Future<void> recordOpenShortcut() =>
      _methods.invokeMethod('recordOpenShortcut');

  @override
  void listenNativeEvents() {
    _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final type = event['type'];
      final payload = event['payload'];
      if (type == 'snapshot' && payload is Map) {
        _snapshot.add(ClipSnapshot(Map<Object?, Object?>.from(payload)));
      } else if (type == 'windowMode' && payload is String) {
        _windowMode.add(payload);
      } else if (type == 'menuTracking' && payload is bool) {
        _menuTracking.add(payload);
      } else if (type == 'paletteKey') {
        _paletteKey.add(null);
      }
    });
  }
}
