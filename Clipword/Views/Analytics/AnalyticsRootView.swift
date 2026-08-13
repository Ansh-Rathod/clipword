import Charts
import SwiftUI

enum AnalyticsSection: String, CaseIterable, Identifiable {
    case overview, activity, topWords, typedWords, byApp, byType, pasteStats, peakHours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .activity: "Activity"
        case .topWords: "Copied Words"
        case .typedWords: "Typed Words"
        case .byApp: "By App"
        case .byType: "By Type"
        case .pasteStats: "Paste Stats"
        case .peakHours: "Peak Hours"
        }
    }
}

struct AnalyticsRootView: View {
    @Environment(AnalyticsEngine.self) private var analyticsEngine
    @Environment(\.sidebarFocused) private var sidebarFocused
    @State private var section: AnalyticsSection = .overview
    @State private var preset: TimeRangePreset = .week
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var customEnd = Date.now

    private var interval: DateInterval? {
        preset.interval(customStart: customStart, customEnd: customEnd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Section", selection: $section) {
                    ForEach(AnalyticsSection.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .focusable()

                Spacer()

                TimeRangePickerView(preset: $preset, customStart: $customStart, customEnd: $customEnd)
                    .frame(maxWidth: 420)
            }
            .padding(.horizontal)

            Group {
                switch section {
                case .overview:
                    OverviewSectionView(interval: interval)
                case .activity:
                    ActivitySectionView(interval: interval)
                case .topWords:
                    TopWordsSectionView(interval: interval, source: .clipboard)
                case .typedWords:
                    TopWordsSectionView(interval: interval, source: .typed)
                case .byApp:
                    ByAppSectionView(interval: interval)
                case .byType:
                    ByTypeSectionView(interval: interval)
                case .pasteStats:
                    PasteStatsSectionView(interval: interval)
                case .peakHours:
                    PeakHoursSectionView(interval: interval)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.vertical)
        .focusSection()
        .onKeyPress(.upArrow) {
            guard !sidebarFocused else { return .ignored }
            cycleSection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !sidebarFocused else { return .ignored }
            cycleSection(1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !sidebarFocused else { return .ignored }
            cyclePreset(1)
            return .handled
        }
    }

    private func cycleSection(_ delta: Int) {
        let all = AnalyticsSection.allCases
        guard let index = all.firstIndex(of: section) else { return }
        section = all[(index + delta + all.count) % all.count]
    }

    private func cyclePreset(_ delta: Int) {
        let all = TimeRangePreset.allCases
        guard let index = all.firstIndex(of: preset) else { return }
        preset = all[(index + delta + all.count) % all.count]
    }
}

struct OverviewSectionView: View {
    @Environment(AnalyticsEngine.self) private var analyticsEngine
    let interval: DateInterval?

    var body: some View {
        let stats = analyticsEngine.overviewStats(interval: interval)
        if stats.totalCopies == 0 && stats.typedWords == 0 {
            ContentUnavailableView("No data", systemImage: "chart.bar.xaxis", description: Text("Copy or type something to see analytics"))
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 16) {
                    StatCardView(title: "Total Copies", value: "\(stats.totalCopies)", systemImage: "doc.on.doc")
                    StatCardView(title: "Copied Words", value: "\(stats.totalWords)", systemImage: "text.word.spacing")
                    StatCardView(title: "Typed Words", value: "\(stats.typedWords)", systemImage: "keyboard")
                    StatCardView(title: "Typing Time", value: formatDuration(stats.typingSeconds), systemImage: "clock")
                    StatCardView(title: "Unique Words", value: "\(stats.uniqueWords)", systemImage: "textformat.abc")
                    StatCardView(title: "Word Reuse", value: String(format: "%.0f%%", stats.reuseRate * 100), systemImage: "arrow.triangle.2.circlepath")
                    StatCardView(title: "Total Pastes", value: "\(stats.totalPastes)", systemImage: "arrow.uturn.backward")
                    StatCardView(title: "Avg Time to Paste", value: formatDuration(stats.averageSecondsToPaste), systemImage: "timer")
                    StatCardView(title: "Avg Words/Copy", value: String(format: "%.1f", stats.averageWordsPerCopy), systemImage: "divide")
                    StatCardView(title: "Total Characters", value: "\(stats.totalChars)", systemImage: "character")
                }
                .padding()
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0s" }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins < 60 { return "\(mins)m \(secs)s" }
        let hours = mins / 60
        return "\(hours)h \(mins % 60)m"
    }
}

struct ActivitySectionView: View {
    @Environment(AnalyticsEngine.self) private var analyticsEngine
    let interval: DateInterval?

    var body: some View {
        let points = analyticsEngine.dailyActivity(interval: interval)
        if points.isEmpty {
            ContentUnavailableView("No activity", systemImage: "chart.bar.xaxis")
        } else {
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Copies", point.copies)
                    )
                    .foregroundStyle(.blue)
                    .position(by: .value("Type", "Copies"))

                    LineMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Pastes", point.pastes)
                    )
                    .foregroundStyle(.orange)

                    LineMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Typed", point.typedWords)
                    )
                    .foregroundStyle(.green)
                }
            }
            .chartForegroundStyleScale([
                "Copies": .blue,
                "Pastes": .orange,
                "Typed": .green
            ])
            .padding()
        }
    }
}

