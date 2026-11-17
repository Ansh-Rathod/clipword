import Foundation
import SwiftData

/// Kept so existing Clipword stores that once recorded analytics still open.
public enum WordSource: String, Codable, CaseIterable {
    case clipboard
    case typed
}

@Model
public final class WordFrequency {
    var word: String
    var count: Int
    var lastSeenAt: Date
    var sourceRaw: String = WordSource.clipboard.rawValue

    var source: WordSource {
        get { WordSource(rawValue: sourceRaw) ?? .clipboard }
        set { sourceRaw = newValue.rawValue }
    }

    init(word: String, count: Int = 1, lastSeenAt: Date = .now, source: WordSource = .clipboard) {
        self.word = word
        self.count = count
        self.lastSeenAt = lastSeenAt
        self.sourceRaw = source.rawValue
    }
}

@Model
public final class DailyStats {
    @Attribute(.unique) var dateKey: String
    var date: Date
    var copiesCount: Int
    var wordsCopied: Int
    var linesCopied: Int
    var charsCopied: Int
    var pastesCount: Int
    var typedWordsCount: Int = 0
    var typingSeconds: Double = 0

    init(
        date: Date,
        copiesCount: Int = 0,
        wordsCopied: Int = 0,
        linesCopied: Int = 0,
        charsCopied: Int = 0,
        pastesCount: Int = 0,
        typedWordsCount: Int = 0,
        typingSeconds: Double = 0
    ) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        self.date = start
        self.dateKey = Self.key(for: start)
        self.copiesCount = copiesCount
        self.wordsCopied = wordsCopied
        self.linesCopied = linesCopied
        self.charsCopied = charsCopied
        self.pastesCount = pastesCount
        self.typedWordsCount = typedWordsCount
        self.typingSeconds = typingSeconds
    }

    static func key(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
