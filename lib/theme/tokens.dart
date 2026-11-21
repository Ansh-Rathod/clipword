import 'package:flutter/widgets.dart';

class ClipTokens {
  static const panelRadius = 24.0;
  static const iconButtonSize = 36.0;
  static const iconRadius = 12.0;
  static const iconFont = 15.0;
  static const pillPaddingH = 14.0;
  static const pillPaddingV = 9.0;
  static const controlFill = 0.10;
  static const listMin = 240.0;
  static const listIdeal = 300.0;
  static const listMax = 360.0;
  static const settingsSidebar = 200.0;
  static const settingsTitlebar = 52.0;
  static const settingsGroupRadius = 10.0;
  static const rowRadius = 6.0;
  static const keycapMin = 18.0;
  static const keycapRadius = 5.0;

  /// Overlay on the native blur. 0 = glass only, 1 = solid `background`.
  static const panelOpacity = 0.7;

  /// Raycast loader / brand red.
  static const accent = Color(0xFFFF6363);
  static const pin = Color(0xFFFCA72F);
  static const bookmark = Color(0xFF0091FF);
  static const success = Color(0xFF28CD41);
}

/// Default Raycast Light / Dark theme slots:
/// background, backgroundSecondary, text, selection, loader,
/// red, orange, yellow, green, blue, purple, magenta.
class ClipPalette {
  ClipPalette({
    required this.dark,
    this.systemAccent,
    this.systemAccentFill,
    this.systemAccentForeground,
  });

  final bool dark;
  final Color? systemAccent;
  final Color? systemAccentFill;
  final Color? systemAccentForeground;

  Color get background =>
      dark ? const Color(0xFF1A1A1A) : const Color(0xFFFFFFFF);
  Color get backgroundSecondary =>
      dark ? const Color(0xFF242424) : const Color(0xFFF4F4F4);
  Color get text => dark ? const Color(0xFFFFFFFF) : const Color(0xFF1A1A1A);
  Color get selection =>
      dark ? const Color(0xFF333333) : const Color(0xFFE8E8E8);
  Color get loader => const Color(0xFFFF6363);

  Color get red => dark ? const Color(0xFFFF6363) : const Color(0xFFFF3B30);
  Color get orange => dark ? const Color(0xFFFCA72F) : const Color(0xFFFF9500);
  Color get yellow => dark ? const Color(0xFFFFD60A) : const Color(0xFFFFCC00);
  Color get green => dark ? const Color(0xFF34C759) : const Color(0xFF28CD41);
  Color get blue => dark ? const Color(0xFF5AC8FA) : const Color(0xFF0091FF);
  Color get purple => dark ? const Color(0xFFBF5AF2) : const Color(0xFFAF52DE);
  Color get magenta => dark ? const Color(0xFFFF375F) : const Color(0xFFFF2D55);

  Color get label => text;
  /// Buttons and popup values — lighter than primary row labels.
  Color get controlLabel => text.withValues(alpha: dark ? 0.78 : 0.58);
  Color get secondary => text.withValues(alpha: 0.55);
  Color get tertiary => text.withValues(alpha: 0.32);
  Color get panel => background.withValues(alpha: ClipTokens.panelOpacity);
  Color get window => panel;
  Color get sidebar => const Color(0x00000000);

  Color get grouped => dark ? const Color(0x28FFFFFF) : const Color(0x3DFFFFFF);
  Color get control => dark ? const Color(0x66333333) : const Color(0x3D1A1A1A);
  Color get chipFill =>
      dark ? const Color(0x66333333) : const Color(0x141A1A1A);
  Color get divider => text.withValues(alpha: dark ? 0.12 : 0.08);
  Color get hover => dark ? const Color(0x33333333) : const Color(0x141A1A1A);
  Color get selectedIdle =>
      dark ? const Color(0x59333333) : const Color(0x291A1A1A);
  Color get toggleOff =>
      dark ? const Color(0x66333333) : const Color(0x291A1A1A);
  Color get accent => systemAccent ?? blue;
  Color get accentFill => systemAccentFill ?? accent;
  Color get onAccent => systemAccentForeground ?? const Color(0xFFFFFFFF);
  Color get success => green;
  Color get destructive => red;
  Color get gray => text.withValues(alpha: 0.45);
}
