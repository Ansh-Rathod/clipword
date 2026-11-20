import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// SF Symbol → Windows glyph fallback + offscreen renderer (port of
/// `symbolImage`/`appIcon` channel methods).
class WinIcons {
  WinIcons._();

  /// SF Symbol name → Segoe Fluent Icons (primary) / Segoe MDL2 Assets
  /// (fallback) codepoint.
  static const _glyphs = <String, int>{
    'doc.text': 0xE8A5, // Page
    'link': 0xE71B, // Link
    'chevron.left.forwardslash.chevron.right': 0xE943, // Code
    'doc.richtext': 0xE8D2, // TextEdit (mdl2)
    'photo': 0xEB9F, // Picture (mdl2)
    'doc': 0xE8A5,
    'paintpalette': 0xE2B1, // Color (fluent)
    'folder.fill': 0xE8B7, // Folder
    'folder': 0xE8B7,
    'bookmark.fill': 0xE8A4, // Bookmark
    'bookmark': 0xE8A4,
    'pin.fill': 0xE718, // Pin
    'pin': 0xE718,
    'app.badge': 0xECAA, // AllApps
    'app': 0xECAA,
    'checkmark.circle.fill': 0xF13E, // CompletedSolid (fluent)
    'doc.on.clipboard': 0xF0E3, // Paste (mdl2)
    'text.insert': 0xF167, // InsertTextBox
    'doc.on.doc': 0xE8C8, // Copy
    'gear': 0xE713, // Setting
    'internaldrive': 0xEDA2, // HardDrive (mdl2)
    'eye.slash': 0xF7AA, // Hide (mdl2)
    'wrench.and.screwdriver': 0xE90F, // Repair (mdl2)
    'magnifyingglass': 0xE721, // Search
    'keyboard': 0xE765, // KeyboardClassic (mdl2)
    'hand.raised': 0xE943,
    'clock': 0xE917, // History (mdl2)
    'trash': 0xE74D, // Delete
    'square.and.pencil': 0xE70F, // Edit
    'plus': 0xE710, // Add
    'minus': 0xE738, // Remove
    'chevron.right': 0xE76C, // ChevronRight (mdl2)
    'chevron.down': 0xE70D, // ChevronDown
    'xmark': 0xE711, // ChromeClose / Cancel
    'checkmark': 0xE73E, // CheckMark
    'arrow.triangle.2.circlepath': 0xE895, // Sync
    'rectangle.on.rectangle': 0xE8C8,
    'paperclip': 0xE723, // Attach
    'photo.on.rectangle': 0xEB9F,
    'square.and.arrow.up': 0xE72D, // Share
    'network': 0xE968, // InternetSharing-ish (mdl2)
    'safari': 0xE774, // Globe (mdl2)
    'globe': 0xE774,
    'envelope': 0xE715, // Mail
    'person.crop.circle': 0xE77B, // Contact
    'star': 0xE734, // FavoriteStar
    'star.fill': 0xE735, // FavoriteStarFill
    'scissors': 0xE8C6, // Cut
    'paintbrush': 0xE2B1,
    'textformat': 0xE8D2,
    'character.textbox': 0xE8D2,
    'number': 0xE9F9,
    'calendar': 0xE787, // Calendar
    'tag': 0xE8EC, // Tag
    'gearshape': 0xE713, // Setting
    'line.3.horizontal.decrease': 0xE71C, // Filter (mdl2)
    'line.3.horizontal.decrease.circle': 0xE71C,
    'line.horizontal.3': 0xE76E, // GlobalNavButton (mdl2)
  };

  /// Renders a glyph to PNG bytes at [size] px (logical px at scale already
  /// baked in by the caller — palette passes `size * scale`).
  static Future<Uint8List?> symbolPng(String name, {double size = 32}) async {
    final codepoint = _glyphs[name];
    if (codepoint == null) return null;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(codepoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: 'Segoe Fluent Icons',
          fontFamilyFallback: const ['Segoe MDL2 Assets'],
          color: const Color(0xFF000000),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset((size - painter.width) / 2, (size - painter.height) / 2));
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.ceil(), size.ceil());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  /// Whether a glyph mapping exists (UI falls back to Material icons when not).
  static bool hasGlyph(String name) => _glyphs.containsKey(name);
}
