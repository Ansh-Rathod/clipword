import Foundation
import SwiftData

enum ClipboardEventKind: String, Codable, CaseIterable {
    case copied
    case pasted

    var label: String {
        switch self {
        case .copied: "Copied"
        case .pasted: "Pasted"
        }
    }

    var systemImage: String {
        switch self {
        case .copied: "doc.on.doc"
        case .pasted: "text.insert"
        }
    }
}

/// One copy or paste of a history entry. Survives as long as the parent item.
@Model
final class ClipboardEvent {
    var id: UUID
    var kindRaw: String
    var occurredAt: Date
    var applicationBundleId: String?
    var item: HistoryItem?

    var kind: ClipboardEventKind {
        get { ClipboardEventKind(rawValue: kindRaw) ?? .copied }
        set { kindRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        kind: ClipboardEventKind,
        occurredAt: Date = .now,
        applicationBundleId: String? = nil,
        item: HistoryItem? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.occurredAt = occurredAt
        self.applicationBundleId = applicationBundleId
        self.item = item
    }
}

struct ItemActivityEvent: Identifiable, Hashable {
    let id: UUID
    let kind: ClipboardEventKind
    let date: Date
    let applicationBundleId: String?
    var isSynthesized: Bool = false
}

@Model
final class HistoryItem {
    var id: UUID
    /// Full payload. `.externalStorage` keeps multi-MB blobs out of the row
    /// cache — `HistoryStore.reload()` would otherwise materialize every blob
    /// in the database on launch. Verified to lightweight-migrate existing
    /// stores (old rows stay inline, new writes go external).
    @Attribute(.externalStorage) var contentData: Data
    /// SHA-256 hex of `contentData`. Duplicate detection compares this string
    /// instead of faulting every stored blob on each copy.
    var contentHash: String?
    var plainText: String?
    var contentTypeRaw: String
    var contentCategoryRaw: String = ClipboardCategory.plainText.rawValue
    var pasteboardTypesData: Data?
    var applicationBundleId: String?
    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var copyCount: Int
    var pasteCount: Int
    var lastPastedAt: Date?
    var isPinned: Bool
    var isBookmarked: Bool = false
    var pinKey: String?
    var pinAlias: String?
    var wordCount: Int
    var lineCount: Int
    var charCount: Int
    var readingTimeSeconds: Int
    @Attribute(.externalStorage) var imageData: Data?
    var title: String?

    @Relationship(deleteRule: .cascade, inverse: \ClipboardEvent.item)
    var events: [ClipboardEvent] = []

    var contentType: ContentType {
        get { ContentType(rawValue: contentTypeRaw) ?? .text }
        set { contentTypeRaw = newValue.rawValue }
    }

    var category: ClipboardCategory {
        get { ClipboardCategory(rawValue: contentCategoryRaw) ?? .plainText }
        set { contentCategoryRaw = newValue.rawValue }
    }

    var pasteboardTypes: [String]? {
        get {
            guard let pasteboardTypesData else { return nil }
            return try? JSONDecoder().decode([String].self, from: pasteboardTypesData)
        }
        set {
            pasteboardTypesData = try? JSONEncoder().encode(newValue ?? [])
        }
    }

    init(
        id: UUID = UUID(),
        contentData: Data = Data(),
        contentHash: String? = nil,
        plainText: String? = nil,
        contentType: ContentType = .text,
        contentCategory: ClipboardCategory = .plainText,
        pasteboardTypes: [String]? = nil,
        applicationBundleId: String? = nil,
        firstCopiedAt: Date = .now,
        lastCopiedAt: Date = .now,
        copyCount: Int = 1,
        pasteCount: Int = 0,
        lastPastedAt: Date? = nil,
        isPinned: Bool = false,
        isBookmarked: Bool = false,
        pinKey: String? = nil,
        pinAlias: String? = nil,
        wordCount: Int = 0,
        lineCount: Int = 0,
        charCount: Int = 0,
        readingTimeSeconds: Int = 0,
        imageData: Data? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.contentData = contentData
        self.contentHash = contentHash
        self.plainText = plainText
        self.contentTypeRaw = contentType.rawValue
        self.contentCategoryRaw = contentCategory.rawValue
        self.pasteboardTypesData = try? JSONEncoder().encode(pasteboardTypes ?? [])
        self.applicationBundleId = applicationBundleId
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.pasteCount = pasteCount
        self.lastPastedAt = lastPastedAt
        self.isPinned = isPinned
        self.isBookmarked = isBookmarked
        self.pinKey = pinKey
        self.pinAlias = pinAlias
        self.wordCount = wordCount
        self.lineCount = lineCount
        self.charCount = charCount
        self.readingTimeSeconds = readingTimeSeconds
        self.imageData = imageData
        self.title = title
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let plainText, !plainText.isEmpty {
            // Trim only a bounded head so multi-MB payloads don't cost O(n) per row render.
            let head = plainText.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines)
            if head.isEmpty {
                // All-whitespace head (rare): fall back to a full trim.
                let trimmed = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return contentType.label }
                return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
            }
            return head.count > 80 ? String(head.prefix(80)) + "…" : head
        }
        return contentType.label
    }

    var subtitle: String {
        var parts: [String] = [category.label]
        if wordCount > 0 { parts.append("\(wordCount) words") }
        if lineCount > 0 { parts.append("\(lineCount) lines") }
        if copyCount > 1 { parts.append("×\(copyCount)") }
        if pasteCount > 0 { parts.append("\(pasteCount) pastes") }
        return parts.joined(separator: " · ")
    }

    /// Newest-first copy/paste log. Falls back to first/last timestamps for
    /// items that predate per-event tracking.
    var activityTimeline: [ItemActivityEvent] {
        // `modelContext == nil` means the object was invalidated (deleted +
        // saved) while this array was still materialized — touching any
        // persisted property on it fatals, so skip before sorting/mapping.
        let stored = events
            .filter { $0.modelContext != nil }
            .sorted { $0.occurredAt > $1.occurredAt }
            .map {
                ItemActivityEvent(
                    id: $0.id,
                    kind: $0.kind,
                    date: $0.occurredAt,
                    applicationBundleId: $0.applicationBundleId
                )
            }
        if !stored.isEmpty { return stored }
        return Self.synthesizedTimeline(from: self)
    }

    private static func synthesizedTimeline(from item: HistoryItem) -> [ItemActivityEvent] {
        var result: [ItemActivityEvent] = [
            ItemActivityEvent(
                id: item.id,
                kind: .copied,
                date: item.firstCopiedAt,
                applicationBundleId: item.applicationBundleId,
                isSynthesized: true
            )
        ]
        if item.copyCount > 1, item.lastCopiedAt != item.firstCopiedAt {
            result.append(
                ItemActivityEvent(
                    id: UUID(),
                    kind: .copied,
                    date: item.lastCopiedAt,
                    applicationBundleId: item.applicationBundleId,
                    isSynthesized: true
                )
            )
        }
        if let pasted = item.lastPastedAt, item.pasteCount > 0 {
            result.append(
                ItemActivityEvent(
                    id: UUID(),
                    kind: .pasted,
                    date: pasted,
                    applicationBundleId: nil,
                    isSynthesized: true
                )
            )
        }
        return result.sorted { $0.date > $1.date }
    }
}

extension HistoryItem: Hashable {
    static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
