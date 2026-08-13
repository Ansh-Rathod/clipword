import Foundation
import SwiftData

@Model
final class HistoryItem {
    var id: UUID
    var contentData: Data
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
        return parts.joined(separator: " · ")
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
