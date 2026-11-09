import AppKit
import ApplicationServices

/// Whether Notification Center's panel is out, for a click that would toggle it. DESIGN.md §8.
///
/// The window server cannot say on its own: one full-screen window at a level of its own holds
/// the panel and the banners alike, and is on screen for either. What tells them apart is in the
/// accessibility tree, where only the panel has the Edit Widgets button (macOS 27). So the cheap
/// question goes first, and an ordinary open never pays for the second.
///
/// Anything unexpected answers "not open", which sends the shortcut as it would have been sent.
@MainActor
enum NotificationCenterPanel {
    private static let bundleID = "com.apple.notificationcenterui"
    /// Named, not localized, and there with or without any notifications in the list.
    private static let panelOnly = "widget-editor-button"
    /// Window, hosting view, group, scroll area, button.
    private static let panelOnlyDepth = 4
    /// This runs on the main actor, so a hung Notification Center must not hold the bar for the
    /// six seconds accessibility calls wait by default.
    private static let timeout: Float = 0.25

    static var isOpen: Bool {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.processIdentifier,
              hasWindowUp(pid) else { return false }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, timeout)
        return elements(of: application, kAXWindowsAttribute).contains { window in
            string(of: window, kAXSubroleAttribute) == kAXSystemDialogSubrole
                && holdsPanelOnly(window, depth: panelOnlyDepth)
        }
    }

    /// Above the desktop, which leaves out the widgets it keeps on the wallpaper.
    private static func hasWindowUp(_ pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { entry in
            (entry[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (entry[kCGWindowLayer as String] as? Int ?? 0) > 0
        }
    }

    private static func holdsPanelOnly(_ element: AXUIElement, depth: Int) -> Bool {
        AXUIElementSetMessagingTimeout(element, timeout)
        if string(of: element, kAXIdentifierAttribute) == panelOnly { return true }
        guard depth > 0 else { return false }
        return elements(of: element, kAXChildrenAttribute).contains {
            holdsPanelOnly($0, depth: depth - 1)
        }
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func elements(of element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
