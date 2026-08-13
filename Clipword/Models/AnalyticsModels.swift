import Foundation
import SwiftData

enum WordSource: String, Codable, CaseIterable {
    case clipboard
    case typed
}

@Model
final class WordFrequency {
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
final class DailyStats {
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

struct OverviewStats: Sendable {
    var totalCopies: Int = 0
    var totalWords: Int = 0
    var totalLines: Int = 0
    var totalChars: Int = 0
    var totalPastes: Int = 0
    var averageWordsPerCopy: Double = 0
    var uniqueWords: Int = 0
    var reuseRate: Double = 0
    var averageSecondsToPaste: Double = 0
    var typedWords: Int = 0
    var typingSeconds: Double = 0
}

struct AppCopyStats: Identifiable, Sendable {
    var id: String { bundleId }
    let bundleId: String
    let appName: String
    let count: Int
}

struct CategoryCopyStats: Identifiable, Sendable {
    var id: String { category.rawValue }
    let category: ClipboardCategory
    let count: Int

    var label: String { category.label }
}

struct DailyActivityPoint: Identifiable, Sendable {
    let id: String
    let date: Date
    let copies: Int
    let pastes: Int
    let typedWords: Int
    let typingSeconds: Double
}

struct TopWordRow: Identifiable, Sendable {
    let id: String
    let word: String
    let count: Int
    let lastSeenAt: Date
    let source: WordSource
}

struct PasteStatsRow: Identifiable, Sendable {
    let id: UUID
    let title: String
    let pasteCount: Int
    let copyCount: Int
}

struct HourlyActivityPoint: Identifiable, Sendable {
    var id: Int { hour }
    let hour: Int
    let copies: Int
}
