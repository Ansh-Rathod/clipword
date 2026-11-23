// TODO(mattkae): remove the ignores when the windowing API is stable.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';

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
    return WidgetsApp(
      title: 'Clipword',
      color: controller.snapshot.accentColor ?? ClipTokens.accent,
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: <T>(settings, builder) {
        return PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
        );
      },
      builder: (context, _) {
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final dark =
                MediaQuery.platformBrightnessOf(context) == Brightness.dark;
            final palette = ClipPalette(
              dark: dark,
              systemAccent: controller.snapshot.accentColor,
              systemAccentFill: controller.snapshot.accentFill,
              systemAccentForeground: controller.snapshot.accentForeground,
            );
            // Windows runs settings in a dedicated engine window
            // (settings_window.dart); the palette view mounts a `Window`
            // subtree once the backend creates its controller. On macOS the
            // `settingsWindow` flag selects content for the second engine.
            final settingsCtrl = _isWindows && !settingsWindow
                ? controller.settingsController
                : null;
            final page = settingsWindow
                ? SettingsPage(controller: controller, palette: palette)
                : PalettePage(controller: controller, palette: palette);
            return ColoredBox(
              color: const Color(0x00000000),
              // WidgetsApp only builds a Navigator/Overlay when routing
              // params are given; a bare `builder` tree has none, and
              // EditableText asserts on `debugCheckHasOverlay` the moment a
              // tap tries to create its selection overlay. Insert one —
              // both palette and settings views run through this builder.
              child: Overlay(
                initialEntries: <OverlayEntry>[
                  OverlayEntry(
                    builder: (context) {
                      // Secondary views must live in a ViewAnchor's `view`
                      // slot — a `View` can't attach inside an ordinary
                      // render position.
                      return settingsCtrl == null
                          ? page
                          : ViewAnchor(
                              view: Window(
                                controller: settingsCtrl as WindowController,
                                child: ClipwordApp(
                                  controller: controller,
                                  settingsWindow: true,
                                ),
                              ),
                              child: page,
                            );
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
