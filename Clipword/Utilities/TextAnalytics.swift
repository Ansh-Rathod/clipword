import Foundation

enum TextAnalytics {
    struct Metrics: Sendable {
        let wordCount: Int
        let lineCount: Int
        let charCount: Int
        let readingTimeSeconds: Int
    }

    /// Word/line counting allocates arrays over the whole string; bound it to a
    /// head so multi-MB payloads don't stall the main thread at copy time.
    /// Char count stays exact (O(n) without allocations).
    private static let analysisLimit = 50_000

    static func metrics(for text: String) -> Metrics {
        // `text.utf16.count` is O(1) for native and NSString-backed strings,
        // while `text.count` scans the whole buffer — repeated full-string
        // scans on multi-MB pastes stalled the main thread at copy time.
        // UTF-16 units equal character counts for ASCII/CJK text (only
        // emoji-heavy payloads differ slightly).
        let chars = text.utf16.count
        let head = chars > analysisLimit ? String(text.prefix(analysisLimit)) : text
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = wordCount(in: trimmed)
        let lines = max(1, trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }.count)
        let readingTime = max(1, Int(ceil(Double(words) / 200.0 * 60.0)))
        return Metrics(wordCount: words, lineCount: lines, charCount: chars, readingTimeSeconds: readingTime)
    }

    static func wordCount(in text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }
}
