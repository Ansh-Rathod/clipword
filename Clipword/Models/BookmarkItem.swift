import Foundation
import SwiftData

@Model
final class BookmarkFolder {
    var id: UUID
    var name: String
    var createdAt: Date
    var sortIndex: Int

    @Relationship(deleteRule: .nullify, inverse: \BookmarkItem.folder)
    var items: [BookmarkItem] = []

    init(
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
final class BookmarkItem {
    var id: UUID
    @Attribute(.externalStorage) var contentData: Data
    var contentHash: String?
    var plainText: String?
    var contentTypeRaw: String
    var contentCategoryRaw: String = ClipboardCategory.plainText.rawValue
    var pasteboardTypesData: Data?
    var applicationBundleId: String?
    var bookmarkedAt: Date
    var sourceCopiedAt: Date
    var wordCount: Int
    var lineCount: Int
    var charCount: Int
    var readingTimeSeconds: Int
    @Attribute(.externalStorage) var imageData: Data?
    var title: String?
    var folder: BookmarkFolder?

    var contentType: ContentType {
        get { ContentType(rawValue: contentTypeRaw) ?? .text }
        set { contentTypeRaw = newValue.rawValue }
    }

    var category: ClipboardCategory {
        get { ClipboardCategory(rawValue: contentCategoryRaw) ?? .plainText }
        set { contentCategoryRaw = newValue.rawValue }
    }

    init(from item: HistoryItem) {
        self.id = UUID()
        self.contentData = item.contentData
        self.contentHash = item.contentHash ?? ContentHasher.hex(item.contentData)
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
}

extension BookmarkItem: Hashable {
    static func == (lhs: BookmarkItem, rhs: BookmarkItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
