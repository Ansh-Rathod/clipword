import Foundation
import SwiftData

/// Independent bookmark copy — survives history delete/prune.
@Model
final class BookmarkItem {
    var id: UUID
    var contentData: Data
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
    var imageData: Data?
    var title: String?

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
