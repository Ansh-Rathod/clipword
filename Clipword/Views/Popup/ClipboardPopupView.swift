import AppKit
import SwiftUI

struct ClipboardDetailPane: View {
    @Environment(AppState.self) private var appState
    @Environment(HistoryStore.self) private var historyStore
    let item: HistoryItem
    var onEdit: () -> Void = {}
    var onNewFolder: () -> Void = {}

    @State private var copyFlash = false
    @State private var pasteFlash = false
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            contentPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            Divider()

            ScrollView {
                informationSection
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .persistScrollOffset(
                store: appState.scrollStore,
                key: PaletteScrollKey.info(item.id),
                restoreToken: appState.windowPresentationToken
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // actionButtons
            //     .padding(.horizontal, 20)
            //     .padding(.bottom, 16)
            //     .padding(.top, 8)
        }
        .onChange(of: historyStore.lastAction?.token) { _, _ in
            flashMatchingAction()
        }
        .onChange(of: item.id) { _, _ in
            copyFlash = false
            pasteFlash = false
            flashTask?.cancel()
        }
        .onDisappear { flashTask?.cancel() }
    }

    @ViewBuilder
    private var contentPreview: some View {
        if item.contentType == .image, let data = item.imageData {
            ScrollView {
                DetailImagePreview(id: item.id, data: data)
            }
            .persistScrollOffset(
                store: appState.scrollStore,
                key: PaletteScrollKey.preview(item.id),
                restoreToken: appState.windowPresentationToken
            )
        } else if let url = ContentClassifier.linkPreviewURL(from: item.plainText) {
            LinkPreviewCard(
                url: url,
                fallbackText: item.plainText ?? url.absoluteString,
                charCount: item.charCount,
                scrollStore: appState.scrollStore,
                scrollKey: PaletteScrollKey.preview(item.id),
                restoreToken: appState.windowPresentationToken
            )
        } else if let text = item.plainText, !text.isEmpty {
            TextPreviewPane(
                text: text,
                charCount: item.charCount,
                scrollStore: appState.scrollStore,
                scrollKey: PaletteScrollKey.preview(item.id),
                restoreToken: appState.windowPresentationToken
            )
        } else {
            ScrollView {
                Text(item.displayTitle)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .persistScrollOffset(
                store: appState.scrollStore,
                key: PaletteScrollKey.preview(item.id),
                restoreToken: appState.windowPresentationToken
            )
        }
    }

    private var informationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Information")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            infoRow("Source") {
                HStack(spacing: 6) {
                    AppIconView(bundleId: item.applicationBundleId, size: 14)
                    Text(appName(for: item.applicationBundleId))
                }
            }
            infoRow("Content type") {
                Text(contentTypeLabel)
            }
            if let url = ContentClassifier.linkPreviewURL(from: item.plainText) {
                infoRow("Address") {
                    Button(url.absoluteString) {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help("Open in Browser")
                }
            }
            infoRow("Characters") {
                Text("\(item.charCount)")
            }
            infoRow("Words") {
                Text("\(item.wordCount)")
            }
            infoRow("Copies") {
                Text("\(item.copyCount)")
            }
            infoRow("Pastes") {
                Text("\(item.pasteCount)")
            }

            activitySection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /*
    private var actionButtons: some View {
        LiquidGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                DetailIconButton(
                    systemName: "doc.on.doc",
                    help: "Copy",
                    tint: copyFlash ? .green : nil,
                    flashSuccess: copyFlash
                ) {
                    historyStore.select(item, paste: false)
                }
                DetailIconButton(
                    systemName: "text.insert",
                    help: "Paste into focused field",
                    tint: pasteFlash ? .green : nil,
                    flashSuccess: pasteFlash
                ) {
                    historyStore.select(item, paste: true)
                    appState.hideWindow()
                }
                DetailIconButton(
                    systemName: "pencil",
                    help: "Edit",
                    action: onEdit
                )
                DetailIconButton(
                    systemName: item.isBookmarked ? "bookmark.fill" : "bookmark",
                    help: item.isBookmarked ? "Remove Bookmark" : "Bookmark",
                    tint: item.isBookmarked ? .accentColor : nil,
                    isActive: item.isBookmarked
                ) {
                    historyStore.toggleBookmark(item)
                }
                DetailIconButton(
                    systemName: "folder.badge.plus",
                    help: folderButtonHelp,
                    tint: historyStore.folder(forHistoryItem: item) != nil ? .accentColor : nil,
                    isActive: historyStore.folder(forHistoryItem: item) != nil
                ) {
                    showFolderMenu()
                }
                DetailIconButton(
                    systemName: item.isPinned ? "pin.fill" : "pin",
                    help: item.isPinned ? "Unpin" : "Pin",
                    tint: item.isPinned ? .orange : nil,
                    isActive: item.isPinned
                ) {
                    historyStore.togglePin(item)
                }
                Spacer()
            }
        }
    }
    */

    @ViewBuilder
    private var activitySection: some View {
        let events = item.activityTimeline
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if events.contains(where: \.isSynthesized), item.copyCount > events.filter({ $0.kind == .copied }).count {
                Text("Older copies were counted but not logged individually.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(events) { event in
                    HStack(spacing: 8) {
                        Image(systemName: event.kind.systemImage)
                            .frame(width: 14)
                            .foregroundStyle(.secondary)
                        Text(event.kind.label)
                        if let bundleId = event.applicationBundleId {
                            Text(appName(for: bundleId))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(copiedLabel(for: event.date))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.top, 4)
    }

    private var folderButtonHelp: String {
        if let folder = historyStore.folder(forHistoryItem: item) {
            return "In “\(folder.name)” — move or add to another folder"
        }
        return "Add to folder"
    }

    private func showFolderMenu() {
        KeyboardContextMenu.popFolderMenu(
            folders: historyStore.folders.map { ($0.id, $0.name) },
            currentFolderID: historyStore.folder(forHistoryItem: item)?.id,
            includeUnfiled: item.isBookmarked,
            select: { id in
                if let id, let folder = historyStore.folder(id: id) {
                    historyStore.bookmark(item, in: folder)
                } else {
                    historyStore.bookmark(item, in: nil)
                }
            },
            newFolder: onNewFolder
        )
    }

    private func flashMatchingAction() {
        guard let action = historyStore.lastAction, action.itemID == item.id else { return }
        flashTask?.cancel()
        switch action.kind {
        case .copied:
            copyFlash = true
            pasteFlash = false
        case .pasted:
            pasteFlash = true
            copyFlash = false
        default:
            return
        }
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            copyFlash = false
            pasteFlash = false
        }
    }

    private func infoRow<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
        .font(.body)
    }

    private var contentTypeLabel: String {
        if item.category == .link || ContentClassifier.isLinkText(item.plainText) { return "Link" }
        switch item.contentType {
        case .text: return item.category == .styledText ? "Text (Formatted)" : "Text"
        case .rtf: return "Text (Formatted)"
        case .html: return "HTML"
        case .image: return "Image"
        case .file: return "File"
        }
    }

    private func copiedLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .standard)
        if calendar.isDateInToday(date) {
            return "Today at \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday at \(time)"
        }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func appName(for bundleId: String?) -> String {
        guard let bundleId, bundleId != "unknown" else { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId
    }
}

struct EditContentSheet: View {
    @Environment(HistoryStore.self) private var historyStore
    @Environment(\.dismiss) private var dismiss
    let item: HistoryItem
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Content")
                .font(.headline)
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .frame(minWidth: 420, minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    historyStore.updateContent(item, content: draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .onAppear { draft = item.plainText ?? "" }
    }
}
