import Defaults
import Foundation
import Fuse
import Observation

@Observable
@MainActor
final class SearchService {
    private let fuse = Fuse(threshold: 0.4)

    /// Search inspects at most this many leading characters of each item's
    /// text. Multi-MB clipboard payloads made every keystroke scan megabytes
    /// (Fuse is quadratic-ish in text length). Same bound as the analytics
    /// head — matches deep inside a huge payload are simply not findable.
    static let searchableTextLimit = 50_000

    func search(query: String, in items: [HistoryItem]) -> [HistoryItem] {
        guard !query.isEmpty else { return items }
        return Perf.measure("search.run") {
            switch Defaults[.searchMode] {
            case .exact:
                return exactSearch(query: query, in: items)
            case .fuzzy:
                return fuzzySearch(query: query, in: items)
            case .regex:
                return regexSearch(query: query, in: items)
            case .mixed:
                let exact = exactSearch(query: query, in: items)
                if !exact.isEmpty { return exact }
                let regex = regexSearch(query: query, in: items)
                if !regex.isEmpty { return regex }
                return fuzzySearch(query: query, in: items)
            }
        }
    }

    func searchBookmarks(query: String, in items: [BookmarkItem]) -> [BookmarkItem] {
        guard !query.isEmpty else { return items }
        return items.filter {
            (boundedText($0.plainText)?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func exactSearch(query: String, in items: [HistoryItem]) -> [HistoryItem] {
        items.filter {
            (boundedText($0.plainText)?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func fuzzySearch(query: String, in items: [HistoryItem]) -> [HistoryItem] {
        let searchable = items.compactMap { item -> (HistoryItem, String)? in
            guard let text = boundedText(item.plainText) ?? item.title else { return nil }
            return (item, text)
        }
        let results = fuse.search(query, in: searchable.map(\.1))
        return results.compactMap { result in
            searchable[result.index].0
        }
    }

    private func regexSearch(query: String, in items: [HistoryItem]) -> [HistoryItem] {
        guard let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
            return []
        }
        return items.filter { item in
            let text = boundedText(item.plainText) ?? item.title ?? ""
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// `text` truncated to `searchableTextLimit` chars, or nil.
    private func boundedText(_ text: String?) -> String? {
        guard let text else { return nil }
        guard text.count > Self.searchableTextLimit else { return text }
        return String(text.prefix(Self.searchableTextLimit))
    }
}
