import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Open Graph / HTML metadata for a copied URL. Fetched on demand from the
/// detail pane and cached on disk so revisiting the same link is instant and
/// offline.
struct LinkPreviewRecord: Sendable {
    var url: URL
    var title: String?
    var detail: String?
    var siteName: String?
    var imageData: Data?
    var iconData: Data?
    var fetchedAt: Date
    var failed: Bool

    var host: String {
        url.host?.replacingOccurrences(of: "www.", with: "", options: [.anchored, .caseInsensitive])
            ?? url.absoluteString
    }

    static func failed(_ url: URL) -> LinkPreviewRecord {
        LinkPreviewRecord(
            url: url,
            title: nil,
            detail: nil,
            siteName: nil,
            imageData: nil,
            iconData: nil,
            fetchedAt: .now,
            failed: true
        )
    }
}

actor LinkPreviewService {
    static let shared = LinkPreviewService()

    private var memory: [String: LinkPreviewRecord] = [:]
    private var inflight: [String: Task<LinkPreviewRecord, Never>] = [:]
    private let session: URLSession

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    nonisolated private static let maxHTMLBytes = 512 * 1024
    nonisolated private static let maxImageBytes = 2_500_000
    nonisolated private static let successTTL: TimeInterval = 14 * 24 * 60 * 60
    nonisolated private static let failureTTL: TimeInterval = 6 * 60 * 60
    private static let memoryLimit = 40
    nonisolated private static let diskBudget: Int64 = 80 * 1024 * 1024

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept-Language": "en-US,en;q=0.9"
        ]
        session = URLSession(configuration: config)
    }

    func preview(for url: URL) async -> LinkPreviewRecord {
        let key = Self.cacheKey(for: url)
        if let cached = memory[key], Self.isFresh(cached) {
            return cached
        }
        if let disk = Self.loadFromDisk(key: key, fallbackURL: url), Self.isFresh(disk) {
            remember(disk, key: key)
            return disk
        }
        if let existing = inflight[key] {
            return await existing.value
        }

        let task = Task<LinkPreviewRecord, Never> { [session] in
            await Self.fetch(url: url, session: session)
        }
        inflight[key] = task
        let record = await task.value
        inflight[key] = nil
        remember(record, key: key)
        Self.saveToDisk(record, key: key)
        Self.enforceDiskBudget()
        return record
    }

    func clearCache() {
        memory.removeAll()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        try? FileManager.default.removeItem(at: Self.directory)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    nonisolated static var cacheSizeDescription: String {
        let bytes = cacheByteCount()
        guard bytes > 0 else { return "Empty" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated static func cacheByteCount() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return total + size
        }
    }

    // MARK: - Fetch

    nonisolated private static func fetch(url: URL, session: URLSession) async -> LinkPreviewRecord {
        do {
            let (html, finalURL) = try await loadHTML(url: url, session: session)
            let meta = HTMLMetaParser.parse(html, pageURL: finalURL)
            async let imageData = loadImage(meta.imageURL, session: session, maxPixelSize: 900, asJPEG: true)
            async let iconData = loadImage(meta.iconURL, session: session, maxPixelSize: 128, asJPEG: false)
            let image = await imageData
            let icon = await iconData

            let site = Self.trimmed(meta.siteName, limit: 80)
                ?? finalURL.host?.replacingOccurrences(of: "www.", with: "", options: [.anchored, .caseInsensitive])
            return LinkPreviewRecord(
                url: finalURL,
                title: Self.trimmed(meta.title, limit: 200),
                detail: Self.trimmed(meta.detail, limit: 400),
                siteName: site,
                imageData: image,
                iconData: icon,
                fetchedAt: .now,
                failed: false
            )
        } catch {
            return .failed(url)
        }
    }

    nonisolated private static func loadHTML(url: URL, session: URLSession) async throws -> (String, URL) {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-\(maxHTMLBytes - 1)", forHTTPHeaderField: "Range")
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let finalURL = http.url ?? url
        let html = decodeHTML(data.prefix(maxHTMLBytes), response: response)
        return (html, finalURL)
    }

    nonisolated private static func decodeHTML(_ data: Data, response: URLResponse) -> String {
        if let name = response.textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let ns = CFStringConvertEncodingToNSStringEncoding(cf)
                if let string = String(data: data, encoding: String.Encoding(rawValue: ns)) {
                    return string
                }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func loadImage(_ url: URL?, session: URLSession, maxPixelSize: Int, asJPEG: Bool) async -> Data? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            if response.expectedContentLength > Int64(maxImageBytes) { return nil }
            guard data.count <= maxImageBytes else { return nil }
            return downsample(data, maxPixelSize: maxPixelSize, asJPEG: asJPEG)
        } catch {
            return nil
        }
    }

    nonisolated private static func downsample(_ data: Data, maxPixelSize: Int, asJPEG: Bool) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let destData = NSMutableData()
        let type = (asJPEG ? UTType.jpeg : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(destData, type, 1, nil) else { return nil }
        var destOptions: [CFString: Any] = [:]
        if asJPEG { destOptions[kCGImageDestinationLossyCompressionQuality] = 0.82 }
        CGImageDestinationAddImage(destination, image, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destData as Data
    }

    // MARK: - Cache

    private func remember(_ record: LinkPreviewRecord, key: String) {
        memory[key] = record
        if memory.count > Self.memoryLimit {
            let oldest = memory.min { $0.value.fetchedAt < $1.value.fetchedAt }?.key
            if let oldest { memory.removeValue(forKey: oldest) }
        }
    }

    nonisolated private static func isFresh(_ record: LinkPreviewRecord) -> Bool {
        let ttl = record.failed ? failureTTL : successTTL
        return Date().timeIntervalSince(record.fetchedAt) < ttl
    }

    nonisolated private static func loadFromDisk(key: String, fallbackURL: URL) -> LinkPreviewRecord? {
        let jsonURL = directory.appendingPathComponent("\(key).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: jsonURL),
              let stored = try? decoder.decode(DiskRecord.self, from: data) else {
            return nil
        }
        let image = try? Data(contentsOf: directory.appendingPathComponent("\(key).jpg"))
        let icon = try? Data(contentsOf: directory.appendingPathComponent("\(key)-icon.png"))
        return LinkPreviewRecord(
            url: URL(string: stored.url) ?? fallbackURL,
            title: stored.title,
            detail: stored.detail,
            siteName: stored.siteName,
            imageData: stored.failed ? nil : image,
            iconData: stored.failed ? nil : icon,
            fetchedAt: stored.fetchedAt,
            failed: stored.failed
        )
    }

    nonisolated private static func saveToDisk(_ record: LinkPreviewRecord, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let image = record.imageData, !record.failed {
            try? image.write(to: directory.appendingPathComponent("\(key).jpg"), options: .atomic)
        }
        if let icon = record.iconData, !record.failed {
            try? icon.write(to: directory.appendingPathComponent("\(key)-icon.png"), options: .atomic)
        }
        let stored = DiskRecord(
            url: record.url.absoluteString,
            title: record.title,
            detail: record.detail,
            siteName: record.siteName,
            fetchedAt: record.fetchedAt,
            failed: record.failed
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(stored) {
            try? data.write(to: directory.appendingPathComponent("\(key).json"), options: .atomic)
        }
    }

    nonisolated private static func enforceDiskBudget() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        var total = files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard total > diskBudget else { return }

        let jsonFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }

        let target = diskBudget * 3 / 4
        for json in jsonFiles {
            guard total > target else { break }
            let key = json.deletingPathExtension().lastPathComponent
            let related = [
                json,
                directory.appendingPathComponent("\(key).jpg"),
                directory.appendingPathComponent("\(key)-icon.png")
            ]
            for url in related {
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try? fm.removeItem(at: url)
                total -= size
            }
        }
    }

    nonisolated private static func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(normalize(url).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func normalize(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        if components?.path == "/", components?.query == nil {
            components?.path = ""
        }
        return components?.string ?? url.absoluteString
    }

    nonisolated private static func trimmed(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    nonisolated static var directory: URL {
        AppSupport.directory.appendingPathComponent("LinkPreviews", isDirectory: true)
    }

    private struct DiskRecord: Codable, Sendable {
        var url: String
        var title: String?
        var detail: String?
        var siteName: String?
        var fetchedAt: Date
        var failed: Bool
    }
}

// MARK: - HTML

private struct ParsedHTMLMeta {
    var title: String?
    var detail: String?
    var siteName: String?
    var imageURL: URL?
    var iconURL: URL?
}

private enum HTMLMetaParser {
    static func parse(_ html: String, pageURL: URL) -> ParsedHTMLMeta {
        let head: String
        if let range = html.range(of: "</head>", options: .caseInsensitive) {
            head = String(html[html.startIndex..<range.lowerBound].prefix(LinkPreviewHTMLLimits.headChars))
        } else {
            head = String(html.prefix(LinkPreviewHTMLLimits.headChars))
        }

        var og: [String: String] = [:]
        var twitter: [String: String] = [:]
        var named: [String: String] = [:]
        var icons: [String] = []

        for tag in tags(named: "meta", in: head) {
            let attrs = attributes(in: tag)
            let key = (attrs["property"] ?? attrs["name"] ?? "").lowercased()
            guard let content = attrs["content"], !content.isEmpty else { continue }
            let value = unescape(content)
            if key.hasPrefix("og:") {
                if og[key] == nil { og[key] = value }
            } else if key.hasPrefix("twitter:") {
                if twitter[key] == nil { twitter[key] = value }
            } else if named[key] == nil {
                named[key] = value
            }
        }

        for tag in tags(named: "link", in: head) {
            let attrs = attributes(in: tag)
            let rel = (attrs["rel"] ?? "").lowercased()
            guard let href = attrs["href"], !href.isEmpty else { continue }
            if rel.contains("apple-touch-icon") || rel == "icon" || rel == "shortcut icon" {
                icons.append(href)
            }
        }

        let title = og["og:title"]
            ?? twitter["twitter:title"]
            ?? named["title"]
            ?? titleTag(in: head)
        let detail = og["og:description"]
            ?? twitter["twitter:description"]
            ?? named["description"]
        let siteName = og["og:site_name"]
        let imageRaw = og["og:image"]
            ?? og["og:image:url"]
            ?? twitter["twitter:image"]
            ?? twitter["twitter:image:src"]
        let iconRaw = icons.first { $0.lowercased().contains("apple-touch-icon") }
            ?? icons.first

        return ParsedHTMLMeta(
            title: stripTags(title),
            detail: stripTags(detail),
            siteName: stripTags(siteName),
            imageURL: resolve(imageRaw, base: pageURL),
            iconURL: resolve(iconRaw, base: pageURL)
                ?? URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
        )
    }

    private static func titleTag(in html: String) -> String? {
        guard let start = html.range(of: "<title", options: .caseInsensitive),
              let openEnd = html.range(of: ">", range: start.lowerBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: openEnd.upperBound..<html.endIndex)
        else { return nil }
        return unescape(String(html[openEnd.upperBound..<close.lowerBound]))
    }

    private static func tags(named name: String, in html: String) -> [String] {
        var result: [String] = []
        var searchFrom = html.startIndex
        let needle = "<\(name)"
        while result.count < 80,
              let start = html.range(of: needle, options: .caseInsensitive, range: searchFrom..<html.endIndex),
              let end = html.range(of: ">", range: start.lowerBound..<html.endIndex) {
            result.append(String(html[start.lowerBound...end.lowerBound]))
            searchFrom = end.upperBound
        }
        return result
    }

    private static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(tag)
        var i = 0
        func skipWS() {
            while i < chars.count && chars[i].isWhitespace { i += 1 }
        }
        while i < chars.count && chars[i] != " " && chars[i] != "\n" && chars[i] != "\t" && chars[i] != ">" {
            i += 1
        }
        while i < chars.count {
            skipWS()
            guard i < chars.count, chars[i] != "/", chars[i] != ">" else { break }
            let nameStart = i
            while i < chars.count && chars[i] != "=" && !chars[i].isWhitespace && chars[i] != ">" {
                i += 1
            }
            let name = String(chars[nameStart..<i]).lowercased()
            skipWS()
            var value = ""
            if i < chars.count && chars[i] == "=" {
                i += 1
                skipWS()
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    let valueStart = i
                    while i < chars.count && chars[i] != quote { i += 1 }
                    value = String(chars[valueStart..<i])
                    if i < chars.count { i += 1 }
                } else {
                    let valueStart = i
                    while i < chars.count && !chars[i].isWhitespace && chars[i] != ">" { i += 1 }
                    value = String(chars[valueStart..<i])
                }
            }
            if !name.isEmpty { result[name] = value }
        }
        return result
    }

    private static func resolve(_ raw: String?, base: URL) -> URL? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("//"), let scheme = base.scheme {
            trimmed = "\(scheme):\(trimmed)"
        }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    private static func stripTags(_ text: String?) -> String? {
        guard var text else { return nil }
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: ""
            )
        }
        text = unescape(text)
        return text
    }

    private static func unescape(_ raw: String) -> String {
        var result = raw
        let named: [(String, String)] = [
            ("&nbsp;", " "),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&amp;", "&")
        ]
        // Ampersand last so double-encoded sequences still resolve.
        for (entity, replacement) in named where entity != "&amp;" {
            result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);", options: .caseInsensitive) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let full = Range(match.range, in: result),
                      let body = Range(match.range(at: 1), in: result) else { continue }
                let token = String(result[body])
                let value: Int?
                if token.lowercased().hasPrefix("x") {
                    value = Int(token.dropFirst(), radix: 16)
                } else {
                    value = Int(token)
                }
                if let value, let scalar = UnicodeScalar(value) {
                    result.replaceSubrange(full, with: String(Character(scalar)))
                }
            }
        }
        result = result.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        return result
    }
}

private enum LinkPreviewHTMLLimits {
    static let headChars = 200_000
}

