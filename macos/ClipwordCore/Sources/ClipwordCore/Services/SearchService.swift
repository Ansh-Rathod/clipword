import Defaults
import Foundation
import Fuse
import Observation

@Observable
@MainActor
public final class SearchService {

    public init() {}

    public func search(query: String, in items: [HistoryItem]) -> [HistoryItem] {
        guard !query.isEmpty else { return items }
        let texts = items.map { (plainText: $0.plainText, title: $0.title) }
        return Self.searchIndices(query: query, mode: Defaults[.searchMode], in: texts)
            .map { items[$0] }
    }

    /// Index-based variant that works on extracted (Sendable) (plainText, title)
    /// pairs and returns indices into the input — safe to call off the main actor.
    nonisolated public static func searchIndices(
        query: String,
        mode: SearchMode,
        in items: [(plainText: String?, title: String?)]
    ) -> [Int] {
        switch mode {
        case .exact:
            return exactIndices(query: query, in: items)
        case .fuzzy:
            return fuzzyIndices(query: query, in: items)
        case .regex:
            return regexIndices(query: query, in: items)
        case .mixed:
            let exact = exactIndices(query: query, in: items)
            if !exact.isEmpty { return exact }
            let regex = regexIndices(query: query, in: items)
            if !regex.isEmpty { return regex }
            return fuzzyIndices(query: query, in: items)
        }
    }

    nonisolated private static func exactIndices(
        query: String,
        in items: [(plainText: String?, title: String?)]
    ) -> [Int] {
        items.indices.filter { i in
            (items[i].plainText?.localizedCaseInsensitiveContains(query) ?? false)
                || (items[i].title?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    nonisolated private static func regexIndices(
        query: String,
        in items: [(plainText: String?, title: String?)]
    ) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
            return []
        }
        return items.indices.filter { i in
            let text = items[i].plainText ?? items[i].title ?? ""
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    nonisolated private static func fuzzyIndices(
        query: String,
        in items: [(plainText: String?, title: String?)]
    ) -> [Int] {
        let fuse = Fuse(threshold: 0.4)
        var positions: [Int] = []
        var texts: [String] = []
        texts.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            guard let text = item.plainText ?? item.title else { continue }
            positions.append(i)
            texts.append(text)
        }
        return fuse.search(query, in: texts).map { positions[$0.index] }
    }

    public func searchBookmarks(query: String, in items: [BookmarkItem]) -> [BookmarkItem] {
        guard !query.isEmpty else { return items }
        return items.filter {
            ($0.plainText?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}
