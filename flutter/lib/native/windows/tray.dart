import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// System-tray icon — the Windows analogue of the macOS status item.
/// The icon + right-click menu are owned by the C++ `clipword_win` host
/// (Shell_NotifyIcon + TrackPopupMenu); this class only installs it and
/// dispatches the `trayEvent`/`trayMenu` callbacks the host invokes.
class WinTray {
  WinTray({
    required this.channel,
    required this.onShowPalette,
    required this.onShowSettings,
    required this.onQuit,
  });

  final MethodChannel channel;
  final void Function() onShowPalette;
  final void Function() onShowSettings;
  final void Function() onQuit;

  Future<void> init() async {
    final icon = File(
        p.join(p.dirname(Platform.resolvedExecutable), 'app_icon.ico'));
    await channel.invokeMethod('installTray', {
      'iconPath': icon.existsSync() ? icon.path : '',
      'tooltip': 'Clipword',
    });
  }

  Future<void> dispose() async {
    await channel.invokeMethod('removeTray');
  }

  /// `trayEvent` from the host (icon click).
  void dispatchEvent(String event) {
    if (event == 'click') onShowPalette();
  }

  /// `trayMenu` from the host (menu item id).
  void dispatchMenu(String id) {
    switch (id) {
      case 'show':
        onShowPalette();
      case 'settings':
        onShowSettings();
      case 'quit':
        onQuit();
    }
  }
}
