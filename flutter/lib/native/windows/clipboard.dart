import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:win32/win32.dart';

import 'snapshot_codec.dart';

/// Result of [WinClipboard.capture] — snapshot plus monitor bookkeeping so
/// `shouldIgnore` sees the same inputs as the macOS version.
class ClipboardCapture {
  const ClipboardCapture(this.snapshot, this.hasMarker, this.formats);
  final ClipSnapshotData? snapshot;
  final bool hasMarker;
  final List<String> formats;
}

/// Raw Win32 clipboard access: enumerate formats, capture a
/// [ClipSnapshotData], and write one back — the Windows analogue of
/// `PasteboardSnapshot.capture`/`write`.
class WinClipboard {
  WinClipboard._();

  static const cfUnicodeText = 13;
  static const cfHdrop = 15;
  static const cfDib = 8;
  static const cfDibV5 = 17;
  static const cfBitmap = 2;

  static final int cfHtml = RegisterClipboardFormat('HTML Format'.toNativeUtf16(allocator: calloc));
  static final int cfRtf = RegisterClipboardFormat('Rich Text Format'.toNativeUtf16(allocator: calloc));
  static final int cfPng = RegisterClipboardFormat('PNG'.toNativeUtf16(allocator: calloc));
  static final int cfMarker = RegisterClipboardFormat('clipword.marker'.toNativeUtf16(allocator: calloc));

  static int sequenceNumber() => GetClipboardSequenceNumber();

  /// Clipboard format ids currently available (enumerated while open).
  static List<int> availableFormatIds() {
    final ids = <int>[];
    if (OpenClipboard(NULL) == 0) return ids;
    try {
      var fmt = 0;
      while ((fmt = EnumClipboardFormats(fmt)) != 0) {
        ids.add(fmt);
      }
    } finally {
      CloseClipboard();
    }
    return ids;
  }

  static String? formatName(int id) {
    const standard = {
      1: 'CF_TEXT',
      2: 'CF_BITMAP',
      8: 'CF_DIB',
      9: 'CF_PALETTE',
      13: 'CF_UNICODETEXT',
      14: 'CF_ENHMETAFILE',
      15: 'CF_HDROP',
      16: 'CF_LOCALE',
      17: 'CF_DIBV5',
      0x0082: 'CF_DSPBITMAP',
    };
    if (standard.containsKey(id)) return standard[id];
    final buf = calloc.allocate<Utf16>((256) * 2);
    try {
      if (GetClipboardFormatName(id, buf, 256) == 0) return null;
      return buf.toDartString();
    } finally {
      calloc.free(buf);
    }
  }

  static Uint8List? _readData(int format) {
    final handle = GetClipboardData(format);
    if (handle == NULL) return null;
    final hData = Pointer<Uint8>.fromAddress(handle);
    final size = GlobalSize(hData);
    if (size <= 0) return null;
    final ptr = GlobalLock(hData);
    if (ptr == nullptr) return null;
    try {
      final out = Uint8List(size);
      out.setAll(0, ptr.cast<Uint8>().asTypedList(size));
      return out;
    } finally {
      GlobalUnlock(hData);
    }
  }

  static String? _readText(int format) {
    final data = _readData(format);
    if (data == null) return null;
    // UTF-16 LE, NUL-terminated.
    final u16 = Uint16List.view(data.buffer, 0, (data.length & ~1) ~/ 2);
    var end = u16.length;
    for (var i = 0; i < u16.length; i++) {
      if (u16[i] == 0) {
        end = i;
        break;
      }
    }
    return String.fromCharCodes(u16.sublist(0, end));
  }

  /// Reads CF_HDROP into a list of filesystem paths. The clipboard data is
  /// already an HDROP handle, so no GlobalLock is needed.
  static List<String>? _readFileDrop() {
    final handle = GetClipboardData(cfHdrop);
    if (handle == NULL) return null;
    final count = DragQueryFile(handle, 0xFFFFFFFF, nullptr, 0);
    if (count == 0) return null;
    final paths = <String>[];
    for (var i = 0; i < count; i++) {
      final len = DragQueryFile(handle, i, nullptr, 0) + 1;
      final buf = calloc.allocate<Utf16>((len) * 2);
      try {
        DragQueryFile(handle, i, buf, len);
        paths.add(buf.toDartString());
      } finally {
        calloc.free(buf);
      }
    }
    return paths;
  }

  /// CF_DIB payload → PNG bytes (prepend a BMP file header and decode).
  static Uint8List? _dibToPng(Uint8List dib) {
    if (dib.length < 40) return null;
    final view = ByteData.sublistView(dib);
    final headerSize = view.getUint32(0, Endian.little);
    final bpp = view.getUint16(14, Endian.little);
    final compression = view.getUint32(16, Endian.little);
    var colors = 0;
    if (dib.length >= 36) colors = view.getUint32(32, Endian.little);
    var paletteBytes = colors * 4;
    if (colors == 0 && bpp <= 8 && bpp > 0) paletteBytes = 1 << (bpp + 2);
    var masks = 0;
    if (headerSize == 40 && compression == 3) masks = 12;
    if (headerSize == 40 && compression == 6) masks = 16;
    final dataOffset = 14 + headerSize + masks + paletteBytes;
    final fileSize = 14 + dib.length;

    final bmp = BytesBuilder(copy: false)
      ..addByte(0x42) // 'B'
      ..addByte(0x4D) // 'M'
      ..add((_u32(fileSize)))
      ..add(_u32(0)) // reserved
      ..add(_u32(dataOffset))
      ..add(dib);
    final decoded = img.decodeBmp(bmp.toBytes());
    if (decoded == null) return null;
    return Uint8List.fromList(img.encodePng(decoded));
  }

