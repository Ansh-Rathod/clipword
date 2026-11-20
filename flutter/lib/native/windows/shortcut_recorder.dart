import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'windows_backend.dart';

/// Wires [WindowsBackend.recordOpenShortcut] to a small capture dialog —
/// call once from the app root on Windows.
void installShortcutRecorder() {
  WindowsBackend.shortcutRecorder = () async {
    final ctx = WindowsBackend.appContext;
    if (ctx == null || !ctx.mounted) return null;
    return showDialog<Map<String, Object?>>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => const ShortcutRecorderDialog(),
    );
  };
}

/// "Press the shortcut" capture dialog — returns `{key, modifiers[]}`.
class ShortcutRecorderDialog extends StatefulWidget {
  const ShortcutRecorderDialog({super.key});

  @override
  State<ShortcutRecorderDialog> createState() => _RecorderState();
}

class _RecorderState extends State<ShortcutRecorderDialog> {
  final _focus = FocusNode();
  Map<String, Object?>? _captured;

  static final _keyNames = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.space: 'space',
    LogicalKeyboardKey.comma: 'comma',
    LogicalKeyboardKey.period: 'period',
    LogicalKeyboardKey.semicolon: 'semicolon',
    LogicalKeyboardKey.quote: 'quote',
    LogicalKeyboardKey.slash: 'slash',
    LogicalKeyboardKey.backslash: 'backslash',
    LogicalKeyboardKey.minus: 'minus',
    LogicalKeyboardKey.equal: 'equal',
    LogicalKeyboardKey.bracketLeft: 'bracketLeft',
    LogicalKeyboardKey.bracketRight: 'bracketRight',
    LogicalKeyboardKey.backquote: 'backquote',
  };

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final key = event.logicalKey;
    // Modifier keys alone don't finish the recording.
    if (key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.meta ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final hw = HardwareKeyboard.instance;
    final mods = <String>[
      if (hw.isControlPressed) 'ctrl',
      if (hw.isShiftPressed) 'shift',
      if (hw.isAltPressed) 'alt',
      if (hw.isMetaPressed) 'win',
    ];
    if (mods.isEmpty) return KeyEventResult.handled; // require a modifier
    final name = _keyNames[key] ?? key.keyLabel.toLowerCase();
    setState(() {
      _captured = {'key': name, 'modifiers': mods};
    });
    Navigator.of(context).pop(_captured);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Open Clipword'),
      content: SizedBox(
        width: 260,
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Press the shortcut you want to use\n(Esc to cancel)',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
