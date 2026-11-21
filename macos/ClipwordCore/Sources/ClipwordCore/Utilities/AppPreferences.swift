import Defaults
import Foundation

public extension UserDefaults {
    /// Shared suite for the Swift app (`com.clipword.app`) and Flutter host.
    static var clipword: UserDefaults {
        UserDefaults(suiteName: "com.clipword.app") ?? .standard
    }
}

public enum PopupPosition: String, CaseIterable, Defaults.Serializable, Identifiable {
    case cursor, menuBar, center, lastPosition

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cursor: "At cursor"
        case .menuBar: "At menu bar"
        case .center: "Screen center"
        case .lastPosition: "Last position"
        }
    }
}

public enum PinPosition: String, CaseIterable, Defaults.Serializable, Identifiable {
    case top, bottom

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public enum SortOrder: String, CaseIterable, Defaults.Serializable, Identifiable {
    case lastCopied, firstCopied, copyCount

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .lastCopied: "Last copied"
        case .firstCopied: "First copied"
        case .copyCount: "Copy count"
        }
    }
}

/// Count cap for unpinned history. `0` means keep every item.
public enum HistorySize {
    public static let unlimited = 0
    public static let presets = [unlimited, 100, 200, 500, 1000]

    public static func isUnlimited(_ value: Int) -> Bool { value <= 0 }

    public static func label(_ value: Int) -> String {
        isUnlimited(value) ? "Unlimited" : "\(value)"
    }
}

/// On-disk home for history, bookmarks, and caches. Uses the real user
/// Application Support folder (not the app bundle / sandbox container) so
/// deleting Clipword does not delete clipboard history.
public enum AppSupport {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clipword", isDirectory: true)
    }

    public static var storeURL: URL {
        directory.appendingPathComponent("Storage.sqlite")
    }
}

/// How long history is kept before unpinned entries are pruned.
public enum HistoryRetention: String, CaseIterable, Defaults.Serializable, Identifiable {
    case day, week, month, threeMonths, sixMonths, year, unlimited

    public var id: String { rawValue }

    public var label: String {
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
    public var cutoffDate: Date? {
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

public enum SearchMode: String, CaseIterable, Defaults.Serializable, Identifiable {
    case exact, fuzzy, regex, mixed

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }
}

public extension Defaults.Keys {
    public static let launchAtLogin = Key<Bool>("launchAtLogin", default: false, suite: .clipword)
    public static let pasteAutomatically = Key<Bool>("pasteAutomatically", default: true, suite: .clipword)
    public static let pasteWithoutFormatting = Key<Bool>("pasteWithoutFormatting", default: false, suite: .clipword)
    public static let searchMode = Key<SearchMode>("searchMode", default: .mixed, suite: .clipword)
    public static let popupPosition = Key<PopupPosition>("popupPosition", default: .center, suite: .clipword)
    /// Serialized `NSRect` of the last panel frame, used when `popupPosition` is `.lastPosition`.
    public static let popupLastFrame = Key<String>("popupLastFrame", default: "", suite: .clipword)
    /// Bookmark folders the user collapsed. Shared by the Swift and Flutter palettes.
    public static let collapsedFolderIDs = Key<[String]>("collapsedFolderIDs", default: [], suite: .clipword)
    public static let pinPosition = Key<PinPosition>("pinPosition", default: .top, suite: .clipword)
    public static let imageMaxHeight = Key<Double>("imageMaxHeight", default: 40, suite: .clipword)
    public static let autoPreview = Key<Bool>("autoPreview", default: true, suite: .clipword)
    public static let autoPreviewDelay = Key<Double>("autoPreviewDelay", default: 1.5, suite: .clipword)
    public static let showAppIcons = Key<Bool>("showAppIcons", default: true, suite: .clipword)
    public static let showFooter = Key<Bool>("showFooter", default: true, suite: .clipword)
    public static let showSearchField = Key<Bool>("showSearchField", default: true, suite: .clipword)
    public static let showFilterSidebar = Key<Bool>("showFilterSidebar", default: false, suite: .clipword)
    public static let saveText = Key<Bool>("saveText", default: true, suite: .clipword)
    public static let saveImages = Key<Bool>("saveImages", default: true, suite: .clipword)
    public static let saveFiles = Key<Bool>("saveFiles", default: true, suite: .clipword)
    /// Fetch Open Graph title/thumbnail when viewing a copied link.
    public static let loadLinkPreviews = Key<Bool>("loadLinkPreviews", default: true, suite: .clipword)
    /// `0` is unlimited (keep every item). Positive values cap unpinned history.
    public static let historySize = Key<Int>("historySize", default: HistorySize.unlimited, suite: .clipword)
    public static let historyRetention = Key<HistoryRetention>("historyRetention", default: .unlimited, suite: .clipword)
    public static let sortOrder = Key<SortOrder>("sortOrder", default: .lastCopied, suite: .clipword)
    /// Bundle IDs seeded into `ignoredApps` on fresh installs (and, once, via
    /// `migrateDefaultsIfNeeded` for installs that predate the non-empty default).
    public static let defaultIgnoredAppBundleIDs: [String] = [
        "com.apple.Passwords",
        "com.apple.keychainaccess"
    ]
    public static let ignoredApps = Key<[String]>("ignoredApps", default: defaultIgnoredAppBundleIDs, suite: .clipword)
    /// One-time migration: seed the default ignored apps on first launch (also
    /// covers installs that predate the non-empty default).
    public static let didSetDefaultIgnoredApps = Key<Bool>("didSetDefaultIgnoredApps", default: false, suite: .clipword)
    public static let allowedAppsOnly = Key<Bool>("allowedAppsOnly", default: false, suite: .clipword)
    public static let ignoredPasteboardTypes = Key<[String]>("ignoredPasteboardTypes", default: [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType"
    ], suite: .clipword)
    public static let ignoredRegexPatterns = Key<[String]>("ignoredRegexPatterns", default: [], suite: .clipword)
    public static let ignoreEvents = Key<Bool>("ignoreEvents", default: false, suite: .clipword)
    public static let ignoreNextEvent = Key<Bool>("ignoreNextEvent", default: false, suite: .clipword)
    public static let clearOnQuit = Key<Bool>("clearOnQuit", default: false, suite: .clipword)
    public static let clearSystemClipboard = Key<Bool>("clearSystemClipboard", default: false, suite: .clipword)
    public static let clipboardCheckInterval = Key<Double>("clipboardCheckInterval", default: 0.5, suite: .clipword)
    /// Legacy category migration ran at least once on this install (persisted so
    /// launch never re-decodes every item's blob).
    public static let didBackfillCategories = Key<Bool>("didBackfillCategories", default: false, suite: .clipword)
    /// HTML copies of a URL used to be stored as styled text; one-shot reclass.
    public static let didReclassifyHTMLLinks = Key<Bool>("didReclassifyHTMLLinks", default: false, suite: .clipword)
}
