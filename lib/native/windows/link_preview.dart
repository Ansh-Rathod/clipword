import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'prefs.dart';

/// Port of `LinkPreviewService` — Open Graph / Twitter / title / favicon
/// scraping with the same caps, TTLs, cache budget, and in-flight dedupe.
class LinkPreviewService {
  LinkPreviewService._();

  static const _maxBodyBytes = 512 * 1024; // 512 KB HTML cap
  static const _maxImageBytes = 5 * 1024 * 1024;
  static const _successTtl = Duration(days: 14);
  static const _failureTtl = Duration(hours: 6);
  static const _cacheBudgetBytes = 80 * 1024 * 1024; // 80 MB
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Clipword/1.0';

  static final _inflight = <String, Future<Map<String, Object?>?>>{};

  static Directory get _cacheDir => AppDirs.previewCache;

  static String _key(String url) => sha256.convert(utf8.encode(url)).toString();

  /// Returns `{title, description, imageBase64, iconBase64}` or null.
  static Future<Map<String, Object?>?> fetch(String urlString) {
    final inflight = _inflight[urlString];
    if (inflight != null) return inflight;
    final future = _fetch(urlString);
    _inflight[urlString] = future;
    future.whenComplete(() => _inflight.remove(urlString));
    return future;
  }

  static Future<Map<String, Object?>?> _fetch(String urlString) async {
    final cached = _readCache(urlString);
    if (cached != null) return cached;
    final uri = Uri.tryParse(urlString);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    try {
      final body = await _getCapped(uri, _maxBodyBytes, 'text/html');
      if (body == null) {
        _writeCache(urlString, null, success: false);
        return null;
      }
      final html = utf8.decode(body, allowMalformed: true);
      final meta = _parse(html, uri);

      final imageUrl = meta['image'];
      final iconUrl = meta['icon'];
      String? image64, icon64;
      if (imageUrl != null) {
        final b = await _getCapped(Uri.tryParse(imageUrl), _maxImageBytes, 'image/');
        if (b != null) image64 = base64Encode(b);
      }
      if (iconUrl != null) {
        final b = await _getCapped(Uri.tryParse(iconUrl), _maxImageBytes, 'image/');
        if (b != null) icon64 = base64Encode(b);
      }
      final result = <String, Object?>{
        'title': meta['title'],
        'description': meta['description'],
        'image': image64,
        'icon': icon64,
      };
      _writeCache(urlString, result, success: true);
      return result;
    } catch (_) {
      _writeCache(urlString, null, success: false);
      return null;
    }
  }

  /// GET with a hard byte cap (aborts mid-download once exceeded) and no
  /// cookies — mirrors `ephemeral` URLSession behavior.
  static Future<Uint8List?> _getCapped(
      Uri? uri, int cap, String acceptPrefix) async {
    if (uri == null) return null;
    final client = HttpClient()..userAgent = _userAgent;
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      req.followRedirects = true;
      req.maxRedirects = 5;
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) return null;
      final type = res.headers.contentType?.mimeType ?? '';
      if (acceptPrefix == 'text/html' &&
          type.isNotEmpty &&
          !type.startsWith('text/')) {
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
        if (builder.length > cap) return null;
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Map<String, String?> _parse(String html, Uri base) {
    String? metaContent(String property) {
      final patterns = [
        RegExp(
            '<meta[^>]+(?:property|name)=["\']$property["\'][^>]+content=["\']([^"\']*)["\']',
            caseSensitive: false),
        RegExp(
            '<meta[^>]+content=["\']([^"\']*)["\'][^>]+(?:property|name)=["\']$property["\']',
            caseSensitive: false),
      ];
      for (final p in patterns) {
        final m = p.firstMatch(html);
        if (m != null) return _unescape(m.group(1)!.trim());
      }
      return null;
    }

    String? title = metaContent('og:title') ??
        metaContent('twitter:title');
    if (title == null) {
      final m = RegExp('<title[^>]*>([^<]*)</title>', caseSensitive: false)
          .firstMatch(html);
      if (m != null) title = _unescape(m.group(1)!.trim());
    }
    final description =
        metaContent('og:description') ?? metaContent('twitter:description');
    final image = _absolute(
        metaContent('og:image') ?? metaContent('twitter:image'), base);
    var icon = _absolute(
        _linkRel(html, 'icon') ?? _linkRel(html, 'shortcut icon'), base);
    icon ??= '${base.scheme}://${base.host}/favicon.ico';
    return {
      'title': title,
      'description': description,
      'image': image,
      'icon': icon,
    };
  }

  static String? _linkRel(String html, String rel) {
    final m = RegExp(
            '<link[^>]+rel=["\'][^"\']*$rel[^"\']*["\'][^>]+href=["\']([^"\']*)["\']',
            caseSensitive: false)
        .firstMatch(html);
    return m?.group(1)?.trim();
  }

  static String? _absolute(String? url, Uri base) {
    if (url == null || url.isEmpty) return null;
    final resolved = base.resolve(url);
    return (resolved.isScheme('http') || resolved.isScheme('https'))
        ? resolved.toString()
        : null;
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");

  // ---------- disk cache ----------

  static Map<String, Object?>? _readCache(String url) {
    try {
      final file = File('${_cacheDir.path}${Platform.pathSeparator}${_key(url)}.json');
      if (!file.existsSync()) return null;
      final stat = file.statSync();
      final age = DateTime.now().difference(stat.modified);
      final record = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final success = record['success'] == true;
      final ttl = success ? _successTtl : _failureTtl;
      if (age > ttl) {
        file.deleteSync();
        return null;
      }
      return success ? (record['data'] as Map<String, Object?>?) : null;
    } catch (_) {
      return null;
    }
  }

  static void _writeCache(String url, Map<String, Object?>? data,
      {required bool success}) {
    try {
      _cacheDir.createSync(recursive: true);
      final file = File('${_cacheDir.path}${Platform.pathSeparator}${_key(url)}.json');
      file.writeAsStringSync(jsonEncode({'success': success, 'data': data}));
      _evictIfNeeded();
    } catch (_) {}
  }

  static void _evictIfNeeded() {
    try {
      final dir = _cacheDir;
      if (!dir.existsSync()) return;
      final files = dir
          .listSync()
          .whereType<File>()
          .map((f) => (f: f, s: f.statSync()))
          .toList();
      var total = files.fold<int>(0, (sum, f) => sum + f.s.size);
      if (total <= _cacheBudgetBytes) return;
      files.sort((a, b) => a.s.modified.compareTo(b.s.modified));
      for (final f in files) {
        if (total <= _cacheBudgetBytes) break;
        total -= f.s.size;
        f.f.deleteSync();
      }
    } catch (_) {}
  }

  static String cacheSize() {
    try {
      final dir = _cacheDir;
      if (!dir.existsSync()) return '0 KB';
      var total = 0;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        total += f.lengthSync();
      }
      const units = ['B', 'KB', 'MB', 'GB'];
      var size = total.toDouble();
      var u = 0;
      while (size >= 1024 && u < units.length - 1) {
        size /= 1024;
        u++;
      }
      return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[u]}';
    } catch (_) {
      return '—';
    }
  }

  static void clearCache() {
    try {
      final dir = _cacheDir;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
