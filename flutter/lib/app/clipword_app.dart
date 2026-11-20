import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../native/windows/shortcut_recorder.dart';
import '../native/windows/windows_backend.dart';
import '../palette/palette_page.dart';
import '../settings/settings_page.dart';
import '../theme/tokens.dart';
import 'controller.dart';

class ClipwordApp extends StatelessWidget {
  const ClipwordApp({
    super.key,
    required this.controller,
    this.settingsWindow = false,
  });
  final ClipwordController controller;
  final bool settingsWindow;

  static bool get _isWindows => !kIsWeb && Platform.isWindows;

  @override
  Widget build(BuildContext context) {
    if (_isWindows) {
      // Give the backend a context for backend-driven dialogs (shortcut
      // recorder) and install the recorder hook once.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WindowsBackend.appContext = context;
      });
      installShortcutRecorder();
    }
    return WidgetsApp(
      title: 'Clipword',
      color: controller.snapshot.accentColor ?? ClipTokens.accent,
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: <T>(settings, builder) {
        return PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, animation, secondaryAnimation) => builder(context),
        );
      },
      builder: (context, _) {
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
            final palette = ClipPalette(
              dark: dark,
              systemAccent: controller.snapshot.accentColor,
              systemAccentFill: controller.snapshot.accentFill,
              systemAccentForeground: controller.snapshot.accentForeground,
            );
            // Windows renders settings inside the one and only window —
            // the backend reports windowMode == 'settings'.
            final showSettings = settingsWindow ||
                (_isWindows && controller.windowMode == 'settings');
            return ColoredBox(
              color: const Color(0x00000000),
              child: showSettings
                  ? SettingsPage(controller: controller, palette: palette)
                  : PalettePage(controller: controller, palette: palette),
            );
          },
        );
      },
    );
  }
}
