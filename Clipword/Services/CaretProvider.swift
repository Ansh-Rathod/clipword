import AppKit
import ApplicationServices
import Foundation

/// Best-effort caret position via the Accessibility API, for anchoring the
/// inline suggestion strip under the text cursor.
///
/// All AX work happens off the main thread (a focused-element query can block
/// 5–20ms; per keystroke that's too much on main). Returns nil when the host
/// app doesn't expose a caret (Electron/Chrome often don't) or the field is
/// secure — callers fall back to anchoring near the mouse cursor.
enum CaretProvider {
    /// Reads the caret for the focused UI element. `primaryScreenHeight` is the
    /// AppKit global-space height of the screen with the menu bar, used to flip
    /// AX's top-left-origin coordinates into AppKit's bottom-left-origin space.
    static func caretRect(primaryScreenHeight: CGFloat) async -> NSRect? {
        await Task.detached(priority: .userInitiated) {
            queryCaretRect(primaryScreenHeight: primaryScreenHeight)
        }.value
    }

    nonisolated private static func queryCaretRect(primaryScreenHeight: CGFloat) -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedElement = focused else { return nil }
        let element = focusedElement as! AXUIElement

        // Never suggest in password fields (secure text is a subrole of
        // text fields, not its own role).
        var roleRef: AnyObject?
        var subroleRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success {
            let secure = kAXSecureTextFieldSubrole as String
            if roleRef as? String == secure || subroleRef as? String == secure {
                return nil
            }
        }

        // 1) Precise caret: bounds of the current selection range (a collapsed
        //    selection = the caret itself).
        var rangeRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef {
            var boundsRef: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &boundsRef
            ) == .success, let bounds = boundsRef,
               let rect = axRect(bounds) {
                return axToScreen(rect, primaryScreenHeight: primaryScreenHeight)
            }
        }

        // 2) Coarse fallback: the focused element's own frame (good enough for
        //    single-line fields; bad for tall text areas, still better than
        //    nothing).
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let position = axPoint(posRef), let size = axSize(sizeRef) {
            return axToScreen(CGRect(origin: position, size: size), primaryScreenHeight: primaryScreenHeight)
        }

        return nil
    }

    // MARK: AXValue helpers

    nonisolated private static func axRect(_ value: AnyObject) -> CGRect? {
        let axValue = value as! AXValue
        var rect = CGRect.zero
        guard AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    nonisolated private static func axPoint(_ value: AnyObject?) -> CGPoint? {
        guard let value else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    nonisolated private static func axSize(_ value: AnyObject?) -> CGSize? {
        guard let value else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// AX coordinates use a top-left origin; AppKit windows use bottom-left.
    nonisolated private static func axToScreen(_ rect: CGRect, primaryScreenHeight: CGFloat) -> NSRect? {
        guard rect.height > 0, rect.height < 4000, rect.width >= 0, rect.width < 8000 else { return nil }
        var converted = rect
        converted.origin.y = primaryScreenHeight - rect.maxY
        return converted
    }
}
