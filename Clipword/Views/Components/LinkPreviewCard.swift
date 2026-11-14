import AppKit
import Defaults
import SwiftUI

/// Detail-pane preview for a copied URL: thumbnail, title, description, and
/// site. Loads on appear and reads from `LinkPreviewService`'s cache after
/// the first fetch.
struct LinkPreviewCard: View {
    let url: URL
    let fallbackText: String
    var charCount: Int = 0
    var scrollStore: PaletteScrollStore? = nil
    var scrollKey: String? = nil
    var restoreToken: Int = 0

    @Default(.loadLinkPreviews) private var loadLinkPreviews
    @State private var record: LinkPreviewRecord?
    @State private var loading = true

    var body: some View {
        Group {
            if !loadLinkPreviews || showFallback {
                TextPreviewPane(
                    text: fallbackText,
                    charCount: charCount,
                    scrollStore: scrollStore,
                    scrollKey: scrollKey,
                    restoreToken: restoreToken
                )
            } else {
                ScrollView {
                    card
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .persistScrollOffsetIfPossible(
                    store: scrollStore,
                    key: scrollKey,
                    restoreToken: restoreToken
                )
            }
        }
        .task(id: url.absoluteString) {
            await loadPreview(reset: true)
        }
        .onChange(of: loadLinkPreviews) { _, enabled in
            if enabled {
                Task { await loadPreview(reset: true) }
            }
        }
    }

    private var showFallback: Bool {
        !loading && (record == nil || record?.failed == true)
    }

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let data = record?.imageData, let image = NSImage(data: data) {
                Button(action: openURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .center)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("Open in Browser")
            } else if loading {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .frame(maxWidth: .infinity)
                        .frame(height: 140)
                    ProgressView()
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let data = record?.iconData, let icon = NSImage(data: data) {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 14, height: 14)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        Image(systemName: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(record?.siteName ?? url.host ?? url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let title = record?.title, !title.isEmpty {
                    Text(title)
                        .font(.headline)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let detail = record?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: openURL) {
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .buttonStyle(.plain)
                .help("Open in Browser")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func loadPreview(reset: Bool) async {
        guard loadLinkPreviews else {
            loading = false
            record = nil
            return
        }
        if reset {
            record = nil
            loading = true
        }
        let loaded = await LinkPreviewService.shared.preview(for: url)
        guard !Task.isCancelled else { return }
        record = loaded
        loading = false
    }

    private func openURL() {
        NSWorkspace.shared.open(url)
    }
}

private extension View {
    @ViewBuilder
    func persistScrollOffsetIfPossible(
        store: PaletteScrollStore?,
        key: String?,
        restoreToken: Int
    ) -> some View {
        if let store, let key {
            persistScrollOffset(store: store, key: key, restoreToken: restoreToken)
        } else {
            self
        }
    }
}
