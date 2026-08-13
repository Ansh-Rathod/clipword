import AppKit
import Foundation

enum ContentClassifier {
    private static let codeUTIPrefixes = [
        "public.source-code",
        "public.swift-source",
        "public.c-source",
        "public.c-header",
        "public.objective-c-source",
        "public.shell-script",
        "public.python-script",
        "public.ruby-script",
        "public.perl-script",
        "public.php-script",
        "public.xml",
        "public.json"
    ]

    private static let codeKeywords = [
        "import ", "function ", "def ", "class ", "#include", "const ", "let ", "var ",
        "return ", "async ", "await ", "public ", "private ", "struct ", "enum "
    ]

    static func classify(snapshot: PasteboardSnapshot, pasteboardTypes: [String] = [], hasColorOnPasteboard: Bool = false) -> ClipboardCategory {
        switch snapshot.contentType {
        case .file:
            return .file
        case .image:
            return .image
        case .rtf, .html:
            return .styledText
        case .text:
            break
        }

        if hasColorOnPasteboard || isColorText(snapshot.plainText) {
            return .color
        }

        if hasLinkType(pasteboardTypes) || isLinkText(snapshot.plainText) {
            return .link
        }

        if isCode(pasteboardTypes: pasteboardTypes, text: snapshot.plainText) {
            return .code
        }

        return .plainText
    }

    static func classify(item: HistoryItem) -> ClipboardCategory {
        if let category = ClipboardCategory(rawValue: item.contentCategoryRaw),
           !item.contentCategoryRaw.isEmpty {
            return category
        }
        if let snapshot = PasteboardSnapshot.decode(from: item.contentData) {
            return classify(snapshot: snapshot, pasteboardTypes: item.pasteboardTypes ?? [])
        }
        switch item.contentType {
        case .file: return .file
        case .image: return .image
        case .rtf, .html: return .styledText
        case .text:
            if isLinkText(item.plainText) { return .link }
            if isCode(pasteboardTypes: item.pasteboardTypes ?? [], text: item.plainText) { return .code }
            if isColorText(item.plainText) { return .color }
            return .plainText
        }
    }

    /// Classification only needs a bounded head — scanning/allocating over a
    /// multi-MB pasteboard would freeze the main thread at copy time.
    private static let classifyTextLimit = 20_000

    private static func classifyHead(_ text: String?) -> String? {
        guard let text else { return nil }
        return String(text.prefix(classifyTextLimit))
    }

    private static func hasLinkType(_ types: [String]) -> Bool {
        types.contains { $0 == "public.url" || ($0.contains("url") && $0.contains("public")) }
    }

    private static func isLinkText(_ text: String?) -> Bool {
        guard let text = classifyHead(text) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let url = URL(string: trimmed), url.scheme != nil,
           ["http", "https", "ftp", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            return true
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            let matches = detector.matches(in: trimmed, range: range)
            if let match = matches.first, matches.count == 1,
               let urlRange = Range(match.range, in: trimmed) {
                let matched = String(trimmed[urlRange])
                let coverage = Double(matched.count) / Double(trimmed.count)
                return coverage >= 0.9
            }
        }

        return false
    }

    private static func isColorText(_ text: String?) -> Bool {
        guard let text = classifyHead(text) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            "^#[0-9A-Fa-f]{3,8}$",
            "^rgb\\(\\s*\\d+\\s*,\\s*\\d+\\s*,\\s*\\d+\\s*\\)$",
            "^hsl\\(\\s*\\d+\\s*,\\s*\\d+%?\\s*,\\s*\\d+%?\\s*\\)$"
        ]
        return patterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func isCode(pasteboardTypes: [String], text: String?) -> Bool {
        if pasteboardTypes.contains(where: { type in
            codeUTIPrefixes.contains(where: { type.hasPrefix($0) || type.contains($0) })
        }) {
            return true
        }

        guard let text = classifyHead(text), !text.isEmpty else { return false }
        var score = 0
        if text.contains("{") && text.contains("}") { score += 1 }
        if text.contains(";") { score += 1 }
        if text.contains("=>") || text.contains("->") { score += 1 }
        if codeKeywords.contains(where: { text.contains($0) }) { score += 1 }
        if text.contains("#include") || text.contains("#!/") { score += 1 }

        let lines = text.components(separatedBy: .newlines)
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        if indented >= 2 { score += 1 }

        return score >= 2
    }
}
