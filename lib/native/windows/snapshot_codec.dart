import 'dart:convert';
import 'dart:typed_data';

/// Port of `PasteboardSnapshot` (`PasteboardTypes.swift`): one captured
/// clipboard payload and its stable JSON blob encoding stored in `contentData`.
enum ClipContentType { text, rtf, html, image, file }

extension ClipContentTypeInfo on ClipContentType {
  String get raw => name;
  String get label => switch (this) {
        ClipContentType.text => 'Text',
        ClipContentType.rtf => 'Rich Text',
        ClipContentType.html => 'HTML',
        ClipContentType.image => 'Image',
        ClipContentType.file => 'File',
      };
}

class ClipSnapshotData {
  ClipSnapshotData({
    this.plainText,
    this.rtfData,
    this.htmlData,
    this.imageData,
    this.fileURLs,
    required this.contentType,
    this.pasteboardTypes,
    this.hasColorOnPasteboard,
  });

  String? plainText;
  Uint8List? rtfData;
  Uint8List? htmlData;
  Uint8List? imageData;
  List<String>? fileURLs;
  ClipContentType contentType;
  List<String>? pasteboardTypes;
  bool? hasColorOnPasteboard;

  /// Deterministic encode (sorted keys) so byte-compare dedupe works —
  /// mirrors `.sortedKeys` in the Swift encoder.
  Uint8List encode() {
    final map = <String, Object?>{
      'contentType': contentType.raw,
      if (fileURLs != null) 'fileURLs': fileURLs,
      if (hasColorOnPasteboard != null)
        'hasColorOnPasteboard': hasColorOnPasteboard,
      if (htmlData != null) 'htmlData': base64Encode(htmlData!),
      if (imageData != null) 'imageData': base64Encode(imageData!),
      if (pasteboardTypes != null) 'pasteboardTypes': pasteboardTypes,
      if (plainText != null) 'plainText': plainText,
      if (rtfData != null) 'rtfData': base64Encode(rtfData!),
    };
    // Keys are inserted alphabetically above; encode directly.
    return utf8.encode(jsonEncode(map));
  }

  static ClipSnapshotData? decode(Uint8List data) {
    try {
      final raw = jsonDecode(utf8.decode(data));
      if (raw is! Map) return null;
      Uint8List? blob(Object? v) =>
          v is String ? Uint8List.fromList(base64Decode(v)) : null;
      return ClipSnapshotData(
        plainText: raw['plainText'] as String?,
        rtfData: blob(raw['rtfData']),
        htmlData: blob(raw['htmlData']),
        imageData: blob(raw['imageData']),
        fileURLs: (raw['fileURLs'] as List?)?.cast<String>(),
        contentType: ClipContentType.values.firstWhere(
          (t) => t.raw == raw['contentType'],
          orElse: () => ClipContentType.text,
        ),
        pasteboardTypes: (raw['pasteboardTypes'] as List?)?.cast<String>(),
        hasColorOnPasteboard: raw['hasColorOnPasteboard'] as bool?,
      );
    } catch (_) {
      return null;
    }
  }
}
