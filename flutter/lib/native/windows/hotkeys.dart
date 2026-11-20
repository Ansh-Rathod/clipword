import 'package:flutter/services.dart';

import 'prefs.dart';

/// Global open-hotkey config — detection lives in the C++ `clipword_win`
/// LL keyboard hook (the hotkey_manager plugin needs a window message loop
/// and was unreliable here). This class only translates the recorded
/// `{key, modifiers[]}` pref into a `{vk, ctrl, alt, shift, win}` map and
/// pushes it to the host; the host invokes `openHotkey` back at us.
class WinHotkeys {
  WinHotkeys({required this.channel});

  final MethodChannel channel;

  /// Default recording when the pref is unset.
  static const defaultRecording = <String, Object?>{
    'key': 'v',
    'modifiers': ['ctrl', 'alt', 'shift'],
  };

  /// The stored recording, or [defaultRecording] when unset/empty (the pref
  /// defaults to `{}`, which must not count as a real recording).
  static Map<String, Object?> get recording {
    final stored = (Prefs.get<Map>('openPaletteShortcut') as Map?)
        ?.cast<String, Object?>();
    if (stored == null || stored.isEmpty || stored['key'] == null) {
      return Map<String, Object?>.from(defaultRecording);
    }
    return Map<String, Object?>.from(stored);
  }

  Future<void> apply() async {
    final rec = recording;
    final keyName = rec['key'] as String?;
    final mods = (rec['modifiers'] as List?)?.cast<String>() ?? const [];
    final vk = keyName == null ? null : vkFor(keyName);
    await channel.invokeMethod('setOpenShortcut', {
      'vk': vk ?? 0x56, // 'V'
      'ctrl': mods.contains('ctrl') || mods.contains('control'),
      'shift': mods.contains('shift'),
      'alt': mods.contains('alt'),
      'win': mods.contains('win') || mods.contains('meta'),
    });
  }

  /// Key name (as produced by the shortcut recorder) → Win32 virtual-key
  /// code. Returns null for unrecognized names.
  static int? vkFor(String name) {
    const named = {
      'space': 0x20,
      'tab': 0x09,
      'enter': 0x0D,
      'comma': 0xBC,
      'period': 0xBE,
      'semicolon': 0xBA,
      'quote': 0xDE,
      'slash': 0xBF,
      'backslash': 0xDC,
      'minus': 0xBD,
      'equal': 0xBB,
      'bracketLeft': 0xDB,
      'bracketRight': 0xDD,
      'backquote': 0xC0,
      'insert': 0x2D,
      'delete': 0x2E,
      'home': 0x24,
      'end': 0x23,
      'pageUp': 0x21,
      'pageDown': 0x22,
      'arrowUp': 0x26,
      'arrowDown': 0x28,
      'arrowLeft': 0x25,
      'arrowRight': 0x27,
      'up': 0x26,
      'down': 0x28,
      'left': 0x25,
      'right': 0x27,
      'numpad0': 0x60,
      'numpad1': 0x61,
      'numpad2': 0x62,
      'numpad3': 0x63,
      'numpad4': 0x64,
      'numpad5': 0x65,
      'numpad6': 0x66,
      'numpad7': 0x67,
      'numpad8': 0x68,
      'numpad9': 0x69,
    };
    if (name.length == 1) {
      final c = name.codeUnitAt(0);
      if (c >= 0x61 && c <= 0x7A) return c - 0x20; // a-z → 'A'-'Z'
      if (c >= 0x30 && c <= 0x39) return c; // '0'-'9'
      return null;
    }
    final lower = name.toLowerCase();
    if (lower.startsWith('f') && lower.length <= 3) {
      final n = int.tryParse(lower.substring(1));
      if (n != null && n >= 1 && n <= 24) return 0x6F + n; // VK_F1
    }
    return named[name] ?? named[lower];
  }

  /// Snapshot → UI label (`"Ctrl+Shift+V"`) — the `shortcutLabel` counterpart.
  static String labelFor(Map<String, Object?>? rec) {
    rec ??= defaultRecording;
    final mods = (rec['modifiers'] as List?)?.cast<String>() ?? const [];
    final key = (rec['key'] as String? ?? 'v').toUpperCase();
    final parts = <String>[
      if (mods.contains('ctrl') || mods.contains('control')) 'Ctrl',
      if (mods.contains('shift')) 'Shift',
      if (mods.contains('alt')) 'Alt',
      if (mods.contains('meta') || mods.contains('win')) 'Win',
      key.length == 1 ? key : key,
    ];
    return parts.join('+');
  }
}
