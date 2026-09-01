import Foundation

/// Pure prefix matcher + scoring for the snippet suggestion palette.
/// Kept side-effect free so it's unit-testable against fixture `HistoryItem`s.
enum SuggestionMatcher {
    struct Config {
        var minChars: Int = 2
        var maxLength: Int = 500
        var limit: Int = 6
    }

    /// Suggestions whose `plainText` starts with `query` (case-insensitive),
    /// deduplicated by normalized text (most recent wins), ranked by
    /// recency + copyCount + pin/bookmark boost, shortest completions favored.
    static func suggestions(
        for query: String,
        in items: [HistoryItem],
        config: Config = Config()
    ) -> [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= config.minChars else { return [] }
        let lowered = trimmed.lowercased()

        let now = Date.now
        var seen = Set<String>()
        var scored: [(item: HistoryItem, score: Double)] = []

        for item in items {
            // Text-only; images/files/colors never suggest.
            guard isSuggestible(item) else { continue }
            guard let text = item.plainText else { continue }
            // Bound the scan like `HistoryItem.displayTitle` does — never walk
            // a multi-MB payload per keystroke.
            let head = text.prefix(config.maxLength)
            guard head.count >= lowered.count else { continue }
            let loweredHead = head.lowercased()
            guard loweredHead.hasPrefix(lowered) else { continue }
            // Exact match with the query leaves nothing to insert.
            if loweredHead == lowered && head.count == lowered.count { continue }
            // Dedupe identical content, keeping the most recently copied.
            if !seen.insert(loweredHead).inserted { continue }

            scored.append((item, score(item, now: now)))
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(config.limit)
            .map(\.item)
    }

    /// Fallback for an empty query: most recent suggestible items (pins first).
    static func recentTextItems(
        in items: [HistoryItem],
        limit: Int = 6
    ) -> [HistoryItem] {
        items
            .filter(isSuggestible)
            .sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                return a.lastCopiedAt > b.lastCopiedAt
            }
            .prefix(limit)
            .map { $0 }
    }

    static func isSuggestible(_ item: HistoryItem) -> Bool {
        guard let text = item.plainText, !text.isEmpty else { return false }
        switch item.contentType {
        case .text, .rtf, .html:
            return true
        case .image, .file:
            return false
        }
    }

    private static func score(_ item: HistoryItem, now: Date) -> Double {
        var s = 0.0
        // Recency decay: copied within the hour ≈ 10 pts, a day ago ≈ 0.4.
        let hours = max(0.25, now.timeIntervalSince(item.lastCopiedAt) / 3600)
        s += min(10, 10 / hours)
        s += Double(min(item.copyCount, 10)) * 0.6
        if item.isPinned { s += 4 }
        if item.isBookmarked { s += 2 }
        // Favor shorter completions — less noise per row.
        if let text = item.plainText { s -= Double(text.count) * 0.002 }
        return s
    }
}
