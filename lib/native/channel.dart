import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'backend.dart';
import 'method_channel_backend.dart';
import 'models.dart';
import 'windows/windows_backend.dart';

/// Facade over the platform host. Callers keep using
/// `ClipwordChannel.instance`; the concrete backend is chosen once by
/// platform (macOS → method channel, Windows → Dart backend).
class ClipwordChannel {
  ClipwordChannel._()
      : _backend = (!kIsWeb && Platform.isWindows)
            ? WindowsBackend()
            : MethodChannelBackend();

  static final instance = ClipwordChannel._();

  final ClipwordBackend _backend;

  /// One-time backend setup. Call once during boot before `start()`.
  Future<void> init() => _backend.init();

  Stream<ClipSnapshot> get snapshots => _backend.snapshots;
  Stream<String> get windowModes => _backend.windowModes;
  Stream<void> get viewsChanged => _backend.viewsChanged;
  Stream<Map<Object?, Object?>> get edits => _backend.edits;
  Stream<Map<Object?, Object?>> get newFolders => _backend.newFolders;
  Stream<Map<Object?, Object?>> get renameFolders => _backend.renameFolders;
  Stream<bool> get menuTracking => _backend.menuTracking;
  Stream<void> get paletteKeys => _backend.paletteKeys;
  Stream<String> get paletteInputs => _backend.paletteInputs;
  Stream<Map<Object?, Object?>> get paletteNavs => _backend.paletteNavs;

  /// Controller for the dedicated settings window (Windows multi-window);
  /// null on macOS and before first open.
  Object? get settingsWindowController => _backend.settingsWindowController;

  Future<ClipSnapshot> snapshot() => _backend.snapshot();

  Future<HistoryPage> loadItems({required int offset, int limit = 80}) =>
      _backend.loadItems(offset: offset, limit: limit);

  Future<void> setSearch(String query) => _backend.setSearch(query);

  Future<void> setCategory(String? category) => _backend.setCategory(category);

  Future<void> setAppFilter(String? bundleId) => _backend.setAppFilter(bundleId);

  Future<void> setTimeFilter(TimeFilter filter) => _backend.setTimeFilter(filter);

  Future<void> setSource(String source) => _backend.setSource(source);

  Future<void> select(String kind, String id) => _backend.select(kind, id);

  Future<void> setCollapsedFolders(Iterable<String> ids) =>
      _backend.setCollapsedFolders(ids);

  Future<void> activate({required bool paste, bool withoutFormatting = false}) =>
      _backend.activate(paste: paste, withoutFormatting: withoutFormatting);

  Future<void> togglePin(String id) => _backend.togglePin(id);

  Future<void> toggleBookmark(String id) => _backend.toggleBookmark(id);

  Future<void> delete({required String kind, required String id}) =>
      _backend.delete(kind: kind, id: id);

  Future<void> addToStack(String id) => _backend.addToStack(id);

  Future<void> editContent(String kind, String id, String content) =>
      _backend.editContent(kind, id, content);

  Future<String?> createFolder({
    required String name,
    String? historyId,
    String? bookmarkId,
  }) =>
      _backend.createFolder(
        name: name,
        historyId: historyId,
        bookmarkId: bookmarkId,
      );

  Future<void> renameFolder(String id, String name) =>
      _backend.renameFolder(id, name);

  Future<void> deleteFolder(String id) => _backend.deleteFolder(id);

  Future<void> showItemMenu({String? kind, String? id, double? x, double? y}) =>
      _backend.showItemMenu(kind: kind, id: id, x: x, y: y);

  Future<void> showFilterMenu() => _backend.showFilterMenu();

  Future<String?> showChoices(List<String> items, {String? current}) =>
      _backend.showChoices(items, current: current);

  Future<void> showSettings({String section = 'general'}) =>
      _backend.showSettings(section: section);

  Future<void> hideWindow() => _backend.hideWindow();

  Future<void> showWindow({String? source}) => _backend.showWindow(source: source);

  Future<void> quit() => _backend.quit();

  Future<void> prefsSet(Map<String, Object?> values) => _backend.prefsSet(values);

  Future<bool> requestAccessibility() => _backend.requestAccessibility();

  Future<List<String>> pickIgnoredApps() => _backend.pickIgnoredApps();

  Future<String> clearPreviewCache() => _backend.clearPreviewCache();

  Future<Map<Object?, Object?>?> itemDetail(String kind, String id) =>
      _backend.itemDetail(kind, id);

  Future<Map<Object?, Object?>?> linkPreview(String url) =>
      _backend.linkPreview(url);

  Future<Uint8List?> symbolImage(String name, {double size = 16}) =>
      _backend.symbolImage(name, size: size);

  Future<Uint8List?> appIcon(String? bundleId, {double size = 16}) =>
      _backend.appIcon(bundleId, size: size);

  Future<void> openUrl(String url) => _backend.openUrl(url);

  Future<void> setSettingsSection(String section) =>
      _backend.setSettingsSection(section);

  Future<void> setOpenShortcut(Map<String, Object?> recording) =>
      _backend.setOpenShortcut(recording);

  Future<void> pauseOpenShortcut(bool paused) =>
      _backend.pauseOpenShortcut(paused);

  Future<void> recordOpenShortcut() => _backend.recordOpenShortcut();

  Future<void> cancelOpenShortcutRecording() =>
      _backend.cancelOpenShortcutRecording();

  void listenNativeEvents() => _backend.listenNativeEvents();
}
