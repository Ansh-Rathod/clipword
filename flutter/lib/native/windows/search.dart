import 'package:fuzzy/fuzzy.dart';

import 'prefs.dart';
import 'store.dart';

/// Port of `SearchService` — exact/regex/fuzzy/mixed over history items.
/// Fuzzy uses the `fuzzy` package (same bitap algorithm family as Fuse).
class SearchService {
  Fuzzy<String>? _fuse;
  List<String> _fuseTexts = const [];

  List<HistoryItem> search(String query, List<HistoryItem> items) {
    if (query.isEmpty) return items;
    switch (Prefs.get<String>('searchMode')) {
      case 'exact':
        return _exact(query, items);
      case 'fuzzy':
        return _fuzzy(query, items);
      case 'regex':
        return _regex(query, items);
      default: // mixed
        final exact = _exact(query, items);
        if (exact.isNotEmpty) return exact;
        final regex = _regex(query, items);
        if (regex.isNotEmpty) return regex;
        return _fuzzy(query, items);
    }
  }

  List<HistoryItem> _exact(String q, List<HistoryItem> items) {
    final lower = q.toLowerCase();
    return items
        .where((i) =>
            (i.plainText?.toLowerCase().contains(lower) ?? false) ||
            (i.title?.toLowerCase().contains(lower) ?? false))
        .toList();
  }

  List<HistoryItem> _fuzzy(String q, List<HistoryItem> items) {
    final texts = items.map((i) => i.plainText ?? i.title ?? '').toList();
    if (!_listEquals(texts, _fuseTexts)) {
      _fuseTexts = texts;
      _fuse = Fuzzy<String>(
        texts,
        options: FuzzyOptions(threshold: 0.4, isCaseSensitive: false),
      );
    }
    final fuse = _fuse;
    if (fuse == null) return items;
    final results = fuse.search(q);
    return results
        .map((r) {
          final idx = r.matches.isNotEmpty
              ? r.matches.first.arrayIndex
              : texts.indexOf(r.item);
          return (idx >= 0 && idx < items.length) ? items[idx] : null;
        })
        .whereType<HistoryItem>()
        .toList();
  }

  List<HistoryItem> _regex(String q, List<HistoryItem> items) {
    RegExp re;
    try {
      re = RegExp(q, caseSensitive: false);
    } catch (_) {
      return const [];
    }
    return items
        .where((i) => re.hasMatch(i.plainText ?? i.title ?? ''))
        .toList();
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
