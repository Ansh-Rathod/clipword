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
  static const settingsSidebar = 196.0;
  static const rowRadius = 6.0;
  static const keycapMin = 18.0;
  static const keycapRadius = 5.0;

  static const accent = Color(0xFF0A84FF);
  static const pin = Color(0xFFFF9F0A);
  static const bookmark = Color(0xFF0A84FF);
  static const success = Color(0xFF30D158);
}

class ClipPalette {
  ClipPalette({required this.dark});

  final bool dark;

  Color get label => dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  Color get secondary => dark ? const Color(0x99EBEBF5) : const Color(0x993C3C43);
  Color get tertiary => dark ? const Color(0x4DEBEBF5) : const Color(0x4D3C3C43);
  Color get panel => dark
      ? const Color(0x99000000)
      : const Color(0x99FFFFFF);
  Color get window => dark ? const Color(0xFF1E1E1E) : const Color(0xFFF2F2F7);
  Color get divider => dark ? const Color(0x33FFFFFF) : const Color(0x33000000);
  Color get hover => label.withValues(alpha: 0.07);
  Color get selectedIdle => label.withValues(alpha: 0.10);
  Color get chipFill => label.withValues(alpha: ClipTokens.controlFill);
}
