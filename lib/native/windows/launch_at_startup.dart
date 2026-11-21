import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// `LaunchAtLoginHelper` port — HKCU\...\Run registry value.
class LaunchAtStartup {
  LaunchAtStartup._();

  static const _keyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'Clipword';

  static void setEnabled(bool enabled) {
    final key = calloc.allocate<HKEY>(sizeOf<HKEY>());
    final path = _keyPath.toNativeUtf16(allocator: calloc);
    try {
      if (RegOpenKeyEx(HKEY_CURRENT_USER, path, 0, KEY_SET_VALUE, key) !=
          ERROR_SUCCESS) {
        return;
      }
      try {
        if (enabled) {
          final exe = '"${Platform.resolvedExecutable}"'.toNativeUtf16(allocator: calloc);
          try {
            RegSetValueEx(key.value, _valueName.toNativeUtf16(allocator: calloc), 0, REG_SZ,
                exe.cast(), (exe.length + 1) * 2);
          } finally {
            calloc.free(exe);
          }
        } else {
          RegDeleteValue(key.value, _valueName.toNativeUtf16(allocator: calloc));
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
