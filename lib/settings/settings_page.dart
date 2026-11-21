import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../app/controller.dart';
import '../native/channel.dart';
import '../native/models.dart';
import '../palette/widgets.dart';
import '../theme/tokens.dart';

bool get _isWin => !kIsWeb && Platform.isWindows;

/// Primary-modifier glyph token: '⌘' macOS, 'Ctrl' Windows.
String get _modKey => _isWin ? 'Ctrl' : '⌘';
String get _shiftKey => _isWin ? 'Shift' : '⇧';
String get _altKey => _isWin ? 'Alt' : '⌥';
String get _menuBarLabel => _isWin ? 'Near tray icon' : 'At menu bar';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.palette,
  });
  final ClipwordController controller;
  final ClipPalette palette;

  List<_NavItem> get _sections => [
    _NavItem('general', 'General', 'gear', palette.gray),
    _NavItem('storage', 'Storage', 'internaldrive', palette.accent),
    _NavItem('ignore', 'Ignore', 'eye.slash', palette.orange),
    _NavItem('advanced', 'Advanced', 'wrench.and.screwdriver', palette.success),
  ];

  @override
  Widget build(BuildContext context) {
    final snap = controller.snapshot;
    final bar = _titlebarHeight(context);
    final current = _sections.firstWhere(
      (section) => section.id == snap.settingsSection,
      orElse: () => _sections.first,
    );
    return Row(
      children: [
        SizedBox(
          width: ClipTokens.settingsSidebar,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // On Windows the native titlebar owns the top chrome — the
              // sidebar just needs a small inset, not the macOS gap.
              SizedBox(height: _isWin ? 5 : bar),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final section in _sections)
                        _SidebarItem(
                          item: section,
                          selected: snap.settingsSection == section.id,
                          palette: palette,
                          onTap: () =>
                              controller.channel.setSettingsSection(section.id),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        ColoredBox(
          color: palette.divider,
          child: const SizedBox(width: 1, height: double.infinity),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: bar,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 36),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        _SettingsGlyph(icon: current.icon, tint: current.tint),
                        const SizedBox(width: 8),
                        Text(
                          current.title,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.3,
                            color: palette.label,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(child: ClipRect(child: _pane(snap))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pane(ClipSnapshot snap) {
    switch (snap.settingsSection) {
      case 'storage':
        return StoragePane(controller: controller, palette: palette);
      case 'ignore':
        return IgnorePane(controller: controller, palette: palette);
      case 'advanced':
        return AdvancedPane(controller: controller, palette: palette);
      default:
        return GeneralPane(controller: controller, palette: palette);
    }
  }
}

class _NavItem {
  const _NavItem(this.id, this.title, this.icon, this.tint);
  final String id;
  final String title;
  final String icon;
  final Color tint;
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.item,
    required this.selected,
    required this.palette,
    required this.onTap,
  });
  final _NavItem item;
  final bool selected;
  final ClipPalette palette;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final fill = selected
        ? widget.palette.accentFill
        : hovered
        ? widget.palette.hover
        : const Color(0x00000000);
    final label = selected ? widget.palette.onAccent : widget.palette.label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
            child: Row(
              children: [
                _SettingsGlyph(icon: widget.item.icon, tint: widget.item.tint),
                const SizedBox(width: 8),
                Text(
                  widget.item.title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: label,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

double _titlebarHeight(BuildContext context) {
  final pad = MediaQuery.paddingOf(context).top;
  return pad > ClipTokens.settingsTitlebar ? pad : ClipTokens.settingsTitlebar;
}

class _SettingsGlyph extends StatelessWidget {
  const _SettingsGlyph({required this.icon, required this.tint});
  final String icon;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SizedBox(
        width: 24,
        height: 24,
        child: Center(
          child: SymbolIcon(icon, size: 12, color: const Color(0xFFFFFFFF)),
        ),
      ),
    );
  }
}

class _PaneScaffold extends StatelessWidget {
  const _PaneScaffold({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(36, 12, 36, 40),
      children: children,
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({this.title, required this.children, required this.palette});
  final String? title;
  final List<Widget> children;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                title!,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.1,
                  color: palette.secondary,
                ),
              ),
            ),
          ],
          DecoratedBox(
            decoration: BoxDecoration(
              color: palette.grouped,
              borderRadius: BorderRadius.circular(
                ClipTokens.settingsGroupRadius,
              ),
            ),
            child: Column(
              children: [
                for (final (i, child) in children.indexed) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: ColoredBox(
                        color: palette.divider,
                        child: const SizedBox(
                          height: 0.5,
                          width: double.infinity,
                        ),
                      ),
                    ),
                  child,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PrefRow extends StatelessWidget {
  const _PrefRow({
    required this.label,
    required this.child,
    this.caption,
    required this.palette,
  });
  final String label;
  final Widget child;
  final String? caption;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 13, color: palette.label),
                ),
                if (caption != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      caption!,
                      style: TextStyle(fontSize: 11, color: palette.secondary),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          child,
        ],
      ),
    );
  }
}

class _PushButton extends StatefulWidget {
  const _PushButton({
    required this.label,
    required this.onTap,
    required this.palette,
    this.destructive = false,
  });
  final String label;
  final VoidCallback onTap;
  final ClipPalette palette;
  final bool destructive;

  @override
  State<_PushButton> createState() => _PushButtonState();
}

class _PushButtonState extends State<_PushButton> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final fill = hovered ? widget.palette.control : widget.palette.chipFill;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: 13,
                color: widget.destructive
                    ? widget.palette.destructive
                    : widget.palette.controlLabel,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortcutKeys extends StatelessWidget {
  const _ShortcutKeys(this.keys, {required this.palette});
  final List<String> keys;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, key) in keys.indexed) ...[
          if (i > 0) const SizedBox(width: 3),
          Keycap(text: key, palette: palette),
        ],
      ],
    );
  }
}

