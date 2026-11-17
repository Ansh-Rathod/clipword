import 'package:flutter/widgets.dart';

import '../app/controller.dart';
import '../native/models.dart';
import '../palette/widgets.dart';
import '../theme/tokens.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller, required this.palette});
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    final snap = controller.snapshot;
    const sections = [
      ('general', 'General', 'gear'),
      ('storage', 'Storage', 'internaldrive'),
      ('ignore', 'Ignore', 'eye.slash'),
      ('advanced', 'Advanced', 'wrench.and.screwdriver'),
    ];
    return ColoredBox(
      color: palette.window,
      child: Row(
        children: [
          SizedBox(
            width: ClipTokens.settingsSidebar,
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text('Settings', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: palette.secondary)),
                  ),
                  for (final section in sections)
                    _sidebarRow(section.$1, section.$2, section.$3, snap.settingsSection == section.$1),
                ],
              ),
            ),
          ),
          ColoredBox(color: palette.divider, child: const SizedBox(width: 1, height: double.infinity)),
          Expanded(child: _pane(snap)),
        ],
      ),
    );
  }

  Widget _sidebarRow(String id, String title, String icon, bool selected) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => controller.channel.setSettingsSection(id),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? ClipTokens.accent.withValues(alpha: 0.18) : const Color(0x00000000),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                SymbolIcon(icon, size: 14, color: selected ? ClipTokens.accent : palette.label),
                const SizedBox(width: 8),
                Text(title, style: TextStyle(color: palette.label)),
              ],
            ),
          ),
        ),
      ),
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

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, required this.palette});
  final String title;
  final List<Widget> children;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: palette.secondary)),
          const SizedBox(height: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              color: palette.label.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: children),
            ),
          ),
        ],
      ),
    );
  }
}

