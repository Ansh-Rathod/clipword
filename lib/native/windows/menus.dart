import 'dart:async';
import 'dart:ffi';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Flat menu description shared by all TrackPopupMenu sites.
class MenuChoice {
  const MenuChoice(this.id, this.title, {this.enabled = true, this.submenu});

  final String id;
  final String title;
  final bool enabled;
  final List<MenuChoice>? submenu;
}

/// Win32 `TrackPopupMenu` wrapper — port of the `NSMenu`-driven context menus
/// (`showItemMenu`, `showFilterMenu`, `showChoices`). `TrackPopupMenu` is
/// modal: it must run on the thread that owns the HWND (the platform thread =
/// the main Dart isolate), where it pumps its own nested message loop. Running
/// it on a background isolate makes `SetForegroundWindow` fail and the menu
/// dismisses instantly.
class WinMenus {
  WinMenus._();

  /// Our runner HWND — the runner class name is shared by every Flutter
  /// desktop app (e.g. RustDesk), so filter matches by owning process. Only
  /// the palette lives there; secondary windows (settings) have their own
  /// HWNDs and pass them explicitly via [popup]'s `hwnd`.
  static int _findWindow() {
    final cls =
        'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: calloc);
    final pid = GetCurrentProcessId();
    final out = calloc<Uint32>();
    try {
      var h = 0;
      while (true) {
        h = FindWindowEx(0, h, cls, nullptr);
        if (h == 0) return 0;
        GetWindowThreadProcessId(h, out);
        if (out.value == pid) return h;
      }
    } finally {
      calloc.free(out);
      calloc.free(cls);
    }
  }

  /// Shows a popup at screen coordinates; returns the chosen id or null.
  /// [hwnd] is the owner window — the settings HWND when a menu is opened
  /// from settings, else the palette HWND is discovered automatically.
  static Future<String?> popup(
    List<MenuChoice> items, {
    Offset? screenPoint,
    int? hwnd,
    required void Function(bool tracking) onTracking,
  }) async {
    hwnd ??= _findWindow();
    if (hwnd == 0) return null;

    onTracking(true);
    try {
      return _runPopup(hwnd, items, screenPoint);
    } finally {
      onTracking(false);
    }
  }

  static String? _runPopup(int hwnd, List<MenuChoice> items, Offset? point) {
    final menu = CreatePopupMenu();
    if (menu == 0) return null;
    try {
      final ids = <int, String>{};
      var nextId = 1;
      void build(int handle, List<MenuChoice> choices) {
        for (final c in choices) {
          final title = c.title.toNativeUtf16(allocator: calloc);
          try {
            if (c.submenu != null && c.submenu!.isNotEmpty) {
              final sub = CreatePopupMenu();
              build(sub, c.submenu!);
              AppendMenu(handle, MF_POPUP | (c.enabled ? MF_ENABLED : MF_DISABLED),
                  sub, title);
            } else {
              final id = nextId++;
              ids[id] = c.id;
              AppendMenu(
                  handle,
                  MF_STRING | (c.enabled ? MF_ENABLED : MF_DISABLED | MF_GRAYED),
                  id,
                  title);
            }
          } finally {
            calloc.free(title);
          }
        }
      }

      build(menu, items);

      int x, y;
      if (point != null) {
        x = point.dx.round();
        y = point.dy.round();
      } else {
        final pt = calloc.allocate<POINT>(sizeOf<POINT>());
        GetCursorPos(pt);
        x = pt.ref.x;
        y = pt.ref.y;
        calloc.free(pt);
      }

      // SetForegroundWindow is required for the menu to dismiss on an
      // outside click. TPM_RETURNCMD → blocking, returns command id.
      SetForegroundWindow(hwnd);
      final cmd = TrackPopupMenu(
        menu,
        TPM_LEFTALIGN | TPM_TOPALIGN | TPM_RETURNCMD | TPM_NONOTIFY,
        x,
        y,
        0,
        hwnd,
        nullptr,
      );
      return ids[cmd];
    } finally {
      DestroyMenu(menu);
    }
  }
}
