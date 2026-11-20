import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Foreground-application identity — the Windows analogue of
/// `NSWorkspace.frontmostApplication`. Returns normalized exe paths like
/// `c:\program files\app\app.exe` (lowered, backslashed) as the "bundle id".
class WinApps {
  WinApps._();

  /// Exe path of the window currently in the foreground, or null.
  static String? frontmostAppId({int? hwnd}) {
    final h = hwnd ?? GetForegroundWindow();
    if (h == 0) return null;
    final pid = calloc.allocate<DWORD>(sizeOf<DWORD>());
    try {
      GetWindowThreadProcessId(h, pid);
      final process = OpenProcess(
          PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid.value);
      if (process == NULL) return null;
      try {
        final buf = calloc.allocate<Utf16>((32767) * 2);
        final size = calloc.allocate<DWORD>(sizeOf<DWORD>())..value = 32767;
        try {
          if (QueryFullProcessImageName(process, 0, buf, size) == 0) {
            return null;
          }
          return normalizePath(buf.toDartString());
        } finally {
          calloc.free(buf);
          calloc.free(size);
        }
      } finally {
        CloseHandle(process);
      }
    } finally {
      calloc.free(pid);
    }
  }

  static String normalizePath(String path) =>
      path.replaceAll('/', '\\').toLowerCase();

  /// Display name for an app id — exe basename minus extension, matching the
  /// `appName(for:)` role from the macOS host.
  static String appName(String bundleId) {
    if (bundleId == 'unknown') return 'Unknown';
    final norm = bundleId.replaceAll('/', '\\');
    final base = norm.substring(norm.lastIndexOf('\\') + 1);
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    if (stem.isEmpty) return 'Unknown';
    return stem[0].toUpperCase() + stem.substring(1);
  }

  /// Own exe path (to filter Clipword out of app lists).
  static String ownAppId() => normalizePath(Platform.resolvedExecutable);
}
