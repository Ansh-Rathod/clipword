import Foundation

enum ClipboardCategory: String, Codable, CaseIterable, Identifiable {
    case plainText, link, code, styledText, image, file, color

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plainText: "Plain Text"
        case .link: "Links"
        case .code: "Code"
        case .styledText: "Styled Text"
        case .image: "Images"
        case .file: "Files"
        case .color: "Colors"
        }
    }

    var systemImage: String {
        switch self {
        case .plainText: "doc.text"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .styledText: "doc.richtext"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }
}

struct AppFilterOption: Identifiable, Hashable {
    let bundleId: String
    let name: String
    let count: Int

    var id: String { bundleId }
}

enum FilterTag: Hashable {
    case all
    case category(ClipboardCategory)
    case allApps
    case app(String)
}
