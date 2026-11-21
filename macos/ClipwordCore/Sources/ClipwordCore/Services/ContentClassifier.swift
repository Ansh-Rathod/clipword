import AppKit
import Foundation

public enum ContentClassifier {
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

    public static func classify(snapshot: PasteboardSnapshot, pasteboardTypes: [String] = [], hasColorOnPasteboard: Bool = false) -> ClipboardCategory {
        switch snapshot.contentType {
        case .file:
            return .file
        case .image:
            return .image
        case .rtf, .html, .text:
            break
        }

        if hasColorOnPasteboard || isColorText(snapshot.plainText) {
            return .color
        }

        // Browsers copy links as HTML (`<a href=...>`), so HTML/RTF must still
        // be eligible as a link when the visible text is a URL.
        if hasLinkType(pasteboardTypes) || isLinkText(snapshot.plainText) {
            return .link
        }

        if snapshot.contentType == .rtf || snapshot.contentType == .html {
            return .styledText
        }

        if isCode(pasteboardTypes: pasteboardTypes, text: snapshot.plainText) {
            return .code
        }

        return .plainText
    }

    public static func classify(item: HistoryItem) -> ClipboardCategory {
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

    /// http(s) URL suitable for fetching a link preview, if the clip is a link.
    static func previewableURL(from text: String?) -> URL? {
        guard let trimmed = normalizedLinkText(text), !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), isPreviewable(url) {
            return url
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = detector.firstMatch(in: trimmed, options: [], range: range),
               let url = match.url, isPreviewable(url) {
                return url
            }
        }
        return nil
    }

    /// URL preview for the detail pane: the clip itself must be a link, not
    /// merely contain one inside a longer snippet.
    public static func linkPreviewURL(from text: String?) -> URL? {
        guard isLinkText(text) else { return nil }
        return previewableURL(from: text)
    }

    private static func isPreviewable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        return url.host != nil
    }

    public static func isLinkText(_ text: String?) -> Bool {
        guard let trimmed = normalizedLinkText(text), !trimmed.isEmpty else { return false }

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

    private static func normalizedLinkText(_ text: String?) -> String? {
        guard let text = classifyHead(text) else { return nil }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        trimmed = trimmed.replacingOccurrences(of: "\u{200B}", with: "")
        trimmed = trimmed.replacingOccurrences(of: "\u{FEFF}", with: "")
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2 {
            let first = trimmed.first
            let last = trimmed.last
            if (first == "<" && last == ">") || (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed.isEmpty ? nil : trimmed
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
