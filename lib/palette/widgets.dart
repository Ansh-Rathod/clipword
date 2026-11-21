import 'dart:typed_data';

import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter/widgets.dart';

import '../native/channel.dart';
import '../theme/tokens.dart';

final _symbolCache = <String, Uint8List>{};

class SymbolIcon extends StatefulWidget {
  const SymbolIcon(this.name, {super.key, this.size = 16, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  State<SymbolIcon> createState() => _SymbolIconState();
}

class _SymbolIconState extends State<SymbolIcon> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SymbolIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name || oldWidget.size != widget.size) {
      _load();
    }
  }

  Future<void> _load() async {
    final key = '${widget.name}-${widget.size}';
    if (_symbolCache[key] != null) {
      setState(() => _bytes = _symbolCache[key]);
      return;
    }
    final bytes = await ClipwordChannel.instance.symbolImage(widget.name, size: widget.size * 2);
    if (bytes == null || !mounted) return;
    _symbolCache[key] = bytes;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes == null) {
      return SizedBox(width: widget.size, height: widget.size);
    }
    return ColorFiltered(
      colorFilter: ColorFilter.mode(widget.color ?? const Color(0xFF000000), BlendMode.srcIn),
      child: Image.memory(
        _bytes!,
        width: widget.size,
        height: widget.size,
        gaplessPlayback: true,
      ),
    );
  }
}

class AppGlyph extends StatefulWidget {
  const AppGlyph(this.bundleId, {super.key, this.size = 14});
  final String? bundleId;
  final double size;

  @override
  State<AppGlyph> createState() => _AppGlyphState();
}

class _AppGlyphState extends State<AppGlyph> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AppGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bundleId != widget.bundleId) _load();
  }

  Future<void> _load() async {
    final bytes = await ClipwordChannel.instance.appIcon(widget.bundleId, size: widget.size * 2);
    if (!mounted) return;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes == null) {
      return SymbolIcon('app', size: widget.size);
    }
    return Image.memory(_bytes!, width: widget.size, height: widget.size);
  }
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    this.icon,
    this.iconData,
    required this.onTap,
    required this.palette,
  });

  final String? icon;
  final IconData? iconData;
  final VoidCallback onTap;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.chipFill,
            borderRadius: BorderRadius.circular(ClipTokens.iconRadius),
          ),
          child: SizedBox(
            width: ClipTokens.iconButtonSize,
            height: ClipTokens.iconButtonSize,
            child: Center(
              child: iconData != null
                  ? Icon(iconData, size: ClipTokens.iconFont, color: palette.label)
                  : SymbolIcon(icon!, size: ClipTokens.iconFont, color: palette.label),
            ),
          ),
        ),
      ),
    );
  }
}

class FilterChipButton extends StatelessWidget {
  const FilterChipButton({
    super.key,
    required this.icon,
    required this.title,
    required this.emphasized,
    required this.palette,
    required this.onTap,
  });

  final String icon;
  final String title;
  final bool emphasized;
  final ClipPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = emphasized ? palette.accent : palette.label;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: emphasized
                ? palette.accent.withValues(alpha: 0.16)
                : palette.chipFill,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ClipTokens.pillPaddingH,
              vertical: ClipTokens.pillPaddingV,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SymbolIcon(icon, size: 13, color: color),
                const SizedBox(width: 4),
                Text(
                  title,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: color),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 14,
                  color: emphasized
                      ? palette.accent.withValues(alpha: 0.8)
                      : palette.secondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class Keycap extends StatelessWidget {
  const Keycap({super.key, this.text, this.icon, this.iconData, required this.palette});
  final String? text;
  final String? icon;
  final IconData? iconData;
  final ClipPalette palette;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.label.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ClipTokens.keycapRadius),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: ClipTokens.keycapMin, minHeight: ClipTokens.keycapMin),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Center(
            child: iconData != null
                ? Icon(iconData, size: 12, color: palette.secondary)
                : icon != null
                    ? SymbolIcon(icon!, size: 11, color: palette.secondary)
                    : Text(
                        text ?? '',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: palette.secondary,
                        ),
                      ),
          ),
        ),
      ),
    );
  }
}

class FooterPill extends StatelessWidget {
  const FooterPill({super.key, required this.child, required this.palette, required this.onTap});
  final Widget child;
  final ClipPalette palette;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: palette.chipFill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ClipTokens.pillPaddingH,
          vertical: ClipTokens.pillPaddingV,
        ),
        child: DefaultTextStyle(
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: palette.label.withValues(alpha: 0.9)),
          child: child,
        ),
      ),
    );
    if (onTap == null) return content;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: content),
    );
  }
}

class NativeToggle extends StatelessWidget {
  const NativeToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  static const _width = 40.0;
  static const _height = 24.0;
  static const _inset = 2.0;

  @override
  Widget build(BuildContext context) {
    final palette = ClipPalette(
      dark: MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    );
    final thumb = _height - _inset * 2;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        behavior: HitTestBehavior.opaque,
        child: Semantics(
          toggled: value,
          button: true,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            width: _width,
            height: _height,
            padding: const EdgeInsets.all(_inset),
            decoration: BoxDecoration(
              color: value ? palette.accent : palette.toggleOff,
              borderRadius: BorderRadius.circular(_height / 2),
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFFFF),
                  borderRadius: BorderRadius.circular(thumb / 2),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x3D000000),
                      blurRadius: 1.5,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
                child: SizedBox(width: thumb, height: thumb),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