class _ShortcutRecorderField extends StatefulWidget {
  const _ShortcutRecorderField({
    required this.keys,
    required this.palette,
    required this.channel,
  });
  final List<String> keys;
  final ClipPalette palette;
  final ClipwordChannel channel;

  @override
  State<_ShortcutRecorderField> createState() => _ShortcutRecorderFieldState();
}

class _ShortcutRecorderFieldState extends State<_ShortcutRecorderField> {
  final _focus = FocusNode(skipTraversal: true);
  bool hovered = false;
  bool recording = false;
  bool listening = false;

  static final _named = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.space: 'space',
    LogicalKeyboardKey.tab: 'tab',
    LogicalKeyboardKey.enter: 'enter',
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
    LogicalKeyboardKey.insert: 'insert',
    LogicalKeyboardKey.delete: 'delete',
    LogicalKeyboardKey.home: 'home',
    LogicalKeyboardKey.end: 'end',
    LogicalKeyboardKey.pageUp: 'pageUp',
    LogicalKeyboardKey.pageDown: 'pageDown',
    LogicalKeyboardKey.arrowUp: 'up',
    LogicalKeyboardKey.arrowDown: 'down',
    LogicalKeyboardKey.arrowLeft: 'left',
    LogicalKeyboardKey.arrowRight: 'right',
    LogicalKeyboardKey.keyA: 'a',
    LogicalKeyboardKey.keyB: 'b',
    LogicalKeyboardKey.keyC: 'c',
    LogicalKeyboardKey.keyD: 'd',
    LogicalKeyboardKey.keyE: 'e',
    LogicalKeyboardKey.keyF: 'f',
    LogicalKeyboardKey.keyG: 'g',
    LogicalKeyboardKey.keyH: 'h',
    LogicalKeyboardKey.keyI: 'i',
    LogicalKeyboardKey.keyJ: 'j',
    LogicalKeyboardKey.keyK: 'k',
    LogicalKeyboardKey.keyL: 'l',
    LogicalKeyboardKey.keyM: 'm',
    LogicalKeyboardKey.keyN: 'n',
    LogicalKeyboardKey.keyO: 'o',
    LogicalKeyboardKey.keyP: 'p',
    LogicalKeyboardKey.keyQ: 'q',
    LogicalKeyboardKey.keyR: 'r',
    LogicalKeyboardKey.keyS: 's',
    LogicalKeyboardKey.keyT: 't',
    LogicalKeyboardKey.keyU: 'u',
    LogicalKeyboardKey.keyV: 'v',
    LogicalKeyboardKey.keyW: 'w',
    LogicalKeyboardKey.keyX: 'x',
    LogicalKeyboardKey.keyY: 'y',
    LogicalKeyboardKey.keyZ: 'z',
    LogicalKeyboardKey.digit0: '0',
    LogicalKeyboardKey.digit1: '1',
    LogicalKeyboardKey.digit2: '2',
    LogicalKeyboardKey.digit3: '3',
    LogicalKeyboardKey.digit4: '4',
    LogicalKeyboardKey.digit5: '5',
    LogicalKeyboardKey.digit6: '6',
    LogicalKeyboardKey.digit7: '7',
    LogicalKeyboardKey.digit8: '8',
    LogicalKeyboardKey.digit9: '9',
  };

  static bool _isModifier(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.control ||
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
      key == LogicalKeyboardKey.metaRight;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    if (recording) {
      widget.channel.cancelOpenShortcutRecording();
    }
    _focus.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (recording) return;
    setState(() => recording = true);
    if (_isWin) {
      _focus.requestFocus();
      return;
    }
    try {
      await widget.channel.recordOpenShortcut();
    } finally {
      if (mounted) setState(() => recording = false);
    }
  }

  void _onFocus() {
    if (!_isWin) return;
    final focused = _focus.hasFocus;
    if (focused && !listening) {
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
      listening = true;
      widget.channel.pauseOpenShortcut(true);
    } else if (!focused && listening) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
      listening = false;
      widget.channel.pauseOpenShortcut(false);
      if (recording) setState(() => recording = false);
    }
  }

  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return true;
    final key = event.logicalKey;
    if (_isModifier(key)) return true;
    if (key == LogicalKeyboardKey.escape) {
      _focus.unfocus();
      return true;
    }
    final hw = HardwareKeyboard.instance;
    final mods = <String>[
      if (hw.isControlPressed) 'ctrl',
      if (hw.isShiftPressed) 'shift',
      if (hw.isAltPressed) 'alt',
      if (hw.isMetaPressed) 'meta',
    ];
    if (mods.isEmpty || mods.every((m) => m == 'shift')) return true;
    final label = key.keyLabel.toLowerCase();
    final name = _named[key] ??
        ((label.length == 1 && RegExp(r'[a-z0-9]').hasMatch(label))
            ? label
            : null);
    if (name == null) return true;
    widget.channel.setOpenShortcut({'key': name, 'modifiers': mods});
    _focus.unfocus();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Focus(
      focusNode: _focus,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: GestureDetector(
          onTap: _start,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: recording
                  ? p.control
                  : hovered
                      ? p.hover
                      : p.chipFill,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: recording ? p.accent.withValues(alpha: 0.7) : p.divider,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 120, minHeight: 18),
                child: recording
                    ? Text(
                        'Press shortcut',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: p.secondary),
                      )
                    : Center(
                        child: _ShortcutKeys(widget.keys, palette: p),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GeneralPane extends StatelessWidget {
  const GeneralPane({
    super.key,
    required this.controller,
    required this.palette,
  });
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    final prefs = controller.snapshot.prefs;
    return _PaneScaffold(
      children: [
        _Section(
          title: 'Startup',
          palette: palette,
          children: [
            _PrefRow(
              label: 'Launch at login',
              palette: palette,
              child: NativeToggle(
                value: prefs.launchAtLogin,
                onChanged: (v) =>
                    controller.channel.prefsSet({'launchAtLogin': v}),
              ),
            ),
          ],
        ),
        _Section(
          title: 'Window',
          palette: palette,
          children: [
            _PrefRow(
              label: 'Open at',
              palette: palette,
              child: _MenuValue(
                value:
                    {
                      'cursor': 'At cursor',
                      'menuBar': _menuBarLabel,
                      'center': 'Screen center',
                      'lastPosition': 'Last position',
                    }[prefs.popupPosition] ??
                    prefs.popupPosition,
                onTap: () async {
                  final picked = await controller.channel.showChoices(
                    [
                      'At cursor',
                      _menuBarLabel,
                      'Screen center',
                      'Last position',
                    ],
                    current: {
                      'cursor': 'At cursor',
                      'menuBar': _menuBarLabel,
                      'center': 'Screen center',
                      'lastPosition': 'Last position',
                    }[prefs.popupPosition],
                  );
                  final map = {
                    'At cursor': 'cursor',
                    _menuBarLabel: 'menuBar',
                    'Screen center': 'center',
                    'Last position': 'lastPosition',
                  };
                  if (picked != null) {
                    await controller.channel.prefsSet({
                      'popupPosition': map[picked],
                    });
                  }
                },
                palette: palette,
              ),
            ),
            if (_isWin)
              _PrefRow(
                label: 'Backdrop',
                caption: controller.snapshot.micaSupported
                    ? null
                    : 'Windows 10 supports Acrylic only',
                palette: palette,
                child: _MenuValue(
                  enabled: controller.snapshot.micaSupported,
                  value: controller.snapshot.micaSupported
                      ? ({
                            'mica': 'Mica',
                            'acrylic': 'Acrylic',
                          }[prefs.windowBackdrop] ??
                          prefs.windowBackdrop)
                      : 'Acrylic',
                  onTap: () async {
                    final picked = await controller.channel.showChoices(
                      ['Mica', 'Acrylic'],
                      current: {
                        'mica': 'Mica',
                        'acrylic': 'Acrylic',
                      }[prefs.windowBackdrop],
                    );
                    const map = {'Mica': 'mica', 'Acrylic': 'acrylic'};
                    if (picked != null) {
                      await controller.channel.prefsSet({
                        'windowBackdrop': map[picked],
                      });
                    }
                  },
                  palette: palette,
                ),
              ),
          ],
        ),
        _Section(
          title: 'Shortcuts',
          palette: palette,
          children: [
            _PrefRow(
              label: 'Open Clipword',
              caption: 'Click the field and press a new shortcut',
              palette: palette,
              child: _ShortcutRecorderField(
                keys: controller.snapshot.openShortcut,
                palette: palette,
                channel: controller.channel,
              ),
            ),
            _PrefRow(
              label: 'Search clips and bookmarks',
              palette: palette,
              child: _ShortcutKeys(['Type'], palette: palette),
            ),
            _PrefRow(
              label: 'Move through the list',
              palette: palette,
              child: _ShortcutKeys(['↑', '↓'], palette: palette),
            ),
            _PrefRow(
              label: prefs.pasteAutomatically
                  ? 'Paste selected item'
                  : 'Copy selected item',
              palette: palette,
              child: _ShortcutKeys(['↩'], palette: palette),
            ),
            _PrefRow(
              label: prefs.pasteAutomatically
                  ? 'Copy selected item'
                  : 'Paste selected item',
              palette: palette,
              child: _ShortcutKeys([_modKey, '↩'], palette: palette),
            ),
            _PrefRow(
              label: 'Toggle bookmarks / recent',
              palette: palette,
              child: _ShortcutKeys([_modKey, 'B'], palette: palette),
            ),
            _PrefRow(
              label: 'Item actions menu',
              palette: palette,
              child: _ShortcutKeys([_modKey, 'K'], palette: palette),
            ),
            _PrefRow(
              label: 'Copy selected item',
              palette: palette,
              child: _ShortcutKeys([_modKey, 'C'], palette: palette),
            ),
            _PrefRow(
              label: 'Edit selected item',
              palette: palette,
              child: _ShortcutKeys([_modKey, 'E'], palette: palette),
            ),
            _PrefRow(
              label: 'Add to paste stack',
              palette: palette,
              child: _ShortcutKeys([_shiftKey, _modKey, 'V'], palette: palette),
            ),
            _PrefRow(
              label: 'Bookmark selected item',
              palette: palette,
              child: _ShortcutKeys([_altKey, 'B'], palette: palette),
            ),
            _PrefRow(
              label: 'Pin selected item',
              palette: palette,
              child: _ShortcutKeys([_altKey, 'P'], palette: palette),
            ),
            _PrefRow(
              label: 'Delete selected item',
              palette: palette,
              child: _ShortcutKeys([_modKey, '⌫'], palette: palette),
            ),
          ],
        ),
        _Section(
          title: 'Search',
          palette: palette,
          children: [
            _PrefRow(
              label: 'Search mode',
              palette: palette,
              child: _MenuValue(
                value:
                    prefs.searchMode[0].toUpperCase() +
                    prefs.searchMode.substring(1),
                onTap: () async {
                  final picked = await controller.channel.showChoices(
                    ['Exact', 'Fuzzy', 'Regex', 'Mixed'],
                    current:
                        prefs.searchMode[0].toUpperCase() +
                        prefs.searchMode.substring(1),
                  );
                  if (picked != null) {
                    await controller.channel.prefsSet({
                      'searchMode': picked.toLowerCase(),
                    });
                  }
                },
                palette: palette,
              ),
            ),
          ],
        ),
        _Section(
          title: 'Paste',
          palette: palette,
          children: [
            _PrefRow(
              label: 'Return key',
              caption: '$_modKey+Return does the other action',
              palette: palette,
              child: _MenuValue(
                value: prefs.pasteAutomatically ? 'Paste' : 'Copy to clipboard',
                onTap: () async {
                  final picked = await controller.channel.showChoices(
                    ['Paste', 'Copy to clipboard'],
                    current: prefs.pasteAutomatically
                        ? 'Paste'
                        : 'Copy to clipboard',
                  );
                  if (picked != null) {
                    await controller.channel.prefsSet({
                      'pasteAutomatically': picked == 'Paste',
                    });
                  }
                },
                palette: palette,
              ),
            ),
            _PrefRow(
              label: 'Paste without formatting by default',
              palette: palette,
              child: NativeToggle(
                value: prefs.pasteWithoutFormatting,
                onChanged: (v) =>
                    controller.channel.prefsSet({'pasteWithoutFormatting': v}),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class StoragePane extends StatelessWidget {
  const StoragePane({
    super.key,
    required this.controller,
    required this.palette,
  });
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    final prefs = controller.snapshot.prefs;
    return _PaneScaffold(
      children: [
        _Section(
          title: 'Content types',
          palette: palette,
          children: [
            _PrefRow(
              label: 'Save text',
              palette: palette,
              child: NativeToggle(
                value: prefs.saveText,
                onChanged: (v) => controller.channel.prefsSet({'saveText': v}),
              ),
            ),
            _PrefRow(
              label: 'Save images',
              palette: palette,
              child: NativeToggle(
                value: prefs.saveImages,
                onChanged: (v) =>
                    controller.channel.prefsSet({'saveImages': v}),
              ),
            ),
            _PrefRow(
              label: 'Save files',
              palette: palette,
              child: NativeToggle(
                value: prefs.saveFiles,
                onChanged: (v) => controller.channel.prefsSet({'saveFiles': v}),
              ),
            ),
          ],
        ),
        _Section(
          title: 'Link previews',
          palette: palette,
          children: [
            _PrefRow(
              label: 'Load link previews',
              palette: palette,
              child: NativeToggle(
                value: prefs.loadLinkPreviews,
                onChanged: (v) =>
                    controller.channel.prefsSet({'loadLinkPreviews': v}),
              ),
            ),
            _PrefRow(
              label: 'Preview cache',
              palette: palette,
              child: Text(
                controller.snapshot.previewCacheSize,
                style: TextStyle(fontSize: 13, color: palette.secondary),
              ),
            ),
            _PrefRow(
              label: 'Clear preview cache',
              palette: palette,
              child: _PushButton(
                label: 'Clear',
                onTap: controller.channel.clearPreviewCache,
                palette: palette,
              ),
            ),
          ],
        ),
        _Section(
          title: 'History',
          palette: palette,
          children: [
            _PrefRow(
              label: 'History size',
              palette: palette,
              child: _MenuValue(
                value: prefs.historySize <= 0
                    ? 'Unlimited'
                    : '${prefs.historySize}',
                onTap: () async {
                  final picked = await controller.channel.showChoices(
                    ['Unlimited', '100', '200', '500', '1000'],
                    current: prefs.historySize <= 0
                        ? 'Unlimited'
                        : '${prefs.historySize}',
                  );
                  if (picked == null) return;
                  await controller.channel.prefsSet({
                    'historySize': picked == 'Unlimited'
                        ? 0
                        : int.parse(picked),
                  });
                },
                palette: palette,
              ),
            ),
            _PrefRow(
              label: 'Keep history for',
              palette: palette,
              child: _MenuValue(
                value:
                    {
                      'day': 'A Day',
                      'week': 'A Week',
                      'month': 'A Month',
                      'threeMonths': '3 Months',
                      'sixMonths': '6 Months',
                      'year': 'A Year',
                      'unlimited': 'Unlimited',
                    }[prefs.historyRetention] ??
                    prefs.historyRetention,
                onTap: () async {
                  const labels = [
                    'A Day',
                    'A Week',
                    'A Month',
                    '3 Months',
                    '6 Months',
                    'A Year',
                    'Unlimited',
                  ];
                  const map = {
                    'A Day': 'day',
                    'A Week': 'week',
                    'A Month': 'month',
                    '3 Months': 'threeMonths',
                    '6 Months': 'sixMonths',
                    'A Year': 'year',
                    'Unlimited': 'unlimited',
                  };
                  final picked = await controller.channel.showChoices(labels);
                  if (picked != null) {
                    await controller.channel.prefsSet({
                      'historyRetention': map[picked],
                    });
                  }
                },
                palette: palette,
              ),
            ),
            _PrefRow(
              label: 'Sort by',
              palette: palette,
              child: _MenuValue(
                value:
                    {
                      'lastCopied': 'Last copied',
                      'firstCopied': 'First copied',
                      'copyCount': 'Copy count',
                    }[prefs.sortOrder] ??
                    prefs.sortOrder,
                onTap: () async {
                  const labels = ['Last copied', 'First copied', 'Copy count'];
                  const map = {
                    'Last copied': 'lastCopied',
                    'First copied': 'firstCopied',
                    'Copy count': 'copyCount',
                  };
                  final picked = await controller.channel.showChoices(labels);
                  if (picked != null) {
                    await controller.channel.prefsSet({
                      'sortOrder': map[picked],
                    });
                  }
                },
                palette: palette,
              ),
            ),
            _PrefRow(
              label: 'Database size',
              palette: palette,
              child: Text(
                controller.snapshot.databaseSize,
                style: TextStyle(fontSize: 13, color: palette.secondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class IgnorePane extends StatefulWidget {
  const IgnorePane({
    super.key,
    required this.controller,
    required this.palette,
  });
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  State<IgnorePane> createState() => _IgnorePaneState();
}

class _IgnorePaneState extends State<IgnorePane> {
  int tab = 0;
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _emptyCopy {
    switch (tab) {
      case 0:
        return 'No ignored apps';
      case 1:
        return 'No ignored pasteboard types';
      default:
        return 'No ignored regex patterns';
    }
  }

  void _addItem(ClipPrefs prefs) {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    if (tab == 0) {
      widget.controller.channel.prefsSet({
        'ignoredApps': [...prefs.ignoredApps, value],
      });
    } else if (tab == 1) {
      widget.controller.channel.prefsSet({
        'ignoredPasteboardTypes': [...prefs.ignoredPasteboardTypes, value],
      });
    } else {
      widget.controller.channel.prefsSet({
        'ignoredRegexPatterns': [...prefs.ignoredRegexPatterns, value],
      });
    }
    _text.clear();
  }

  void _removeItem(ClipPrefs prefs, String item) {
    if (tab == 0) {
      widget.controller.channel.prefsSet({
        'ignoredApps': prefs.ignoredApps.where((e) => e != item).toList(),
      });
    } else if (tab == 1) {
      widget.controller.channel.prefsSet({
        'ignoredPasteboardTypes': prefs.ignoredPasteboardTypes
            .where((e) => e != item)
            .toList(),
      });
    } else {
      widget.controller.channel.prefsSet({
        'ignoredRegexPatterns': prefs.ignoredRegexPatterns
            .where((e) => e != item)
            .toList(),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = widget.controller.snapshot.prefs;
    final palette = widget.palette;
    final items = tab == 0
        ? prefs.ignoredApps
        : tab == 1
        ? prefs.ignoredPasteboardTypes
        : prefs.ignoredRegexPatterns;
    return _PaneScaffold(
      children: [
        _Section(
          palette: palette,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: _SegmentedControl(
                labels: const ['Apps', 'Types', 'Regex'],
                index: tab,
                onChanged: (i) => setState(() => tab = i),
                palette: palette,
              ),
            ),
          ],
        ),
        if (tab == 0)
          _Section(
            palette: palette,
            children: [
              _PrefRow(
                label: 'Allow listed apps only',
                palette: palette,
                child: NativeToggle(
                  value: prefs.allowedAppsOnly,
                  onChanged: (v) => widget.controller.channel.prefsSet({
                    'allowedAppsOnly': v,
                  }),
                ),
              ),
            ],
          ),
        _Section(
          palette: palette,
          children: [
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Text(
                  _emptyCopy,
                  style: TextStyle(fontSize: 13, color: palette.secondary),
                ),
              )
            else
              for (final item in items)
                _PrefRow(
                  label: item,
                  palette: palette,
                  child: _PushButton(
                    label: 'Remove',
                    destructive: true,
                    palette: palette,
                    onTap: () => _removeItem(prefs, item),
                  ),
                ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: palette.chipFill,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: EditableText(
                          controller: _text,
                          focusNode: _focus,
                          style: TextStyle(color: palette.label, fontSize: 13),
                          cursorColor: palette.accent,
                          backgroundCursorColor: palette.secondary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _PushButton(
                    label: 'Add',
                    palette: palette,
                    onTap: () => _addItem(prefs),
                  ),
                  if (tab == 0) ...[
                    const SizedBox(width: 8),
                    _PushButton(
                      label: 'Choose App…',
                      palette: palette,
                      onTap: widget.controller.channel.pickIgnoredApps,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SegmentedControl extends StatelessWidget {
  const _SegmentedControl({
    required this.labels,
    required this.index,
    required this.onChanged,
    required this.palette,
  });
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.chipFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          children: [
            for (final (i, label) in labels.indexed)
              Expanded(
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => onChanged(i),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: index == i
                            ? (palette.dark
                                  ? const Color(0xFF636366)
                                  : const Color(0xFFFFFFFF))
                            : const Color(0x00000000),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Center(
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: index == i
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: palette.label,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AdvancedPane extends StatelessWidget {
  const AdvancedPane({
    super.key,
    required this.controller,
    required this.palette,
  });
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    final prefs = controller.snapshot.prefs;
    return _PaneScaffold(
      children: [
        _Section(
          title: 'Clipboard',
          palette: palette,
          children: [
            _PrefRow(
              label: 'Clear history on quit',
              palette: palette,
              child: NativeToggle(
                value: prefs.clearOnQuit,
                onChanged: (v) =>
                    controller.channel.prefsSet({'clearOnQuit': v}),
              ),
            ),
            _PrefRow(
              label: 'Clear system clipboard after copy',
              palette: palette,
              child: NativeToggle(
                value: prefs.clearSystemClipboard,
                onChanged: (v) =>
                    controller.channel.prefsSet({'clearSystemClipboard': v}),
              ),
            ),
          ],
        ),
        _Section(
          title: 'Device Access',
          palette: palette,
          children: [
            _PrefRow(
              label: 'Permission',
              caption: _isWin
                  ? 'Auto-paste works on Windows without extra permissions.'
                  : 'macOS lists this as Device Control and Data Access.',
              palette: palette,
              child: controller.snapshot.accessibility
                  ? Row(
                      children: [
                        SymbolIcon(
                          'checkmark.circle.fill',
                          size: 14,
                          color: palette.success,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Granted',
                          style: TextStyle(fontSize: 13, color: palette.label),
                        ),
                      ],
                    )
                  : _PushButton(
                      label: 'Request Permission',
                      onTap: controller.channel.requestAccessibility,
                      palette: palette,
                    ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MenuValue extends StatefulWidget {
  const _MenuValue({
    required this.value,
    required this.onTap,
    required this.palette,
    this.enabled = true,
  });
  final String value;
  final VoidCallback onTap;
  final ClipPalette palette;
  final bool enabled;

  @override
  State<_MenuValue> createState() => _MenuValueState();
}

class _MenuValueState extends State<_MenuValue> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        if (widget.enabled) setState(() => hovered = true);
      },
      onExit: (_) => setState(() => hovered = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: hovered
                ? widget.palette.control
                : widget.palette.chipFill,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.value,
                  style: TextStyle(
                    fontSize: 13,
                    color: widget.enabled
                        ? widget.palette.controlLabel
                        : widget.palette.secondary,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.unfold_more,
                  size: 14,
                  color: widget.palette.secondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
