import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Windows accent color — the `accentColor`/`accentFill`/`accentForeground`
/// snapshot keys' counterpart. Reads `HKCU\Software\Microsoft\Windows\DWM`.
class WinAccent {
  WinAccent._();

  static List<double>? _cached;
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// `[r,g,b,a]` components 0..1 (same shape as `colorComponents` on macOS).
  static List<double>? accent() {
    if (_cached != null &&
        DateTime.now().difference(_cachedAt) < const Duration(seconds: 10)) {
      return _cached;
    }
    final value = _readDwmDword('AccentColor');
    if (value == null) return _cached;
    // AccentColor is 0xAABBGGRR (COLORREF + alpha in high byte).
    final a = ((value >> 24) & 0xFF) / 255.0;
    final b = ((value >> 16) & 0xFF) / 255.0;
    final g = ((value >> 8) & 0xFF) / 255.0;
    final r = (value & 0xFF) / 255.0;
    _cached = [r, g, b, a == 0 ? 1.0 : a];
    _cachedAt = DateTime.now();
    return _cached;
  }

  /// Foreground on accent — white or near-black by luminance.
  static List<double> foreground() {
    final c = accent() ?? const [0, 0.48, 1, 1];
    final lum = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
    return lum > 0.6 ? [0, 0, 0, 1] : [1, 1, 1, 1];
  }

  static int? _readDwmDword(String name) {
    final key = calloc.allocate<HKEY>(sizeOf<HKEY>());
    final path = r'Software\Microsoft\Windows\DWM'.toNativeUtf16(allocator: calloc);
    try {
      if (RegOpenKeyEx(HKEY_CURRENT_USER, path, 0, KEY_QUERY_VALUE, key) !=
          ERROR_SUCCESS) {
        return null;
      }
      try {
        final data = calloc.allocate<DWORD>(sizeOf<DWORD>());
        final size = calloc.allocate<DWORD>(sizeOf<DWORD>())..value = sizeOf<DWORD>();
        final type = calloc.allocate<DWORD>(sizeOf<DWORD>());
        try {
          if (RegQueryValueEx(key.value, name.toNativeUtf16(allocator: calloc), nullptr, type,
                  data.cast<BYTE>(), size) ==
              ERROR_SUCCESS) {
            return data.value;
          }
          return null;
        } finally {
          calloc.free(data);
          calloc.free(size);
          calloc.free(type);
        }
      } finally {
        RegCloseKey(key.value);
      }
    } finally {
      calloc.free(path);
      calloc.free(key);
    }
  }
}
