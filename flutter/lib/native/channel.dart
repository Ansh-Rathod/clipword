import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';

class ClipwordChannel {
  ClipwordChannel._() {
    _methods.setMethodCallHandler(_onMethod);
  }

  static final instance = ClipwordChannel._();

  static const _methods = MethodChannel('clipword');
  static const _events = EventChannel('clipword/events');

  final _snapshot = StreamController<ClipSnapshot>.broadcast();
  final _windowMode = StreamController<String>.broadcast();
  final _edit = StreamController<Map<Object?, Object?>>.broadcast();
  final _newFolder = StreamController<Map<Object?, Object?>>.broadcast();
  final _renameFolder = StreamController<Map<Object?, Object?>>.broadcast();
  final _menuTracking = StreamController<bool>.broadcast();

  Stream<ClipSnapshot> get snapshots => _snapshot.stream;
  Stream<String> get windowModes => _windowMode.stream;
  Stream<Map<Object?, Object?>> get edits => _edit.stream;
  Stream<Map<Object?, Object?>> get newFolders => _newFolder.stream;
  Stream<Map<Object?, Object?>> get renameFolders => _renameFolder.stream;
  Stream<bool> get menuTracking => _menuTracking.stream;

  Future<dynamic> _onMethod(MethodCall call) async {
    switch (call.method) {
      case 'onSnapshot':
        final map = Map<Object?, Object?>.from(call.arguments as Map);
        _snapshot.add(ClipSnapshot(map));
      case 'onWindowMode':
        _windowMode.add(call.arguments as String);
      case 'edit':
        _edit.add(Map<Object?, Object?>.from(call.arguments as Map));
      case 'newFolder':
        _newFolder.add(Map<Object?, Object?>.from(call.arguments as Map));
      case 'renameFolder':
        _renameFolder.add(Map<Object?, Object?>.from(call.arguments as Map));
      case 'onMenuTracking':
        _menuTracking.add(call.arguments as bool);
    }
  }

  Future<ClipSnapshot> snapshot() async {
    final raw = await _methods.invokeMethod<Map>('snapshot');
    return ClipSnapshot(Map<Object?, Object?>.from(raw ?? const {}));
  }

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

  Future<void> setSearch(String query) =>
      _methods.invokeMethod('setSearch', {'query': query});

  Future<void> setCategory(String? category) =>
      _methods.invokeMethod('setCategory', {'category': category});

  Future<void> setAppFilter(String? bundleId) =>
      _methods.invokeMethod('setAppFilter', {'bundleId': bundleId});

  Future<void> setTimeFilter(TimeFilter filter) =>
      _methods.invokeMethod('setTimeFilter', filter.toArgs());

  Future<void> setSource(String source) =>
      _methods.invokeMethod('setSource', {'source': source});

  Future<void> select(String kind, String id) =>
      _methods.invokeMethod('select', {'kind': kind, 'id': id});

  Future<void> setCollapsedFolders(Iterable<String> ids) =>
      _methods.invokeMethod('setCollapsedFolders', {'ids': ids.toList()});

  Future<void> activate({required bool paste, bool withoutFormatting = false}) =>
      _methods.invokeMethod('activate', {
        'paste': paste,
        'withoutFormatting': withoutFormatting,
      });

  Future<void> togglePin(String id) =>
      _methods.invokeMethod('togglePin', {'id': id});

  Future<void> toggleBookmark(String id) =>
      _methods.invokeMethod('toggleBookmark', {'id': id});

  Future<void> delete({required String kind, required String id}) =>
      _methods.invokeMethod('delete', {'kind': kind, 'id': id});

  Future<void> addToStack(String id) =>
      _methods.invokeMethod('addToStack', {'id': id});

  Future<void> editContent(String kind, String id, String content) =>
      _methods.invokeMethod('editContent', {
        'kind': kind == 'history' ? 'history' : 'bookmark',
        'id': id,
        'content': content,
      });

  Future<void> createFolder({
    required String name,
    String? historyId,
    String? bookmarkId,
  }) =>
      _methods.invokeMethod('createFolder', {
        'name': name,
        if (historyId != null) 'historyId': historyId,
        if (bookmarkId != null) 'bookmarkId': bookmarkId,
      });

  Future<void> renameFolder(String id, String name) =>
      _methods.invokeMethod('renameFolder', {'id': id, 'name': name});

  Future<void> deleteFolder(String id) =>
      _methods.invokeMethod('deleteFolder', {'id': id});

  Future<void> showItemMenu({
    String? kind,
    String? id,
    double? x,
    double? y,
  }) =>
      _methods.invokeMethod('showItemMenu', {
        if (kind != null) 'kind': kind,
        if (id != null) 'id': id,
        if (x != null) 'x': x,
        if (y != null) 'y': y,
      });

  Future<void> showFilterMenu() => _methods.invokeMethod('showFilterMenu');

  Future<String?> showChoices(List<String> items, {String? current}) =>
      _methods.invokeMethod<String>('showChoices', {
        'items': items,
        'current': current,
      });

  Future<void> showSettings({String section = 'general'}) =>
      _methods.invokeMethod('showSettings', {'section': section});

  Future<void> hideWindow() => _methods.invokeMethod('hideWindow');

  Future<void> quit() => _methods.invokeMethod('quit');

  Future<void> prefsSet(Map<String, Object?> values) =>
      _methods.invokeMethod('prefsSet', values);

  Future<bool> requestAccessibility() async =>
      await _methods.invokeMethod<bool>('requestAccessibility') ?? false;

  Future<List<String>> pickIgnoredApps() async {
    final raw = await _methods.invokeMethod<List>('pickIgnoredApps');
    return raw?.cast<String>() ?? const [];
  }

  Future<String> clearPreviewCache() async =>
      await _methods.invokeMethod<String>('clearPreviewCache') ?? 'Empty';

  Future<Map<Object?, Object?>?> itemDetail(String kind, String id) async {
    final raw = await _methods.invokeMethod<Map>('itemDetail', {
      'kind': kind,
      'id': id,
    });
    return raw == null ? null : Map<Object?, Object?>.from(raw);
  }

  Future<Map<Object?, Object?>?> linkPreview(String url) async {
    final raw = await _methods.invokeMethod<Map>('linkPreview', {'url': url});
    return raw == null ? null : Map<Object?, Object?>.from(raw);
  }

  Future<Uint8List?> symbolImage(String name, {double size = 16}) async {
    final raw = await _methods.invokeMethod('symbolImage', {
      'name': name,
      'size': size,
    });
    if (raw is Uint8List) return raw;
    return null;
  }

  Future<Uint8List?> appIcon(String? bundleId, {double size = 16}) async {
    if (bundleId == null) return null;
    final raw = await _methods.invokeMethod('appIcon', {
      'bundleId': bundleId,
      'size': size,
    });
    if (raw is Uint8List) return raw;
    return null;
  }

  Future<void> openUrl(String url) =>
      _methods.invokeMethod('openUrl', {'url': url});

  Future<void> setSettingsSection(String section) =>
      _methods.invokeMethod('setSettingsSection', {'section': section});

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
      }
    });
  }
}
