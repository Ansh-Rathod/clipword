import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'prefs.dart';

/// Palette/settings window management — one window resized/re-flagged between
/// modes (port of `setupPalette`/`setupSettings`/`swapContent`, minus the
/// second window). Pure Win32 on the runner HWND: plugins couldn't find a
/// hidden-at-boot window reliably, so this talks to the window directly.
class WinWindowing {
  WinWindowing({
    required this.onHide,
    required this.onFocusLost,
    required this.onModeChanged,
  });

  static const paletteSize = Size(720, 520);
  static const settingsSize = Size(780, 600);

  final void Function() onHide;
  final void Function() onFocusLost;
  final void Function(String mode) onModeChanged;

  String windowMode = 'hidden';
  String source = 'history';
  double? _paletteHeightOverride;

  int _hwnd = 0;

  /// Our runner HWND. Can't use a bare `FindWindow` — the class name
  /// `FLUTTER_RUNNER_WIN32_WINDOW` is shared by every Flutter desktop app
  /// on the machine (e.g. RustDesk), so enumerate class matches and keep
  /// the one owned by this process.
  static int _findWindow() {
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: calloc);
    final pid = GetCurrentProcessId();
    final out = calloc<Uint32>();
    try {
      var h = 0;
      var found = 0;
      while (true) {
        h = FindWindowEx(0, h, cls, nullptr);
        if (h == 0) break;
        GetWindowThreadProcessId(h, out);
        if (out.value == pid) {
          found = h;
          break;
        }
      }
      return found;
    } finally {
      calloc.free(out);
      calloc.free(cls);
    }
  }

  int get hwnd {
    if (_hwnd == 0 || IsWindow(_hwnd) == 0) _hwnd = _findWindow();
    return _hwnd;
  }

  Future<void> init() async {
    // Created hidden by the runner; make it palette-shaped immediately so the
    // first hotkey reveal doesn't flicker through the default frame.
    _setFrameless(true);
    _setAlwaysOnTop(true);
    _setSize(paletteSize);
    _setTaskbarVisible(false);
  }

  /// Whether the window gets a taskbar button / Alt+Tab entry. The invisible
  /// `Static` owner (set in the runner) hides it normally; WS_EX_APPWINDOW
  /// forces presence even on an owned window — wanted in settings mode only.
  /// Do NOT add WS_EX_TOOLWINDOW: it shrinks the caption to a lone close.
  void _setTaskbarVisible(bool visible) {
    final ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    final next = visible ? (ex | WS_EX_APPWINDOW) : (ex & ~WS_EX_APPWINDOW);
    if (next != ex) {
      SetWindowLongPtr(hwnd, GWL_EXSTYLE, next);
      SetWindowPos(hwnd, 0, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
              SWP_FRAMECHANGED);
    }
  }

  Future<void> showPalette({String? forSource, bool activate = true}) async {
    if (windowMode != 'palette') {
      _setAlwaysOnTop(true);
      _setFrameless(true);
      _setTaskbarVisible(false);
      _setSize(Size(
          paletteSize.width, _paletteHeightOverride ?? paletteSize.height));
    }
    if (forSource != null) source = forSource;
    final wasHidden = windowMode == 'hidden';
    windowMode = 'palette';
    onModeChanged(windowMode);
    if (wasHidden) _positionForPref();
    _show();
    if (activate) _focus();
  }

  Future<void> showSettings() async {
    if (windowMode == 'settings') {
      _focus();
      return;
    }
    windowMode = 'settings';
    _setAlwaysOnTop(false);
    _setFrameless(false);
    _setTaskbarVisible(true);
    _setSize(settingsSize);
    _centerOnCursorScreen();
    _show();
    _focus();
    onModeChanged(windowMode);
  }

  /// Back from settings → palette (mirrors `swapContent(backToPalette)`).
  Future<void> backToPalette({String? forSource}) async {
    if (forSource != null) source = forSource;
    windowMode = 'palette';
    _setFrameless(true);
    _setAlwaysOnTop(true);
    _setTaskbarVisible(false);
    _setSize(Size(
        paletteSize.width, _paletteHeightOverride ?? paletteSize.height));
    onModeChanged(windowMode);
    _positionForPref();
    _show();
    _focus();
  }

  Future<void> hide() async {
    if (windowMode == 'hidden') return;
    windowMode = 'hidden';
    onModeChanged(windowMode);
    _hideWindow();
    onHide();
  }

  /// Runner forwarded WM_CLOSE: the OS window is already hidden natively —
  /// only update the mode bookkeeping here.
  void notifyClosed() {
    if (windowMode == 'hidden') return;
    windowMode = 'hidden';
    onModeChanged(windowMode);
    onHide();
  }

  /// Runner forwarded WA_INACTIVE (port of `windowDidResignKey` → auto-hide).
  void notifyDeactivated() {
    if (windowMode == 'palette') {
      _saveFrame();
      onFocusLost();
    }
  }

  Future<void> setPaletteHeight(double h) async {
    _paletteHeightOverride = h;
    if (windowMode == 'palette') {
      _setSize(Size(paletteSize.width, h));
    }
  }

  // ---------- position prefs ----------

  void _positionForPref() {
    switch (Prefs.get<String>('popupPosition')) {
      case 'cursor':
        _atCursor();
      case 'menuBar':
        _nearTray();
      case 'lastPosition':
        if (!_restoreSavedFrame()) _centerOnCursorScreen();
      default: // 'center'
        _centerOnCursorScreen();
    }
  }

  /// Work area of the monitor under the mouse cursor.
  static Rect _cursorWorkArea() {
    final pt = calloc<POINT>();
    final info = calloc<MONITORINFO>();
    try {
      GetCursorPos(pt);
      final hMon = MonitorFromPoint(pt.ref, MONITOR_DEFAULTTONEAREST);
      info.ref.cbSize = sizeOf<MONITORINFO>();
      if (GetMonitorInfo(hMon, info) == 0) {
        return const Rect.fromLTWH(0, 0, 1920, 1080);
      }
      final r = info.ref.rcWork;
      return Rect.fromLTWH(r.left.toDouble(), r.top.toDouble(),
          (r.right - r.left).toDouble(), (r.bottom - r.top).toDouble());
    } finally {
      calloc.free(info);
      calloc.free(pt);
    }
  }

  /// Primary work area (taskbar side — used for 'menuBar'/tray positioning).
  static Rect _primaryWorkArea() {
    final rect = calloc<RECT>();
    try {
      if (SystemParametersInfo(SPI_GETWORKAREA, 0, rect, 0) == 0) {
        return const Rect.fromLTWH(0, 0, 1920, 1040);
      }
      final r = rect.ref;
      return Rect.fromLTWH(r.left.toDouble(), r.top.toDouble(),
          (r.right - r.left).toDouble(), (r.bottom - r.top).toDouble());
    } finally {
      calloc.free(rect);
    }
  }

  void _centerOnCursorScreen() {
    final wa = _cursorWorkArea();
    final size = _size();
    _setPosition(Offset(
      wa.left + (wa.width - size.width) / 2,
      wa.top + (wa.height - size.height) / 2,
    ));
  }

  void _atCursor({double padding = 12}) {
    final pt = calloc<POINT>();
    late double cx, cy;
    try {
      GetCursorPos(pt);
      cx = pt.ref.x.toDouble();
      cy = pt.ref.y.toDouble();
    } finally {
      calloc.free(pt);
    }
    final wa = _cursorWorkArea();
    final size = _size();
    final x = (cx - size.width / 2).clamp(wa.left, wa.right - size.width);
    final y = (cy + padding).clamp(wa.top, wa.bottom - size.height);
    _setPosition(Offset(x, y));
  }

  void _nearTray() {
    // Notification area sits at the taskbar edge — bottom-right of the
    // primary work area for the default bottom taskbar.
    final wa = _primaryWorkArea();
    final size = _size();
    _setPosition(Offset(
      wa.left + wa.width - size.width - 8,
      wa.top + wa.height - size.height - 8,
    ));
  }

  bool _restoreSavedFrame() {
    final frame = Prefs.popupLastFrame();
    if (frame == null) return false;
    _setPosition(Offset(frame.x, frame.y));
    return true;
  }

  void _saveFrame() {
    final pos = _position();
    if (pos != null) Prefs.setPopupLastFrame(PopupFrame(pos.dx, pos.dy));
  }

  // ---------- raw window ops ----------

  /// SW_SHOW leaves a minimized window parked at -32000 — restore it first.
  void _show() {
    if (IsIconic(hwnd) != 0) {
      ShowWindow(hwnd, SW_RESTORE);
    } else {
      ShowWindow(hwnd, SW_SHOW);
    }
  }

  void _hideWindow() => ShowWindow(hwnd, SW_HIDE);

  void _focus() {
    final target = hwnd;
    if (target == 0) return;
    // Same AttachThreadInput dance as WinPaste: SetForegroundWindow is
    // restricted when the caller isn't the foreground process.
    final foregroundThread =
        GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
    final targetThread = GetWindowThreadProcessId(target, nullptr);
    final currentThread = GetCurrentThreadId();
    AttachThreadInput(currentThread, foregroundThread, TRUE);
    AttachThreadInput(currentThread, targetThread, TRUE);
    SetForegroundWindow(target);
    BringWindowToTop(target);
    AttachThreadInput(currentThread, foregroundThread, FALSE);
    AttachThreadInput(currentThread, targetThread, FALSE);
  }

  Size _size() {
    final rect = calloc<RECT>();
    try {
      GetWindowRect(hwnd, rect);
      final r = rect.ref;
      return Size(
          (r.right - r.left).toDouble(), (r.bottom - r.top).toDouble());
    } finally {
      calloc.free(rect);
    }
  }

  Offset? _position() {
    final rect = calloc<RECT>();
    try {
      if (GetWindowRect(hwnd, rect) == 0) return null;
      return Offset(rect.ref.left.toDouble(), rect.ref.top.toDouble());
    } finally {
      calloc.free(rect);
    }
  }

  /// `size` is in Flutter logical px — the window rect SetWindowPos wants is
  /// physical px including non-client chrome, so scale by the monitor DPI and
  /// grow for the frame.
  void _setSize(Size size) {
    final dpi = GetDpiForWindow(hwnd);
    final rect = calloc<RECT>();
    try {
      rect.ref.right = (size.width * dpi / 96).round();
      rect.ref.bottom = (size.height * dpi / 96).round();
      AdjustWindowRectExForDpi(rect, GetWindowLongPtr(hwnd, GWL_STYLE), 0,
          GetWindowLongPtr(hwnd, GWL_EXSTYLE), dpi);
      SetWindowPos(hwnd, 0, 0, 0, rect.ref.right - rect.ref.left,
          rect.ref.bottom - rect.ref.top,
          SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    } finally {
      calloc.free(rect);
    }
  }

  void _setPosition(Offset pos) {
    SetWindowPos(hwnd, 0, pos.dx.round(), pos.dy.round(), 0, 0,
        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }

  void _setAlwaysOnTop(bool top) {
    SetWindowPos(hwnd, top ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }

  void _setFrameless(bool frameless) {
    const chrome = WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
    final style = GetWindowLongPtr(hwnd, GWL_STYLE);
    final next = frameless ? (style & ~chrome) : (style | chrome);
    if (next != style) {
      SetWindowLongPtr(hwnd, GWL_STYLE, next);
      SetWindowPos(hwnd, 0, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
              SWP_FRAMECHANGED);
    }
  }
}
