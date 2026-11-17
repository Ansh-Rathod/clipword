import Foundation
import SwiftData

@Model
public final class BookmarkFolder {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var sortIndex: Int

    @Relationship(deleteRule: .nullify, inverse: \BookmarkItem.folder)
    var items: [BookmarkItem] = []

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sortIndex = sortIndex
    }
}

extension BookmarkFolder: Hashable {
    static func == (lhs: BookmarkFolder, rhs: BookmarkFolder) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Independent bookmark copy — survives history delete/prune.
@Model
public final class BookmarkItem {
    var id: UUID
    public var contentData: Data
    public var plainText: String?
    public var contentTypeRaw: String
    public var contentCategoryRaw: String = ClipboardCategory.plainText.rawValue
    var pasteboardTypesData: Data?
    public var applicationBundleId: String?
    public var bookmarkedAt: Date
    public var sourceCopiedAt: Date
    public var wordCount: Int
    public var lineCount: Int
    public var charCount: Int
    public var readingTimeSeconds: Int
    public var imageData: Data?
    public var title: String?
    public var folder: BookmarkFolder?

    public var contentType: ContentType {
        get { ContentType(rawValue: contentTypeRaw) ?? .text }
        set { contentTypeRaw = newValue.rawValue }
    }

    public var category: ClipboardCategory {
        get { ClipboardCategory(rawValue: contentCategoryRaw) ?? .plainText }
        set { contentCategoryRaw = newValue.rawValue }
    }

    public init(from item: HistoryItem) {
        self.id = UUID()
        self.contentData = item.contentData
        self.plainText = item.plainText
        self.contentTypeRaw = item.contentTypeRaw
        self.contentCategoryRaw = item.contentCategoryRaw
        self.pasteboardTypesData = item.pasteboardTypesData
        self.applicationBundleId = item.applicationBundleId
        self.bookmarkedAt = .now
        self.sourceCopiedAt = item.lastCopiedAt
        self.wordCount = item.wordCount
        self.lineCount = item.lineCount
        self.charCount = item.charCount
        self.readingTimeSeconds = item.readingTimeSeconds
        self.imageData = item.imageData
        self.title = item.title
    }

    public var displayTitle: String {
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
}

extension BookmarkItem: Hashable {
    static func == (lhs: BookmarkItem, rhs: BookmarkItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
