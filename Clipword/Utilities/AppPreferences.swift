import Defaults
import Foundation

enum PopupPosition: String, CaseIterable, Defaults.Serializable, Identifiable {
    case cursor, menuBar, center, lastPosition

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cursor: "At cursor"
        case .menuBar: "At menu bar"
        case .center: "Screen center"
        case .lastPosition: "Last position"
        }
    }
}

enum PinPosition: String, CaseIterable, Defaults.Serializable, Identifiable {
    case top, bottom

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum SortOrder: String, CaseIterable, Defaults.Serializable, Identifiable {
    case lastCopied, firstCopied, copyCount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastCopied: "Last copied"
        case .firstCopied: "First copied"
        case .copyCount: "Copy count"
        }
    }
}

/// How long history is kept before unpinned entries are pruned.
enum HistoryRetention: String, CaseIterable, Defaults.Serializable, Identifiable {
    case day, week, month, threeMonths, sixMonths, year, unlimited

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: "A Day"
        case .week: "A Week"
        case .month: "A Month"
        case .threeMonths: "3 Months"
        case .sixMonths: "6 Months"
        case .year: "A Year"
        case .unlimited: "Unlimited"
        }
    }

    /// Items older than this are pruned; `nil` means keep everything.
    var cutoffDate: Date? {
        guard self != .unlimited else { return nil }
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .day: return calendar.date(byAdding: .day, value: -1, to: now)
        case .week: return calendar.date(byAdding: .day, value: -7, to: now)
        case .month: return calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: now)
        case .year: return calendar.date(byAdding: .year, value: -1, to: now)
        case .unlimited: return nil
        }
    }
}

enum SearchMode: String, CaseIterable, Defaults.Serializable, Identifiable {
    case exact, fuzzy, regex, mixed

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

extension Defaults.Keys {
    static let launchAtLogin = Key<Bool>("launchAtLogin", default: false)
    static let pasteAutomatically = Key<Bool>("pasteAutomatically", default: true)
    static let pasteWithoutFormatting = Key<Bool>("pasteWithoutFormatting", default: false)
    static let searchMode = Key<SearchMode>("searchMode", default: .mixed)
    static let popupPosition = Key<PopupPosition>("popupPosition", default: .center)
    /// Serialized `NSRect` of the last panel frame, used when `popupPosition` is `.lastPosition`.
    static let popupLastFrame = Key<String>("popupLastFrame", default: "")
    static let pinPosition = Key<PinPosition>("pinPosition", default: .top)
    static let imageMaxHeight = Key<Double>("imageMaxHeight", default: 40)
    static let autoPreview = Key<Bool>("autoPreview", default: true)
    static let autoPreviewDelay = Key<Double>("autoPreviewDelay", default: 1.5)
    static let showAppIcons = Key<Bool>("showAppIcons", default: true)
    static let showFooter = Key<Bool>("showFooter", default: true)
    static let showSearchField = Key<Bool>("showSearchField", default: true)
    static let showFilterSidebar = Key<Bool>("showFilterSidebar", default: false)
    static let saveText = Key<Bool>("saveText", default: true)
    static let saveImages = Key<Bool>("saveImages", default: true)
    static let saveFiles = Key<Bool>("saveFiles", default: true)
    /// Fetch Open Graph title/thumbnail when viewing a copied link.
    static let loadLinkPreviews = Key<Bool>("loadLinkPreviews", default: true)
    static let historySize = Key<Int>("historySize", default: 200)
    static let historyRetention = Key<HistoryRetention>("historyRetention", default: .unlimited)
    static let sortOrder = Key<SortOrder>("sortOrder", default: .lastCopied)
    /// Bundle IDs seeded into `ignoredApps` on fresh installs (and, once, via
    /// `migrateDefaultsIfNeeded` for installs that predate the non-empty default).
    static let defaultIgnoredAppBundleIDs: [String] = [
        "com.apple.Passwords",
        "com.apple.keychainaccess"
    ]
    static let ignoredApps = Key<[String]>("ignoredApps", default: defaultIgnoredAppBundleIDs)
    /// One-time migration: seed the default ignored apps on first launch (also
    /// covers installs that predate the non-empty default).
    static let didSetDefaultIgnoredApps = Key<Bool>("didSetDefaultIgnoredApps", default: false)
    static let allowedAppsOnly = Key<Bool>("allowedAppsOnly", default: false)
    static let ignoredPasteboardTypes = Key<[String]>("ignoredPasteboardTypes", default: [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType"
    ])
    static let ignoredRegexPatterns = Key<[String]>("ignoredRegexPatterns", default: [])
    static let ignoreEvents = Key<Bool>("ignoreEvents", default: false)
    static let ignoreNextEvent = Key<Bool>("ignoreNextEvent", default: false)
    static let clearOnQuit = Key<Bool>("clearOnQuit", default: false)
    static let clearSystemClipboard = Key<Bool>("clearSystemClipboard", default: false)
    static let clipboardCheckInterval = Key<Double>("clipboardCheckInterval", default: 0.5)
    /// Legacy category migration ran at least once on this install (persisted so
    /// launch never re-decodes every item's blob).
    static let didBackfillCategories = Key<Bool>("didBackfillCategories", default: false)
    /// Migration flags
    static let didRemoveLegacyOptionHotkeys = Key<Bool>("didRemoveLegacyOptionHotkeys", default: false)
}
