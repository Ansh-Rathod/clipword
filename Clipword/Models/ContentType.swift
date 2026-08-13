import Foundation

enum ContentType: String, Codable, CaseIterable {
    case text, rtf, html, image, file

    var label: String {
        switch self {
        case .text: "Text"
        case .rtf: "Rich Text"
        case .html: "HTML"
        case .image: "Image"
        case .file: "File"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "doc.text"
        case .rtf: "doc.richtext"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .file: "doc"
        }
    }
}
