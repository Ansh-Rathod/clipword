// TODO(mattkae): remove the ignores when the windowing API is stable.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:ffi' hide Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:win32/win32.dart';

import 'prefs.dart';
import 'windowing.dart';

/// The dedicated settings window — an engine-created `FLUTTER_HOST_WINDOW`
/// HWND driven by the official multi-window API ([WindowController] +
/// [Window]). Created lazily on first open and hidden (never destroyed) when
/// closed, so the settings widget tree keeps scroll/section state between
/// opens and the app only pays the window's cost once it's used.
///
/// Unlike the palette HWND this is a normal unowned overlapped window:
/// native caption buttons, a taskbar button and an Alt+Tab entry — matching
/// the "settings behaves like a real app window" requirement. Everything
/// that needs its HWND goes through [WindowControllerWin32.windowHandle]
/// (backdrop, positioning, menu ownership).
class WinSettingsWindow {
  WinSettingsWindow({required MethodChannel channel}) : _win = channel;

  static const settingsSize = Size(780, 600);

  final MethodChannel _win;

  WindowController? _controller;

  /// Fired once after the controller is created — the app mounts the
  /// `Window(controller:)` subtree in response.
  void Function()? onCreated;

  /// Fired whenever the window is hidden (close button or programmatic).
  void Function()? onHidden;

  /// The controller the `Window` widget renders through. Non-null once the
  /// window has been created — the app treats this as its mount flag.
  WindowController? get controller => _controller;

  int get hwnd {
    final c = _controller;
    if (c == null) return 0;
    return (c as WindowControllerWin32).windowHandle.address;
  }

  bool get isVisible => hwnd != 0 && IsWindowVisible(hwnd) != 0;

  bool get isForeground => hwnd != 0 && GetForegroundWindow() == hwnd;

  /// Show the window, creating it on first use. First open styles and
  /// centers it while hidden, lets one frame render into the new view, then
  /// reveals it — avoids a blank/restyle flash.
  Future<void> open() async {
    final created = _controller == null;
    if (created) {
      _controller = WindowController(
        size: settingsSize,
        title: 'Clipword Settings',
        delegate: _HideOnClose(this),
      );
      // The engine window is created visible — hide while we restyle.
      ShowWindow(hwnd, SW_HIDE);
      _centerOnCursorScreen();
      await applyBackdrop();
      onCreated?.call();
      // Give the Window widget a frame to attach to the new view so the
      // reveal doesn't show an unpainted window.
      await WidgetsBinding.instance.endOfFrame;
    }
    ShowWindow(hwnd, IsIconic(hwnd) != 0 ? SW_RESTORE : SW_SHOW);
    focusWindow(hwnd);
    // DWM drops composition attrs across hide→show; refresh every reveal.
    await applyBackdrop();
  }

  /// Hide without destroying — the widget tree stays mounted and keeps
  /// its state for the next open.
  void hide() {
    if (hwnd == 0) return;
    ShowWindow(hwnd, SW_HIDE);
    onHidden?.call();
  }

  /// Push the persisted backdrop pref ('mica' | 'acrylic' | 'none') to this
  /// window's HWND — the channel applies the same per-window treatment the
  /// palette gets (corners, caption attrs, frame margins).
  Future<void> applyBackdrop() async {
    final h = hwnd;
    if (h == 0) return;
    try {
      await _win.invokeMethod('setWindowBackdrop', {
        'mode': Prefs.get<String>('windowBackdrop'),
        'hwnd': h,
      });
    } catch (_) {}
  }

  /// Center on the monitor under the cursor (mirrors the palette's
  /// 'center' positioning).
  void _centerOnCursorScreen() {
    final rect = calloc<RECT>();
    try {
      if (GetWindowRect(hwnd, rect) == 0) return;
      final r = rect.ref;
      final size =
          Size((r.right - r.left).toDouble(), (r.bottom - r.top).toDouble());
      final wa = cursorWorkArea();
      SetWindowPos(
        hwnd,
        0,
        (wa.left + (wa.width - size.width) / 2).round(),
        (wa.top + (wa.height - size.height) / 2).round(),
        0,
        0,
        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
      );
    } finally {
      calloc.free(rect);
    }
  }

  void dispose() {
    try {
      _controller?.destroy();
    } catch (_) {}
    _controller = null;
  }
}

/// The X button hides instead of destroying — settings is a keep-alive
/// utility window like the palette, not a document.
class _HideOnClose extends WindowControllerDelegate {
  _HideOnClose(this._window);

  final WinSettingsWindow _window;

  @override
  void onWindowCloseRequested(WindowController controller) {
    _window.hide();
  }
}
