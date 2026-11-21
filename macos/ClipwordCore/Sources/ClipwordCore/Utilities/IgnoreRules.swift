import AppKit
import Defaults
import Foundation

struct IgnoreRules {
  static func shouldIgnore(pasteboard: NSPasteboard, plainText: String?) -> Bool {
    if Defaults[.ignoreEvents] { return true }
    if Defaults[.ignoreNextEvent] {
      Defaults[.ignoreNextEvent] = false
      return true
    }

    if pasteboard.string(forType: PasteboardTypes.clipwordMarker) != nil {
      return true
    }

    let ignoredTypes = Set(Defaults[.ignoredPasteboardTypes] + PasteboardTypes.defaultIgnoredTypes)
    for type in pasteboard.types ?? [] {
      if ignoredTypes.contains(type.rawValue) { return true }
    }

    if let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
      let ignoredApps = Defaults[.ignoredApps]
      if Defaults[.allowedAppsOnly] {
        if !ignoredApps.isEmpty, !ignoredApps.contains(bundleId) { return true }
      } else if ignoredApps.contains(bundleId) {
        return true
      }
    }

    if let plainText {
      for pattern in Defaults[.ignoredRegexPatterns] where !pattern.isEmpty {
        if let regex = try? NSRegularExpression(pattern: pattern),
           regex.firstMatch(in: plainText, range: NSRange(plainText.startIndex..., in: plainText)) != nil {
          return true
        }
      }
    }

    return false
  }

  static func shouldSave(snapshot: PasteboardSnapshot) -> Bool {
    switch snapshot.contentType {
    case .text, .rtf, .html: return Defaults[.saveText]
    case .image: return Defaults[.saveImages]
    case .file: return Defaults[.saveFiles]
    }
  }
}
