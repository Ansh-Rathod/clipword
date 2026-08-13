import Foundation

enum TextAnalytics {
    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "can", "had",
        "her", "was", "one", "our", "out", "has", "have", "been", "were", "they",
        "this", "that", "with", "from", "your", "what", "there", "about", "which",
        "when", "make", "like", "time", "just", "know", "take", "into", "year",
        "some", "them", "than", "then", "will", "would", "could", "should"
    ]

    struct Metrics: Sendable {
        let wordCount: Int
        let lineCount: Int
        let charCount: Int
        let readingTimeSeconds: Int
    }

    static func metrics(for text: String) -> Metrics {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = wordCount(in: trimmed)
        let lines = max(1, trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }.count)
        let chars = trimmed.count
        let readingTime = max(1, Int(ceil(Double(words) / 200.0 * 60.0)))
        return Metrics(wordCount: words, lineCount: lines, charCount: chars, readingTimeSeconds: readingTime)
    }

    static func wordCount(in text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    static func isStopWord(_ word: String) -> Bool {
        stopWords.contains(word.lowercased())
    }

    static func tokens(
        from text: String,
        minLength: Int,
        excludeStopWords: Bool
    ) -> [String] {
        let pattern = "[a-zA-Z0-9']+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        return matches.compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let token = String(text[range]).lowercased()
            guard token.count >= minLength else { return nil }
            if excludeStopWords, stopWords.contains(token) { return nil }
            return token
        }
    }
}
