import SwiftUI

struct FilterSidebarView: View {
    @Environment(HistoryStore.self) private var historyStore
    @Binding var selectedFilter: FilterTag?

    var body: some View {
        List(selection: $selectedFilter) {
            Section("Type") {
                filterRow(tag: .all, label: "All", icon: "tray.full", count: historyStore.items.count)
                ForEach(ClipboardCategory.allCases) { category in
                    filterRow(
                        tag: .category(category),
                        label: category.label,
                        icon: category.systemImage,
                        count: historyStore.count(for: category)
                    )
                }
            }
            Section("App") {
                filterRow(tag: .allApps, label: "All Apps", icon: "apps.iphone", count: historyStore.items.count)
                ForEach(historyStore.availableApps) { app in
                    filterRow(
                        tag: .app(app.bundleId),
                        label: app.name,
                        icon: "app",
                        count: app.count
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        .onChange(of: selectedFilter) { _, tag in
            applyFilter(tag)
        }
    }

    @ViewBuilder
    private func filterRow(tag: FilterTag, label: String, icon: String, count: Int) -> some View {
        HStack {
            Label(label, systemImage: icon)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(tag)
    }

    private func applyFilter(_ tag: FilterTag?) {
        guard let tag else {
            historyStore.setCategoryFilter(nil)
            historyStore.setAppFilter(nil)
            return
        }
        switch tag {
        case .all:
            historyStore.setCategoryFilter(nil)
            historyStore.setAppFilter(nil)
        case .category(let category):
            historyStore.setCategoryFilter(category)
            historyStore.setAppFilter(nil)
        case .allApps:
            historyStore.setCategoryFilter(nil)
            historyStore.setAppFilter(nil)
        case .app(let bundleId):
            historyStore.setAppFilter(bundleId)
        }
    }
}
