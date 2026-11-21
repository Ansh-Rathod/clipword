import 'dart:async';
import 'dart:typed_data';

import 'models.dart';

/// Platform backend for the `clipword` host contract.
///
/// On macOS this is implemented by [MethodChannelBackend], a client of the
/// Swift host. On Windows, [WindowsBackend] implements the same contract in
/// Dart (plus a small `clipword_win` channel for hooks/OCR/icons).
abstract class ClipwordBackend {
  /// One-time async setup (open store, install tray/hotkeys, start monitor).
  /// No-op for the method-channel implementation.
  Future<void> init() async {}

  Stream<ClipSnapshot> get snapshots;
  Stream<String> get windowModes;
  Stream<void> get viewsChanged;
  Stream<Map<Object?, Object?>> get edits;
  Stream<Map<Object?, Object?>> get newFolders;
  Stream<Map<Object?, Object?>> get renameFolders;
  Stream<bool> get menuTracking;
  Stream<void> get paletteKeys;

  /// Text forwarded from the native host when keystrokes bypass the Flutter
  /// view (palette window is key but the view isn't first responder).
  Stream<String> get paletteInputs;

  /// Navigation keys forwarded from the native host — macOS consumes them as
  /// interpretKeyEvents selectors before the framework sees a key event.
  Stream<Map<Object?, Object?>> get paletteNavs;

  Future<ClipSnapshot> snapshot();

  Future<HistoryPage> loadItems({required int offset, int limit = 80});

  Future<void> setSearch(String query);

  Future<void> setCategory(String? category);

  Future<void> setAppFilter(String? bundleId);

  Future<void> setTimeFilter(TimeFilter filter);

  Future<void> setSource(String source);

  Future<void> select(String kind, String id);

  Future<void> setCollapsedFolders(Iterable<String> ids);

  Future<void> activate({required bool paste, bool withoutFormatting = false});

  Future<void> togglePin(String id);

  Future<void> toggleBookmark(String id);

  Future<void> delete({required String kind, required String id});

  Future<void> addToStack(String id);

  Future<void> editContent(String kind, String id, String content);

  Future<String?> createFolder({required String name, String? historyId, String? bookmarkId});

  Future<void> renameFolder(String id, String name);

  Future<void> deleteFolder(String id);

  Future<void> showItemMenu({String? kind, String? id, double? x, double? y});

  Future<void> showFilterMenu();

  Future<String?> showChoices(List<String> items, {String? current});

  Future<void> showSettings({String section = 'general'});

  Future<void> hideWindow();

  Future<void> showWindow({String? source});

  Future<void> quit();

  Future<void> prefsSet(Map<String, Object?> values);

  Future<bool> requestAccessibility();

  Future<List<String>> pickIgnoredApps();

  Future<String> clearPreviewCache();

  Future<Map<Object?, Object?>?> itemDetail(String kind, String id);

  Future<Map<Object?, Object?>?> linkPreview(String url);

  Future<Uint8List?> symbolImage(String name, {double size = 16});

  Future<Uint8List?> appIcon(String? bundleId, {double size = 16});

  Future<void> openUrl(String url);

  Future<void> setSettingsSection(String section);

  Future<void> setOpenShortcut(Map<String, Object?> recording);

  Future<void> pauseOpenShortcut(bool paused);

  Future<void> recordOpenShortcut();

  Future<void> cancelOpenShortcutRecording();

  void listenNativeEvents();
}