  static List<int> _u32(int v) =>
      [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

  /// Capture the current clipboard (port of `PasteboardSnapshot.capture`,
  /// same precedence: files → url → image → html → rtf → text). Always
  /// returns a result so the caller can consume `ignoreNextEvent`/`hasMarker`
  /// in the same order as `IgnoreRules.shouldIgnore` on macOS.
  static ClipboardCapture capture() {
    if (OpenClipboard(NULL) == 0) {
      return const ClipboardCapture(null, false, []);
    }
    try {
      final ids = <int>[];
      var fmt = 0;
      while ((fmt = EnumClipboardFormats(fmt)) != 0) {
        ids.add(fmt);
      }
      final names = ids.map(formatName).whereType<String>().toList();
      final hasMarker = ids.contains(cfMarker);
      ClipboardCapture result(ClipSnapshotData? s) =>
          ClipboardCapture(s, hasMarker, names);

      // Files
      if (ids.contains(cfHdrop)) {
        final paths = _readFileDrop();
        if (paths != null && paths.isNotEmpty) {
          return result(ClipSnapshotData(
            plainText: paths.join('\n'),
            fileURLs: paths.map(_pathToFileUri).toList(),
            contentType: ClipContentType.file,
            pasteboardTypes: names,
          ));
        }
      }

      // URL formats (browsers)
      if (names.any((n) {
        final l = n.toLowerCase();
        return l.contains('uniformresourcelocator') || l == 'cfstr_ineturla';
      })) {
        final url = _readText(cfUnicodeText);
        if (url != null && url.isNotEmpty) {
          return result(ClipSnapshotData(
            plainText: url,
            contentType: ClipContentType.text,
            pasteboardTypes: names,
          ));
        }
      }

      // Image — prefer registered PNG, fall back to DIB conversion.
      if (ids.contains(cfPng)) {
        final png = _readData(cfPng);
        if (png != null) {
          final decoded = img.decodePng(png);
          final label = decoded != null
              ? 'Image (${decoded.width}×${decoded.height})'
              : 'Image';
          return result(ClipSnapshotData(
            plainText: label,
            imageData: png,
            contentType: ClipContentType.image,
            pasteboardTypes: names,
          ));
        }
      }
      if (ids.contains(cfDib) ||
          ids.contains(cfDibV5) ||
          ids.contains(cfBitmap)) {
        final dib = _readData(ids.contains(cfDibV5) ? cfDibV5 : cfDib);
        if (dib != null) {
          final png = _dibToPng(dib);
          if (png != null) {
            final decoded = img.decodePng(png);
            final label = decoded != null
                ? 'Image (${decoded.width}×${decoded.height})'
                : 'Image';
            return result(ClipSnapshotData(
              plainText: label,
              imageData: png,
              contentType: ClipContentType.image,
              pasteboardTypes: names,
            ));
          }
        }
      }

      // HTML
      if (ids.contains(cfHtml)) {
        final raw = _readData(cfHtml);
        if (raw != null) {
          final html =
              utf8.decode(raw, allowMalformed: true).replaceAll(' ', '');
          return result(ClipSnapshotData(
            plainText: _readText(cfUnicodeText) ?? html,
            htmlData: Uint8List.fromList(utf8.encode(html)),
            contentType: ClipContentType.html,
            pasteboardTypes: names,
          ));
        }
      }

      // RTF
      if (ids.contains(cfRtf)) {
        final rtf = _readData(cfRtf);
        if (rtf != null) {
          return result(ClipSnapshotData(
            plainText: _readText(cfUnicodeText),
            rtfData: rtf,
            contentType: ClipContentType.rtf,
            pasteboardTypes: names,
          ));
        }
      }

      // Plain text
      final text = _readText(cfUnicodeText);
      if (text != null && text.isNotEmpty) {
        return result(ClipSnapshotData(
          plainText: text,
          contentType: ClipContentType.text,
          pasteboardTypes: names,
        ));
      }

      return result(null);
    } finally {
      CloseClipboard();
    }
  }

  static const markerName = 'clipword.marker';

  static String _pathToFileUri(String path) {
    final norm = path.replaceAll('\\', '/');
    final encoded = norm.split('/').map(Uri.encodeComponent).join('/');
    return 'file:///${encoded.startsWith('/') ? encoded.substring(1) : encoded}';
  }

  /// Writes a snapshot back to the clipboard (port of `snapshot.write`).
  /// `withoutFormatting` writes plain text + files only, and skips the
  /// Clipword marker — same semantics as macOS.
  static void write(ClipSnapshotData snapshot, {required bool withoutFormatting}) {
    if (OpenClipboard(NULL) == 0) return;
    try {
      EmptyClipboard();
      final plain = snapshot.plainText;
      if (withoutFormatting) {
        if (plain != null) _setText(plain);
        _setFiles(snapshot.fileURLs);
        return;
      }
      switch (snapshot.contentType) {
        case ClipContentType.file:
          _setFiles(snapshot.fileURLs);
        case ClipContentType.image:
          _setImage(snapshot.imageData);
        case ClipContentType.html:
          if (snapshot.htmlData != null) {
            _setData(cfHtml, _wrapCfHtml(snapshot.htmlData!));
          }
          if (plain != null) _setText(plain);
        case ClipContentType.rtf:
          if (snapshot.rtfData != null) _setData(cfRtf, snapshot.rtfData!);
          if (plain != null) _setText(plain);
        case ClipContentType.text:
          if (plain != null) _setText(plain);
      }
      _setData(cfMarker, Uint8List.fromList([1]));
    } finally {
      CloseClipboard();
    }
  }

  /// CF_HTML requires a `Version:0.9` header block with byte offsets.
  static Uint8List _wrapCfHtml(Uint8List htmlBytes) {
    const header = 'Version:0.9\r\nStartHTML:';
    const mid1 = '\r\nEndHTML:';
    const mid2 = '\r\nStartFragment:';
    const mid3 = '\r\nEndFragment:';
    const suffix = '\r\n';
    // Build with fixed-width 10-digit offsets, then patch.
    const pad = '0000000000';
    final pre =
        utf8.encode('$header$pad$mid1$pad$mid2$pad$mid3$pad$suffix');
    final fragStart = '<!--StartFragment-->';
    final fragEnd = '<!--EndFragment-->';
    var body = utf8.decode(htmlBytes, allowMalformed: true);
    if (!body.contains('StartFragment')) {
      body = '<html><body>$fragStart$body$fragEnd</body></html>';
    }
    final bodyBytes = utf8.encode(body);
    final total = pre.length + bodyBytes.length;
    final fragS = body.contains(fragStart)
        ? pre.length + body.indexOf(fragStart) + fragStart.length
        : pre.length;
    final fragE = body.contains(fragEnd)
        ? pre.length + body.indexOf(fragEnd)
        : total;
    String off(int v) => v.toString().padLeft(10, '0');
    final head = utf8.encode(
        '$header${off(pre.length)}$mid1${off(total)}$mid2${off(fragS)}$mid3${off(fragE)}$suffix');
    final out = Uint8List(head.length + bodyBytes.length);
    out.setRange(0, head.length, head);
    out.setRange(head.length, out.length, bodyBytes);
    return out;
  }

  static void _setData(int format, Uint8List bytes) {
    final h = GlobalAlloc(0x0002 /* GMEM_MOVEABLE */, bytes.length);
    if (h == nullptr) return;
    final ptr = GlobalLock(h);
    if (ptr == nullptr) {
      GlobalFree(h);
      return;
    }
    ptr.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    GlobalUnlock(h);
    if (SetClipboardData(format, h.address) == NULL) {
      GlobalFree(h);
    }
  }

  static void _setText(String text) {
    final units = text.codeUnits;
    final bytes = Uint8List((units.length + 1) * 2);
    ByteData.view(bytes.buffer).buffer.asUint16List().setRange(0, units.length, units);
    _setData(cfUnicodeText, bytes);
  }

  static void _setFiles(List<String>? fileURLs) {
    if (fileURLs == null || fileURLs.isEmpty) return;
    final paths = fileURLs
        .map((u) => Uri.tryParse(u))
        .whereType<Uri>()
        .map((u) => u.toFilePath().replaceAll('/', '\\'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (paths.isEmpty) return;
    // DROPFILES: 20-byte header + UTF-16 double-null-terminated path list.
    final joined = '${paths.join('\u0000')}\u0000\u0000';
    final units = joined.codeUnits;
    final bytes = Uint8List(20 + units.length * 2);
    ByteData.view(bytes.buffer)
      ..setUint32(0, 20, Endian.little) // pFiles offset
      ..setUint32(16, 1, Endian.little); // fWide
    bytes.setRange(20, bytes.length, Uint16List.fromList(units).buffer.asUint8List());
    _setData(cfHdrop, bytes);
  }

  static void _setImage(Uint8List? png) {
    if (png == null) return;
    _setData(cfPng, png);
    final decoded = img.decodePng(png);
    if (decoded == null) return;
    final bmp = img.encodeBmp(decoded);
    // Strip the 14-byte BITMAPFILEHEADER → CF_DIB.
    if (bmp.length > 14) {
      _setData(cfDib, Uint8List.fromList(bmp.sublist(14)));
    }
  }

  static bool hasFormat(int format) => IsClipboardFormatAvailable(format) != 0;

  static void empty() {
    if (OpenClipboard(NULL) == 0) return;
    try {
      EmptyClipboard();
    } finally {
      CloseClipboard();
    }
  }
}
