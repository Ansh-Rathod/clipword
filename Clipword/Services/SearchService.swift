import Defaults
import Foundation
import Fuse
import Observation

@Observable
@MainActor
final class SearchService {
    private let fuse = Fuse(threshold: 0.4)

    func search(query: String, in items: [HistoryItem]) -> [HistoryItem] {
        guard !query.isEmpty else { return items }
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

    func searchBookmarks(query: String, in items: [BookmarkItem]) -> [BookmarkItem] {
        guard !query.isEmpty else { return items }
        return items.filter {
            ($0.plainText?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func exactSearch(query: String, in items: [HistoryItem]) -> [HistoryItem] {
        items.filter {
            ($0.plainText?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func fuzzySearch(query: String, in items: [HistoryItem]) -> [HistoryItem] {
        let searchable = items.compactMap { item -> (HistoryItem, String)? in
            guard let text = item.plainText ?? item.title else { return nil }
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
            let text = item.plainText ?? item.title ?? ""
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}
