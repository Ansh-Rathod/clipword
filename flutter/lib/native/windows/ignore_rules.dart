import 'prefs.dart';
import 'snapshot_codec.dart';

/// Port of `IgnoreRules` — gated on format names, source app, and text rules.
class IgnoreRules {
  IgnoreRules._();

  /// Marker clipboard format written by Clipword itself; matching clips are
  /// our own writes and must not be re-captured.
  static const markerFormat = 'clipword.marker';

  /// `formats` = clipboard format names present, `sourceApp` = foreground
  /// exe path (or null), `plainText` = captured text if any.
  static bool shouldIgnore({
    required List<String> formats,
    required String? sourceApp,
    String? plainText,
    bool hasMarker = false,
  }) {
    if (Prefs.get<bool>('ignoreEvents')) return true;
    if (Prefs.get<bool>('ignoreNextEvent')) {
      Prefs.set('ignoreNextEvent', false);
      return true;
    }
    if (hasMarker) return true;

    final ignored = {
      ...Prefs.defaultIgnoredFormats,
      ...Prefs.list('ignoredPasteboardTypes'),
    };
    for (final f in formats) {
      if (ignored.contains(f)) return true;
    }

    if (sourceApp != null) {
      final apps = Prefs.list('ignoredApps');
      final name = _exeName(sourceApp);
      if (Prefs.get<bool>('allowedAppsOnly')) {
        if (apps.isNotEmpty && !_appListed(apps, sourceApp, name)) return true;
      } else if (_appListed(apps, sourceApp, name)) {
        return true;
      }
    }

    if (plainText != null) {
      for (final pattern in Prefs.list('ignoredRegexPatterns')) {
        if (pattern.isEmpty) continue;
        try {
          if (RegExp(pattern).hasMatch(plainText)) return true;
        } catch (_) {}
      }
    }
    return false;
  }

  static bool shouldSave(ClipSnapshotData snapshot) {
    switch (snapshot.contentType) {
      case ClipContentType.text:
      case ClipContentType.rtf:
      case ClipContentType.html:
        return Prefs.get<bool>('saveText');
      case ClipContentType.image:
        return Prefs.get<bool>('saveImages');
      case ClipContentType.file:
        return Prefs.get<bool>('saveFiles');
    }
  }

  static String _exeName(String path) {
    final norm = path.replaceAll('/', '\\').toLowerCase();
    final idx = norm.lastIndexOf('\\');
    return idx >= 0 ? norm.substring(idx + 1) : norm;
  }

  static bool _appListed(List<String> apps, String path, String name) =>
      apps.any((a) => a == path || _exeName(a) == name);
}
