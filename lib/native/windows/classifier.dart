import 'snapshot_codec.dart';

/// Port of `ClipboardCategory` + `ContentClassifier` (pure logic).
enum ClipboardCategory {
  plainText,
  link,
  code,
  styledText,
  image,
  file,
  color;

  String get raw => name;

  String get label => switch (this) {
        ClipboardCategory.plainText => 'Plain Text',
        ClipboardCategory.link => 'Links',
        ClipboardCategory.code => 'Code',
        ClipboardCategory.styledText => 'Styled Text',
        ClipboardCategory.image => 'Images',
        ClipboardCategory.file => 'Files',
        ClipboardCategory.color => 'Colors',
      };

  String get systemImage => switch (this) {
        ClipboardCategory.plainText => 'doc.text',
        ClipboardCategory.link => 'link',
        ClipboardCategory.code => 'chevron.left.forwardslash.chevron.right',
        ClipboardCategory.styledText => 'doc.richtext',
        ClipboardCategory.image => 'photo',
        ClipboardCategory.file => 'doc',
        ClipboardCategory.color => 'paintpalette',
      };

  static ClipboardCategory? parse(String? raw) {
    if (raw == null) return null;
    for (final c in values) {
      if (c.raw == raw) return c;
    }
    return null;
  }
}

class ContentClassifier {
  ContentClassifier._();

  static const _codeFormatHints = [
    'chromium web page mime type', // browsers
    'vscode/editordata',
    'application/x-code',
  ];

  static const _codeKeywords = [
    'import ', 'function ', 'def ', 'class ', '#include', 'const ', 'let ',
    'var ', 'return ', 'async ', 'await ', 'public ', 'private ', 'struct ',
    'enum '
  ];

  static const _classifyTextLimit = 20000;

  static ClipboardCategory classify(
    ClipSnapshotData snapshot, {
    List<String> formats = const [],
    bool hasColor = false,
  }) {
    switch (snapshot.contentType) {
      case ClipContentType.file:
        return ClipboardCategory.file;
      case ClipContentType.image:
        return ClipboardCategory.image;
      default:
        break;
    }

    if (hasColor ||
        snapshot.hasColorOnPasteboard == true ||
        isColorText(snapshot.plainText)) {
      return ClipboardCategory.color;
    }

    if (_hasLinkFormat(formats) || isLinkText(snapshot.plainText)) {
      return ClipboardCategory.link;
    }

    if (snapshot.contentType == ClipContentType.rtf ||
        snapshot.contentType == ClipContentType.html) {
      return ClipboardCategory.styledText;
    }

    if (isCode(formats: formats, text: snapshot.plainText)) {
      return ClipboardCategory.code;
    }

    return ClipboardCategory.plainText;
  }

  /// Category for an edited/stored item (port of `classify(item:)`).
  static ClipboardCategory classifyStored({
    required String? existingCategory,
    required ClipContentType contentType,
    String? plainText,
    List<String> formats = const [],
  }) {
    final existing = ClipboardCategory.parse(existingCategory);
    if (existing != null && (existingCategory?.isNotEmpty ?? false)) {
      return existing;
    }
    switch (contentType) {
      case ClipContentType.file:
        return ClipboardCategory.file;
      case ClipContentType.image:
        return ClipboardCategory.image;
      case ClipContentType.rtf:
      case ClipContentType.html:
        return ClipboardCategory.styledText;
      case ClipContentType.text:
        if (isLinkText(plainText)) return ClipboardCategory.link;
        if (isCode(formats: formats, text: plainText)) {
          return ClipboardCategory.code;
        }
        if (isColorText(plainText)) return ClipboardCategory.color;
        return ClipboardCategory.plainText;
    }
  }

  static String? _head(String? text) {
    if (text == null) return null;
    return text.length <= _classifyTextLimit
        ? text
        : text.substring(0, _classifyTextLimit);
  }

  static bool _hasLinkFormat(List<String> formats) => formats.any((f) {
        final lower = f.toLowerCase();
        return lower == 'uniformresourcelocator' ||
            lower == 'uniformresourcelocatorw' ||
            lower.contains('url') && lower.contains('link');
      });

  /// http(s) URL suitable for a link preview, if the clip is itself a link.
  static Uri? linkPreviewURL(String? text) {
    if (!isLinkText(text)) return null;
    final trimmed = normalizedLinkText(text);
    if (trimmed == null || trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri != null && _isPreviewable(uri)) return uri;
    final match = _linkRegex.firstMatch(trimmed);
    if (match != null) {
      final candidate = Uri.tryParse(match.group(0)!);
      if (candidate != null && _isPreviewable(candidate)) return candidate;
    }
    return null;
  }

  static bool _isPreviewable(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;

  static final _linkRegex = RegExp(
    r'https?://[^\s<>"\x27]+',
    caseSensitive: false,
  );

  static bool isLinkText(String? text) {
    final trimmed = normalizedLinkText(text);
    if (trimmed == null || trimmed.isEmpty) return false;

    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme &&
        ['http', 'https', 'ftp', 'mailto'].contains(uri.scheme.toLowerCase())) {
      return true;
    }

    final matches = _linkRegex.allMatches(trimmed).toList();
    if (matches.length == 1) {
      final matched = matches.first.group(0)!;
      if (matched.length / trimmed.length >= 0.9) return true;
    }
    return false;
  }

  static String? normalizedLinkText(String? text) {
    final head = _head(text);
    if (head == null) return null;
    var trimmed = head.trim();
    if (trimmed.isEmpty) return null;
    trimmed = trimmed.replaceAll('\u200B', '').replaceAll('\uFEFF', '');
    trimmed = trimmed.trim();
    if (trimmed.length >= 2) {
      final first = trimmed[0];
      final last = trimmed[trimmed.length - 1];
      if ((first == '<' && last == '>') ||
          (first == '"' && last == '"') ||
          (first == "'" && last == "'")) {
        trimmed = trimmed.substring(1, trimmed.length - 1).trim();
      }
    }
    return trimmed.isEmpty ? null : trimmed;
  }

  static final _colorPatterns = [
    RegExp(r'^#[0-9A-Fa-f]{3,8}$'),
    RegExp(r'^rgb\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\)$'),
    RegExp(r'^hsl\(\s*\d+\s*,\s*\d+%?\s*,\s*\d+%?\s*\)$'),
  ];

  static bool isColorText(String? text) {
    final head = _head(text);
    if (head == null) return false;
    final trimmed = head.trim();
    return _colorPatterns.any((p) => p.hasMatch(trimmed));
  }

  static bool isCode({List<String> formats = const [], String? text}) {
    if (formats.any((f) {
      final lower = f.toLowerCase();
      return _codeFormatHints.any((hint) => lower.contains(hint));
    })) {
      return true;
    }

    final head = _head(text);
    if (head == null || head.isEmpty) return false;
    var score = 0;
    if (head.contains('{') && head.contains('}')) score++;
    if (head.contains(';')) score++;
    if (head.contains('=>') || head.contains('->')) score++;
    if (_codeKeywords.any((k) => head.contains(k))) score++;
    if (head.contains('#include') || head.contains('#!/')) score++;

    final lines = head.split(RegExp(r'\r?\n'));
    final indented = lines.where((l) => l.startsWith('    ') || l.startsWith('\t')).length;
    if (indented >= 2) score++;

    return score >= 2;
  }
}