class _PrefRow extends StatelessWidget {
  const _PrefRow({required this.label, required this.child, this.caption, required this.palette});
  final String label;
  final Widget child;
  final String? caption;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: palette.label)),
                if (caption != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(caption!, style: TextStyle(fontSize: 11, color: palette.secondary)),
                  ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class GeneralPane extends StatelessWidget {
  const GeneralPane({super.key, required this.controller, required this.palette});
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    final prefs = controller.snapshot.prefs;
    return ListView(
      padding: const EdgeInsets.all(24),
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
                onChanged: (v) => controller.channel.prefsSet({'launchAtLogin': v}),
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
                value: {
                  'cursor': 'At cursor',
                  'menuBar': 'At menu bar',
                  'center': 'Screen center',
                  'lastPosition': 'Last position',
                }[prefs.popupPosition] ??
                    prefs.popupPosition,
                onTap: () async {
                  final picked = await controller.channel.showChoices(
                    ['At cursor', 'At menu bar', 'Screen center', 'Last position'],
                    current: {
                      'cursor': 'At cursor',
                      'menuBar': 'At menu bar',
                      'center': 'Screen center',
                      'lastPosition': 'Last position',
                    }[prefs.popupPosition],
                  );
                  const map = {
                    'At cursor': 'cursor',
                    'At menu bar': 'menuBar',
                    'Screen center': 'center',
                    'Last position': 'lastPosition',
                  };
                  if (picked != null) {
                    await controller.channel.prefsSet({'popupPosition': map[picked]});
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
            _PrefRow(label: 'Open Clipword', palette: palette, child: Text('⇧⌘C', style: TextStyle(color: palette.secondary, fontFamily: 'Menlo'))),
            _PrefRow(label: 'Search clips and bookmarks', palette: palette, child: Text('Type', style: TextStyle(color: palette.secondary, fontFamily: 'Menlo'))),
            _PrefRow(label: 'Move through the list', palette: palette, child: Text('↑ ↓', style: TextStyle(color: palette.secondary, fontFamily: 'Menlo'))),
            _PrefRow(label: 'Expand folder, or paste', palette: palette, child: Text('Return', style: TextStyle(color: palette.secondary, fontFamily: 'Menlo'))),
            _PrefRow(label: 'Toggle bookmarks / recent', palette: palette, child: Text('⌘B', style: TextStyle(color: palette.secondary, fontFamily: 'Menlo'))),
            _PrefRow(label: 'Item actions menu', palette: palette, child: Text('⌘K', style: TextStyle(color: palette.secondary, fontFamily: 'Menlo'))),
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
                value: prefs.searchMode[0].toUpperCase() + prefs.searchMode.substring(1),
                onTap: () async {
                  final picked = await controller.channel.showChoices(
                    ['Exact', 'Fuzzy', 'Regex', 'Mixed'],
                    current: prefs.searchMode[0].toUpperCase() + prefs.searchMode.substring(1),
                  );
                  if (picked != null) {
                    await controller.channel.prefsSet({'searchMode': picked.toLowerCase()});
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
              label: 'Paste automatically',
              palette: palette,
              child: NativeToggle(
                value: prefs.pasteAutomatically,
                onChanged: (v) => controller.channel.prefsSet({'pasteAutomatically': v}),
              ),
            ),
            _PrefRow(
              label: 'Paste without formatting by default',
              palette: palette,
              child: NativeToggle(
                value: prefs.pasteWithoutFormatting,
                onChanged: (v) => controller.channel.prefsSet({'pasteWithoutFormatting': v}),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class StoragePane extends StatelessWidget {
  const StoragePane({super.key, required this.controller, required this.palette});
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    final prefs = controller.snapshot.prefs;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _Section(
          title: 'Content types',
          palette: palette,
          children: [
            _PrefRow(label: 'Save text', palette: palette, child: NativeToggle(value: prefs.saveText, onChanged: (v) => controller.channel.prefsSet({'saveText': v}))),
            _PrefRow(label: 'Save images', palette: palette, child: NativeToggle(value: prefs.saveImages, onChanged: (v) => controller.channel.prefsSet({'saveImages': v}))),
            _PrefRow(label: 'Save files', palette: palette, child: NativeToggle(value: prefs.saveFiles, onChanged: (v) => controller.channel.prefsSet({'saveFiles': v}))),
          ],
        ),
        _Section(
          title: 'Link previews',
          palette: palette,
          children: [
            _PrefRow(label: 'Load link previews', palette: palette, child: NativeToggle(value: prefs.loadLinkPreviews, onChanged: (v) => controller.channel.prefsSet({'loadLinkPreviews': v}))),
            _PrefRow(label: 'Preview cache', palette: palette, child: Text(controller.snapshot.previewCacheSize, style: TextStyle(color: palette.secondary))),
            _PrefRow(
              label: 'Clear Preview Cache',
              palette: palette,
              child: GestureDetector(
                onTap: () => controller.channel.clearPreviewCache(),
                child: const Text('Clear', style: TextStyle(color: ClipTokens.accent)),
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
                value: prefs.historySize <= 0 ? 'Unlimited' : '${prefs.historySize}',
                onTap: () async {
                  final picked = await controller.channel.showChoices(
                    ['Unlimited', '100', '200', '500', '1000'],
                    current: prefs.historySize <= 0 ? 'Unlimited' : '${prefs.historySize}',
                  );
                  if (picked == null) return;
                  await controller.channel.prefsSet({
                    'historySize': picked == 'Unlimited' ? 0 : int.parse(picked),
                  });
                },
                palette: palette,
              ),
            ),
            _PrefRow(
              label: 'Keep history for',
              palette: palette,
              child: _MenuValue(
                value: {
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
                  const labels = ['A Day', 'A Week', 'A Month', '3 Months', '6 Months', 'A Year', 'Unlimited'];
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
                    await controller.channel.prefsSet({'historyRetention': map[picked]});
                  }
                },
                palette: palette,
              ),
            ),
            _PrefRow(
              label: 'Sort by',
              palette: palette,
              child: _MenuValue(
                value: {
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
                    await controller.channel.prefsSet({'sortOrder': map[picked]});
                  }
                },
                palette: palette,
              ),
            ),
            _PrefRow(label: 'Database size', palette: palette, child: Text(controller.snapshot.databaseSize, style: TextStyle(color: palette.secondary))),
          ],
        ),
      ],
    );
  }
}

class IgnorePane extends StatefulWidget {
  const IgnorePane({super.key, required this.controller, required this.palette});
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

  @override
  Widget build(BuildContext context) {
    final prefs = widget.controller.snapshot.prefs;
    final palette = widget.palette;
    final items = tab == 0
        ? prefs.ignoredApps
        : tab == 1
            ? prefs.ignoredPasteboardTypes
            : prefs.ignoredRegexPatterns;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              for (final entry in [(0, 'Apps'), (1, 'Types'), (2, 'Regex')])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => tab = entry.$1),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: tab == entry.$1 ? ClipTokens.accent.withValues(alpha: 0.16) : palette.chipFill,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Text(entry.$2, style: TextStyle(color: palette.label)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (tab == 0)
            _PrefRow(
              label: 'Allow listed apps only',
              palette: palette,
              child: NativeToggle(
                value: prefs.allowedAppsOnly,
                onChanged: (v) => widget.controller.channel.prefsSet({'allowedAppsOnly': v}),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: EditableText(
                  controller: _text,
                  focusNode: _focus,
                  style: TextStyle(color: palette.label, fontSize: 14),
                  cursorColor: ClipTokens.accent,
                  backgroundCursorColor: palette.secondary,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () {
                  final value = _text.text.trim();
                  if (value.isEmpty) return;
                  if (tab == 0) {
                    widget.controller.channel.prefsSet({'ignoredApps': [...prefs.ignoredApps, value]});
                  } else if (tab == 1) {
                    widget.controller.channel.prefsSet({'ignoredPasteboardTypes': [...prefs.ignoredPasteboardTypes, value]});
                  } else {
                    widget.controller.channel.prefsSet({'ignoredRegexPatterns': [...prefs.ignoredRegexPatterns, value]});
                  }
                  _text.clear();
                },
                child: const Text('Add', style: TextStyle(color: ClipTokens.accent)),
              ),
              if (tab == 0) ...[
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: widget.controller.channel.pickIgnoredApps,
                  child: Row(
                    children: [
                      SymbolIcon('folder', size: 13, color: ClipTokens.accent),
                      const SizedBox(width: 4),
                      const Text('Choose App…', style: TextStyle(color: ClipTokens.accent)),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(child: Text(item, style: TextStyle(color: palette.label))),
                        GestureDetector(
                          onTap: () {
                            if (tab == 0) {
                              widget.controller.channel.prefsSet({
                                'ignoredApps': prefs.ignoredApps.where((e) => e != item).toList(),
                              });
                            } else if (tab == 1) {
                              widget.controller.channel.prefsSet({
                                'ignoredPasteboardTypes': prefs.ignoredPasteboardTypes.where((e) => e != item).toList(),
                              });
                            } else {
                              widget.controller.channel.prefsSet({
                                'ignoredRegexPatterns': prefs.ignoredRegexPatterns.where((e) => e != item).toList(),
                              });
                            }
                          },
                          child: const Text('Remove', style: TextStyle(color: Color(0xFFFF453A))),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AdvancedPane extends StatelessWidget {
  const AdvancedPane({super.key, required this.controller, required this.palette});
  final ClipwordController controller;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    final prefs = controller.snapshot.prefs;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        _Section(
          title: 'Clipboard',
          palette: palette,
          children: [
            _PrefRow(label: 'Clear history on quit', palette: palette, child: NativeToggle(value: prefs.clearOnQuit, onChanged: (v) => controller.channel.prefsSet({'clearOnQuit': v}))),
            _PrefRow(label: 'Clear system clipboard after copy', palette: palette, child: NativeToggle(value: prefs.clearSystemClipboard, onChanged: (v) => controller.channel.prefsSet({'clearSystemClipboard': v}))),
          ],
        ),
        _Section(
          title: 'Device Access',
          palette: palette,
          children: [
            _PrefRow(
              label: 'Permission',
              caption: 'macOS lists this as Device Control and Data Access.',
              palette: palette,
              child: controller.snapshot.accessibility
                  ? Row(
                      children: [
                        SymbolIcon('checkmark.circle.fill', size: 14, color: ClipTokens.success),
                        const SizedBox(width: 6),
                        Text('Granted', style: TextStyle(color: palette.label)),
                      ],
                    )
                  : GestureDetector(
                      onTap: controller.channel.requestAccessibility,
                      child: const Text('Request Permission', style: TextStyle(color: ClipTokens.accent)),
                    ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MenuValue extends StatelessWidget {
  const _MenuValue({required this.value, required this.onTap, required this.palette});
  final String value;
  final VoidCallback onTap;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          children: [
            Text(value, style: TextStyle(color: palette.label)),
            const SizedBox(width: 6),
            SymbolIcon('chevron.up.chevron.down', size: 10, color: palette.secondary),
          ],
        ),
      ),
    );
  }
}
