import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'apps.dart';

/// Port of `PasteService` — remembers the frontmost app before the palette
/// shows, restores focus, and sends Ctrl+V (or unicode keystrokes) via
/// `SendInput`.
class WinPaste {
  WinPaste._();

  static int? _savedHwnd;
  static String? _savedAppId;
  static bool _pasting = false;

  static bool get isPasting => _pasting;

  /// Call when the palette is about to show.
  static void saveFrontmost() {
    final h = GetForegroundWindow();
    if (h != 0) {
      _savedHwnd = h;
      _savedAppId = WinApps.frontmostAppId(hwnd: h);
    }
  }

  static String? get savedAppId => _savedAppId;

  /// Bring the previously-foreground window back, then send Ctrl+V.
  /// `AttachThreadInput` is needed because Windows refuses
  /// `SetForegroundWindow` from a non-foreground process.
  static void restoreAndPaste({bool unformatted = false}) {
    final target = _savedHwnd;
    if (target != null && IsWindow(target) != 0) {
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
    sendCtrlV();
  }

  /// Sends Ctrl+Shift+V (unformatted paste in many Windows apps) — falls back
  /// to Ctrl+V when the app ignores it.
  static void sendCtrlV({bool shift = false}) {
    _pasting = true;
    final count = shift ? 6 : 4;
    try {
      final inputs = calloc.allocate<INPUT>((count) * sizeOf<INPUT>());
      try {
        var i = 0;
        void key(int vk, bool up) {
          inputs[i].type = INPUT_KEYBOARD;
          inputs[i].ki.wVk = vk;
          inputs[i].ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
          i++;
        }

        key(VK_CONTROL, false);
        if (shift) key(VK_SHIFT, false);
        key(VK_V, false);
        key(VK_V, true);
        if (shift) key(VK_SHIFT, true);
        key(VK_CONTROL, true);
        SendInput(count, inputs, sizeOf<INPUT>());
      } finally {
        calloc.free(inputs);
      }
    } finally {
      // Keep the flag up briefly so the clipboard monitor doesn't treat the
      // resulting paste as a user copy.
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        _pasting = false;
      });
    }
  }
}
