import AppKit
import Defaults
import SwiftUI

struct HistoryRowView: View {
    let item: HistoryItem
    var emphasized: Bool = false
    var recentlyActed: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: rowIcon)
                .font(.body)
                .frame(width: 18)
                .symbolEffect(.bounce, value: recentlyActed)

            Text(item.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if item.isBookmarked {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(emphasized ? Color.white.opacity(0.95) : Color.accentColor)
                    .transition(.scale.combined(with: .opacity))
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(emphasized ? Color.white.opacity(0.95) : Color.orange)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .foregroundStyle(emphasized ? Color.white : Color.primary)
        .padding(.vertical, 2)
        .padding(.leading, 4)
        .overlay(alignment: .leading) {
            if recentlyActed {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: .leading)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: item.isBookmarked)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: item.isPinned)
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: recentlyActed)
    }

    private var rowIcon: String {
        if item.contentType == .image { return "photo" }
        if item.contentType == .file { return "doc" }
        return item.category.systemImage
    }
}
