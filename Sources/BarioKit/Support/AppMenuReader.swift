import ApplicationServices
import QuartzCore

/// Reads another app's menu bar through Accessibility, and presses its
/// items. Every app's menu bar is in its accessibility tree: `AXMenuBar` on the
/// application, its `AXMenuBarItem`s (the Apple menu first), each holding one `AXMenu` of
/// `AXMenuItem`s, an item's submenu being its one `AXMenu` child.
///
/// Measured on macOS 27: the whole tree but the Apple menu is 5–11 ms for Ghostty and Finder;
/// the Apple menu's Recent Items is the expensive part, and is left out. Calls are synchronous
/// messages to the app, so each has a short timeout and the whole read a deadline: an app that
/// is busy costs a menu that opens a little late or not at all, never a bar that stops.
enum AppMenuReader {
    /// What one read found: the menus, and the element behind every item, by its path, with the
    /// titles on the way to it, to find it again if it goes stale before it is pressed.
    struct Read {
        var menus: [AppMenuItem] = []
        var elements: [[Int]: AXUIElement] = [:]
        var titles: [[Int]: [String]] = [:]
    }

    enum Failure: Error, Equatable {
        /// The app has no menu bar to read: nothing opens.
        case noMenuBar
        /// It did not answer in time.
        case notResponding
    }

    /// Each message to the app, which is waited on.
    static let timeout: Float = 0.1
    /// The whole read. What it has read by then is what shows.
    static let deadline: CFTimeInterval = 0.15

    /// Read in one message per item.
    private static let attributes = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemCmdCharAttribute,
                                     kAXMenuItemCmdModifiersAttribute, kAXMenuItemCmdGlyphAttribute,
                                     kAXMenuItemMarkCharAttribute, kAXChildrenAttribute]

    /// Whether bario may read other apps, asking macOS to say so to the user the first time.
    static func isTrusted(prompting: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompting] as CFDictionary)
    }

    /// The app's menus, the Apple menu left out.
    static func read(pid: pid_t) -> Result<Read, Failure> {
        let end = CACurrentMediaTime() + deadline
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: AnyObject?
        switch AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &value) {
        case .success:
            break
        case .cannotComplete:
            return .failure(.notResponding)
        default:
            return .failure(.noMenuBar)
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failure(.noMenuBar) }
        let bar = value as! AXUIElement
        var read = Read()
        for (index, top) in children(of: bar).enumerated().dropFirst() {
            guard CACurrentMediaTime() < end else { break }
            let title = string(of: top, kAXTitleAttribute) ?? ""
            let items = children(of: top).first.map { items(in: $0, path: [index], titles: [title], into: &read, until: end) }
            read.menus.append(AppMenuItem(title, submenu: items ?? [], path: [index]))
        }
        return read.menus.isEmpty ? .failure(.noMenuBar) : .success(read)
    }

    private static func items(in menu: AXUIElement, path: [Int], titles: [String], into read: inout Read,
                              until end: CFTimeInterval) -> [AppMenuItem] {
        var found: [AppMenuItem] = []
        for (index, element) in children(of: menu).enumerated() {
            guard CACurrentMediaTime() < end else { break }
            AXUIElementSetMessagingTimeout(element, timeout)
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values) == .success,
                  let list = values as? [AnyObject], list.count == 7 else { continue }
            // A missing attribute comes back as an error value in its place.
            let field = { (i: Int) -> AnyObject? in CFGetTypeID(list[i]) == AXValueGetTypeID() ? nil : list[i] }
            let title = field(0) as? String ?? ""
            let here = path + [index]
            var item = AppMenuItem(title, enabled: field(1) as? Bool ?? false, mark: field(5) as? String,
                                   shortcut: MenuShortcut(character: field(2) as? String, glyph: field(4) as? Int,
                                                          modifiers: field(3) as? Int ?? 0),
                                   path: here)
            if item.mark?.isEmpty == true { item.mark = nil }
            if let submenu = (field(6) as? [AXUIElement])?.first {
                item.submenu = items(in: submenu, path: here, titles: titles + [title], into: &read, until: end)
            }
            read.elements[here] = element
            read.titles[here] = titles + [title]
            found.append(item)
        }
        return found
    }

    /// Press an item, waiting no longer than `wait` for the app to say it has: an item that opens
    /// a modal answers only once the modal ends.
    static func press(_ element: AXUIElement, wait: Float = 1) -> AXError {
        AXUIElementSetMessagingTimeout(element, wait)
        return AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    /// The item at the end of a path of titles, in a fresh read: for an element that went stale
    /// between the read that showed it and its press.
    static func find(_ titles: [String], pid: pid_t) -> AXUIElement? {
        guard case .success(let read) = read(pid: pid) else { return nil }
        return read.titles.first { $0.value == titles }.flatMap { read.elements[$0.key] }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// An element carried to the task that presses it. Accessibility elements are references to
/// another process's objects, safe to message from any thread.
struct PressableElement: @unchecked Sendable {
    let element: AXUIElement
}
