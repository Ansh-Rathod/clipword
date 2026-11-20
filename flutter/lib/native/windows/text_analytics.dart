/// Port of `TextAnalytics` (pure logic, same bounds).
class TextMetrics {
  const TextMetrics({
    required this.wordCount,
    required this.lineCount,
    required this.charCount,
    required this.readingTimeSeconds,
  });
  final int wordCount;
  final int lineCount;
  final int charCount;
  final int readingTimeSeconds;
}

class TextAnalytics {
  TextAnalytics._();

  static const _analysisLimit = 50000;

  static TextMetrics metrics(String text) {
    final chars = text.length;
    final head = chars > _analysisLimit ? text.substring(0, _analysisLimit) : text;
    final trimmed = head.trim();
    final words = trimmed.isEmpty
        ? 0
        : trimmed.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final lines = trimmed
        .split(RegExp(r'\r?\n'))
        .where((l) => l.isNotEmpty)
        .length;
    final reading = (words / 200 * 60).ceil().clamp(1, 1 << 31);
    return TextMetrics(
      wordCount: words,
      lineCount: lines < 1 ? 1 : lines,
      charCount: chars,
      readingTimeSeconds: reading,
    );
  }
}
