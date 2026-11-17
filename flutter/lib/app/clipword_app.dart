import 'package:flutter/widgets.dart';

import '../palette/palette_page.dart';
import '../settings/settings_page.dart';
import '../theme/tokens.dart';
import 'controller.dart';

class ClipwordApp extends StatelessWidget {
  const ClipwordApp({super.key, required this.controller});
  final ClipwordController controller;

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      color: ClipTokens.accent,
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
            final palette = ClipPalette(dark: dark);
            final settings = controller.windowMode == 'settings';
            return ColoredBox(
              color: settings ? palette.window : const Color(0x00000000),
              child: settings
                  ? SettingsPage(controller: controller, palette: palette)
                  : PalettePage(controller: controller, palette: palette),
            );
          },
        );
      },
    );
  }
}