struct TopWordsSectionView: View {
    @Environment(AnalyticsEngine.self) private var analyticsEngine
    let interval: DateInterval?
    let source: WordSource

    var body: some View {
        let words = analyticsEngine.topWords(interval: interval, source: source)
        if words.isEmpty {
            ContentUnavailableView(
                source == .typed ? "No typed words yet" : "No words tracked",
                systemImage: source == .typed ? "keyboard" : "textformat.abc",
                description: Text(source == .typed ? "Enable typing analytics in Advanced settings" : "Copy some text to see word frequency")
            )
        } else {
            Table(words) {
                TableColumn("Word") { Text($0.word) }
                TableColumn("Count") { Text("\($0.count)") }
                TableColumn("Last seen") { Text($0.lastSeenAt, style: .date) }
            }
            .padding()
        }
    }
}

struct ByAppSectionView: View {
    @Environment(AnalyticsEngine.self) private var analyticsEngine
    let interval: DateInterval?

    var body: some View {
        let apps = analyticsEngine.appBreakdown(interval: interval)
        if apps.isEmpty {
            ContentUnavailableView("No app data", systemImage: "app.badge")
        } else {
            Chart(apps) { app in
                BarMark(
                    x: .value("Count", app.count),
                    y: .value("App", app.appName)
                )
            }
            .padding()
        }
    }
}

struct ByTypeSectionView: View {
    @Environment(AnalyticsEngine.self) private var analyticsEngine
    let interval: DateInterval?

    var body: some View {
        let categories = analyticsEngine.categoryBreakdown(interval: interval)
        if categories.isEmpty {
            ContentUnavailableView("No type data", systemImage: "square.grid.3x1.folder.fill.badge.plus")
        } else {
            Chart(categories) { item in
                BarMark(
                    x: .value("Count", item.count),
                    y: .value("Type", item.label)
                )
            }
            .padding()
        }
    }
}

struct PasteStatsSectionView: View {
    @Environment(AnalyticsEngine.self) private var analyticsEngine
    let interval: DateInterval?

    var body: some View {
        let rows = analyticsEngine.pasteStats(interval: interval)
        let ratio = analyticsEngine.pasteToCopyRatio
        if rows.isEmpty {
            ContentUnavailableView("No paste data", systemImage: "arrow.uturn.backward")
        } else {
            VStack(alignment: .leading, spacing: 16) {
                LabeledContent("Paste-to-copy ratio") {
                    Gauge(value: min(ratio, 1.0)) {
                        Text(String(format: "%.0f%%", ratio * 100))
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .frame(width: 200)
                }
                Table(rows) {
                    TableColumn("Item") { Text($0.title) }
                    TableColumn("Pastes") { Text("\($0.pasteCount)") }
                    TableColumn("Copies") { Text("\($0.copyCount)") }
                }
            }
            .padding()
        }
    }
}

struct PeakHoursSectionView: View {
    @Environment(AnalyticsEngine.self) private var analyticsEngine
    let interval: DateInterval?

    var body: some View {
        let points = analyticsEngine.hourlyActivity(interval: interval)
        if points.allSatisfy({ $0.copies == 0 }) {
            ContentUnavailableView("No hourly data", systemImage: "clock")
        } else {
            Chart(points) { point in
                BarMark(
                    x: .value("Hour", point.hour),
                    y: .value("Copies", point.copies)
                )
            }
            .chartXScale(domain: 0...23)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(String(format: "%02d:00", hour))
                        }
                    }
                }
            }
            .padding()
        }
    }
}
