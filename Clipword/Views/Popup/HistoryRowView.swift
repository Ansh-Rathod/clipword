import AppKit
import Defaults
import SwiftUI

struct HistoryRowView: View {
    let item: HistoryItem
    var emphasized: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: rowIcon)
                .font(.body)
                .frame(width: 18)

            Text(item.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if item.isBookmarked {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(emphasized ? Color.white.opacity(0.95) : Color.blue)
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(emphasized ? Color.white.opacity(0.95) : Color.orange)
            }
        }
        .foregroundStyle(emphasized ? Color.white : Color.primary)
        .padding(.vertical, 2)
    }

    private var rowIcon: String {
        if item.contentType == .image { return "photo" }
        if item.contentType == .file { return "doc" }
        return item.category.systemImage
    }
}
