import Defaults
import Foundation
import Observation
import SwiftData
import AppKit

@Observable
@MainActor
final class AnalyticsEngine {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Tokenization is bounded to a head and word upserts are batched into one
    /// fetch + one save: tokenizing and saving per-token over a multi-MB paste
    /// froze the main thread for minutes (one Core Data transaction per word).
    private static let analyticsTokenLimit = 20_000

    func recordCopy(item: HistoryItem) {
        upsertDailyStats { stats in
            stats.copiesCount += 1
            stats.wordsCopied += item.wordCount
            stats.linesCopied += item.lineCount
            stats.charsCopied += item.charCount
        }

        guard let text = item.plainText,
              item.contentType == .text || item.contentType == .rtf || item.contentType == .html else {
            return
        }

        let head = text.utf16.count > Self.analyticsTokenLimit ? String(text.prefix(Self.analyticsTokenLimit)) : text
        let tokens = TextAnalytics.tokens(
            from: head,
            minLength: Defaults[.analyticsMinWordLength],
            excludeStopWords: Defaults[.analyticsStopWords]
        )
        var counts: [String: Int] = [:]
        for token in tokens {
            counts[token, default: 0] += 1
        }

        let sourceRaw = WordSource.clipboard.rawValue
        var descriptor = FetchDescriptor<WordFrequency>(
            predicate: #Predicate { $0.sourceRaw == sourceRaw }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        var byWord: [String: WordFrequency] = [:]
        for word in existing { byWord[word.word] = word }

        for (word, increment) in counts {
            if let wordFrequency = byWord[word] {
                wordFrequency.count += increment
                wordFrequency.lastSeenAt = .now
            } else {
                modelContext.insert(WordFrequency(word: word, count: increment, source: .clipboard))
            }
        }
        try? modelContext.save()
    }

    func recordPaste(item: HistoryItem) {
        upsertDailyStats { stats in
            stats.pastesCount += 1
        }
    }

    func recordTypedWord(_ word: String) {
        upsertWord(word, source: .typed)
        upsertDailyStats { stats in
            stats.typedWordsCount += 1
        }
    }

    func recordTypingSeconds(_ seconds: Double) {
        guard seconds > 0 else { return }
        upsertDailyStats { stats in
            stats.typingSeconds += seconds
        }
    }

    private func upsertWord(_ word: String, source: WordSource) {
        let sourceRaw = source.rawValue
        var descriptor = FetchDescriptor<WordFrequency>(
            predicate: #Predicate { $0.word == word && $0.sourceRaw == sourceRaw }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.count += 1
            existing.lastSeenAt = .now
        } else {
            modelContext.insert(WordFrequency(word: word, source: source))
        }
        try? modelContext.save()
    }

    private func upsertDailyStats(_ update: (DailyStats) -> Void) {
        let today = Calendar.current.startOfDay(for: .now)
        let key = DailyStats.key(for: today)
        var descriptor = FetchDescriptor<DailyStats>(
            predicate: #Predicate { $0.dateKey == key }
        )
        descriptor.fetchLimit = 1
        let stats: DailyStats
        if let existing = try? modelContext.fetch(descriptor).first {
            stats = existing
        } else {
            stats = DailyStats(date: today)
            modelContext.insert(stats)
        }
        update(stats)
        try? modelContext.save()
    }

    func overviewStats(interval: DateInterval?) -> OverviewStats {
        let items = fetchItems(in: interval)
        let copies = items.reduce(0) { $0 + $1.copyCount }
        let words = items.reduce(0) { $0 + $1.wordCount * max(1, $1.copyCount) }
        let lines = items.reduce(0) { $0 + $1.lineCount * max(1, $1.copyCount) }
        let chars = items.reduce(0) { $0 + $1.charCount * max(1, $1.copyCount) }
        let pastes = items.reduce(0) { $0 + $1.pasteCount }
        let avg = copies > 0 ? Double(words) / Double(copies) : 0

        let clipboardWords = fetchWordFrequencies(source: .clipboard, interval: interval)
        let unique = clipboardWords.count
        let totalWordOccurrences = clipboardWords.reduce(0) { $0 + $1.count }
        let reuse = totalWordOccurrences > 0
            ? 1.0 - (Double(unique) / Double(totalWordOccurrences))
            : 0

        let pasted = items.filter { $0.pasteCount > 0 && $0.lastPastedAt != nil }
        let avgPasteLag: Double
        if pasted.isEmpty {
            avgPasteLag = 0
        } else {
            let total = pasted.reduce(0.0) { sum, item in
                guard let pastedAt = item.lastPastedAt else { return sum }
                return sum + max(0, pastedAt.timeIntervalSince(item.firstCopiedAt))
            }
            avgPasteLag = total / Double(pasted.count)
        }

        let typed = typedOverview(interval: interval)

        return OverviewStats(
            totalCopies: copies,
            totalWords: words,
            totalLines: lines,
            totalChars: chars,
            totalPastes: pastes,
            averageWordsPerCopy: avg,
            uniqueWords: unique,
            reuseRate: reuse,
            averageSecondsToPaste: avgPasteLag,
            typedWords: typed.words,
            typingSeconds: typed.seconds
        )
    }

    private func typedOverview(interval: DateInterval?) -> (words: Int, seconds: Double) {
        var descriptor = FetchDescriptor<DailyStats>()
        if let interval {
            let start = interval.start
            let end = interval.end
            descriptor.predicate = #Predicate { $0.date >= start && $0.date <= end }
        }
        let stats = (try? modelContext.fetch(descriptor)) ?? []
        let words = stats.reduce(0) { $0 + $1.typedWordsCount }
        let seconds = stats.reduce(0.0) { $0 + $1.typingSeconds }
        return (words, seconds)
    }

    func dailyActivity(interval: DateInterval?) -> [DailyActivityPoint] {
        var descriptor = FetchDescriptor<DailyStats>(sortBy: [SortDescriptor(\.date)])
        if let interval {
            let start = interval.start
            let end = interval.end
            descriptor.predicate = #Predicate { $0.date >= start && $0.date <= end }
        }
        let stats = (try? modelContext.fetch(descriptor)) ?? []
        return stats.map {
            DailyActivityPoint(
                id: $0.dateKey,
                date: $0.date,
                copies: $0.copiesCount,
                pastes: $0.pastesCount,
                typedWords: $0.typedWordsCount,
                typingSeconds: $0.typingSeconds
            )
        }
    }

    func topWords(limit: Int = 50, interval: DateInterval?, source: WordSource = .clipboard) -> [TopWordRow] {
        let words = fetchWordFrequencies(source: source, interval: interval)
            .sorted { $0.count > $1.count }
            .prefix(limit)
        return words.map {
            TopWordRow(
                id: "\($0.sourceRaw):\($0.word)",
                word: $0.word,
                count: $0.count,
                lastSeenAt: $0.lastSeenAt,
                source: $0.source
            )
        }
    }

    func hourlyActivity(interval: DateInterval?) -> [HourlyActivityPoint] {
        let items = fetchItems(in: interval)
        var counts = Array(repeating: 0, count: 24)
        let calendar = Calendar.current
        for item in items {
            let hour = calendar.component(.hour, from: item.lastCopiedAt)
            counts[hour] += item.copyCount
        }
        return counts.enumerated().map { HourlyActivityPoint(hour: $0.offset, copies: $0.element) }
    }

    func appBreakdown(interval: DateInterval?) -> [AppCopyStats] {
        let items = fetchItems(in: interval)
        var counts: [String: Int] = [:]
        for item in items {
            let key = item.applicationBundleId ?? "unknown"
            counts[key, default: 0] += item.copyCount
        }
        return counts.map { bundleId, count in
            AppCopyStats(bundleId: bundleId, appName: appName(for: bundleId), count: count)
        }
        .sorted { $0.count > $1.count }
    }

    func categoryBreakdown(interval: DateInterval?) -> [CategoryCopyStats] {
        let items = fetchItems(in: interval)
        var counts: [ClipboardCategory: Int] = [:]
        for item in items {
            counts[item.category, default: 0] += item.copyCount
        }
        return ClipboardCategory.allCases.compactMap { category in
            guard let count = counts[category], count > 0 else { return nil }
            return CategoryCopyStats(category: category, count: count)
        }
        .sorted { $0.count > $1.count }
    }

    func pasteStats(interval: DateInterval?, limit: Int = 20) -> [PasteStatsRow] {
        let items = fetchItems(in: interval)
            .filter { $0.pasteCount > 0 }
            .sorted { $0.pasteCount > $1.pasteCount }
            .prefix(limit)
        return items.map {
            PasteStatsRow(id: $0.id, title: $0.displayTitle, pasteCount: $0.pasteCount, copyCount: $0.copyCount)
        }
    }

    var pasteToCopyRatio: Double {
        let stats = overviewStats(interval: nil)
        guard stats.totalCopies > 0 else { return 0 }
        return Double(stats.totalPastes) / Double(stats.totalCopies)
    }

    // MARK: - Private

    private func fetchWordFrequencies(source: WordSource, interval: DateInterval?) -> [WordFrequency] {
        let sourceRaw = source.rawValue
        var descriptor = FetchDescriptor<WordFrequency>(
            predicate: #Predicate { $0.sourceRaw == sourceRaw }
        )
        var words = (try? modelContext.fetch(descriptor)) ?? []
        if let interval {
            words = words.filter { $0.lastSeenAt >= interval.start && $0.lastSeenAt <= interval.end }
        }
        return words
    }

    private func fetchItems(in interval: DateInterval?) -> [HistoryItem] {
        var descriptor = FetchDescriptor<HistoryItem>()
        if let interval {
            let start = interval.start
            let end = interval.end
            descriptor.predicate = #Predicate { $0.lastCopiedAt >= start && $0.lastCopiedAt <= end }
        }
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func appName(for bundleId: String) -> String {
        if bundleId == "unknown" { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId
    }
}
