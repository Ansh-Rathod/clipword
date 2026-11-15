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

/// Limits history to clips copied in a day or an inclusive range of days.
enum HistoryTimeFilter: Equatable, Hashable {
    case any
    case today
    case yesterday
    case last7Days
    case thisMonth
    /// Inclusive calendar days, each normalized to the start of the day.
    case days(from: Date, to: Date)

    var isActive: Bool {
        if case .any = self { return false }
        return true
    }

    /// Compact toolbar title. Inactive state matches the Filter chip’s “Filter”.
    var chipTitle: String {
        switch self {
        case .any: return "When"
        default: return label
        }
    }

    var label: String {
        switch self {
        case .any: return "Any time"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last7Days: return "Last 7 days"
        case .thisMonth: return "This month"
        case .days(let from, let to):
            let calendar = Calendar.current
            if calendar.isDate(from, inSameDayAs: to) {
                return Self.sectionTitle(for: from, calendar: calendar)
            }
            return "\(Self.shortDate(from, calendar: calendar))–\(Self.shortDate(to, calendar: calendar))"
        }
    }

    func contains(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .any:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .yesterday:
            return calendar.isDateInYesterday(date)
        case .last7Days:
            let start = calendar.startOfDay(for: now)
            guard let from = calendar.date(byAdding: .day, value: -6, to: start) else { return true }
            return date >= from
        case .thisMonth:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .days(let from, let to):
            let day = calendar.startOfDay(for: date)
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.startOfDay(for: max(from, to))
            return day >= start && day <= end
        }
    }

    static func spanning(_ from: Date, to: Date, calendar: Calendar = .current) -> HistoryTimeFilter {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        return .days(from: min(start, end), to: max(start, end))
    }

    static func sectionTitle(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    private static func shortDate(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
