import Foundation

/// One item of an app's menu bar, as `AppMenuReader` read it. A
/// top-level menu is one too, with its items as its submenu.
public struct AppMenuItem: Sendable, Equatable {
    public var title: String
    public var enabled: Bool
    /// What the menu puts beside it: ✓ when it is on, – when it is mixed.
    public var mark: String?
    public var shortcut: MenuShortcut?
    /// Its submenu's items, if it has one.
    public var submenu: [AppMenuItem]?
    /// Where it was read, by index among its siblings from the menu bar down: what `press`
    /// names it by.
    public var path: [Int]

    public init(_ title: String, enabled: Bool = true, mark: String? = nil, shortcut: MenuShortcut? = nil,
                submenu: [AppMenuItem]? = nil, path: [Int] = []) {
        self.title = title
        self.enabled = enabled
        self.mark = mark
        self.shortcut = shortcut
        self.submenu = submenu
        self.path = path
    }

    /// A line between groups: no title, nothing under it, no shortcut.
    public var isSeparator: Bool { title.isEmpty && submenu == nil && shortcut == nil }
}

/// A menu item's keyboard shortcut, as the menu writes it: ⌃⌥⇧⌘ and then the key.
public struct MenuShortcut: Sendable, Equatable {
    /// The key as it prints: `N`, `⇥`, `↑`, `F5`.
    public var key: String
    public var shift = false
    public var option = false
    public var control = false
    public var command = true
    /// The fn (globe) key.
    public var function = false

    public init(key: String, shift: Bool = false, option: Bool = false, control: Bool = false,
                command: Bool = true, function: Bool = false) {
        self.key = key
        self.shift = shift
        self.option = option
        self.control = control
        self.command = command
        self.function = function
    }

    /// From what Accessibility says: the key's character, its glyph from the Carbon menu-glyph
    /// table when it has no character worth printing, and the modifiers as a bit field (1 Shift,
    /// 2 Option, 4 Control, 8 *no* Command, 16 fn). nil when there is no key.
    public init?(character: String?, glyph: Int?, modifiers: Int) {
        guard let key = MenuShortcut.printable(character: character, glyph: glyph) else { return nil }
        self.init(key: key, shift: modifiers & 1 != 0, option: modifiers & 2 != 0,
                  control: modifiers & 4 != 0, command: modifiers & 8 == 0, function: modifiers & 16 != 0)
    }

    /// As the menu shows it: `⌥⇧⌘W`, `⌃⇥`, `fn F`.
    public var text: String {
        var text = function ? "fn " : ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + key
    }

    /// The key, whatever its case: what an Option variant shares with its item.
    var keyIdentity: String { key.lowercased() }

    static func printable(character: String?, glyph: Int?) -> String? {
        if let glyph, glyph != 0, let printed = glyphs[glyph] { return printed }
        guard let character, let scalar = character.unicodeScalars.first else { return nil }
        if let printed = specials[scalar.value] { return printed }
        // NSF1FunctionKey on: F1 to F35.
        if (0xF704...0xF726).contains(scalar.value) { return "F\(scalar.value - 0xF704 + 1)" }
        // Another private-use key the table does not know prints as nothing useful.
        if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        if scalar.value < 0x20 { return nil }
        return character.uppercased()
    }

    /// The Carbon menu-glyph numbers a key comes as when its character would not print.
    static let glyphs: [Int: String] = {
        var table: [Int: String] = [
            0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x05: "⇧", 0x06: "⌃", 0x07: "⌥", 0x09: "Space",
            0x0A: "⌦", 0x0B: "↩", 0x0C: "↩", 0x0D: "↩", 0x10: "⇣", 0x11: "⌘", 0x17: "⌫",
            0x18: "⇠", 0x19: "⇡", 0x1A: "⇢", 0x1B: "⎋", 0x1C: "⌧", 0x62: "⇞", 0x63: "⇪",
            0x64: "←", 0x65: "→", 0x66: "↖", 0x68: "↑", 0x69: "↘", 0x6A: "↓", 0x6B: "⇟",
            0x6E: "⌽", 0x8C: "⏏",
        ]
        for n in 0..<12 { table[0x6F + n] = "F\(n + 1)" }
        for n in 0..<3 { table[0x87 + n] = "F\(n + 13)" }
        for n in 0..<4 { table[0x8F + n] = "F\(n + 16)" }
        return table
    }()

    /// Characters that stand for keys with no letter: Tab, Return, Escape, Delete, the arrows.
    static let specials: [UInt32: String] = [
        0x09: "⇥", 0x0D: "↩", 0x03: "⌤", 0x1B: "⎋", 0x08: "⌫", 0x7F: "⌫", 0x20: "Space",
        0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→",
        0xF728: "⌦", 0xF729: "↖", 0xF72B: "↘", 0xF72C: "⇞", 0xF72D: "⇟",
    ]
}

/// An app's menu bar made into a bario menu: pure, so what the
/// `front-app` module shows can be tested without an app or Accessibility.
public enum AppMenus {
    /// The verb a chosen item's row sends its item's module, with the item's path.
    public static let pressVerb = "press"

    /// The menu for an app's menu bar: a row per menu, the first called "App", each opening its
    /// items. nil when there is nothing to show.
    public static func menu(_ menus: [AppMenuItem], option: Bool) -> Node? {
        var rows: [Node] = []
        for (index, menu) in menus.enumerated() {
            let items = rowNodes(shown(menu.submenu ?? [], option: option), option: option)
            guard !items.isEmpty else { continue }
            let title = index == 0 ? "App" : menu.title
            rows.append(Node(.row(Container(children: [
                .text(title), .spacer(), .icon("chevron.right", classes: ["arrow"]),
            ])), actions: NodeActions(submenu: items)))
        }
        return Node.menu(rows)
    }

    /// What one menu shows, Option held or not: each Option variant in place of its item, or left
    /// out; untitled items (custom views) left out; separators never doubled or at either end.
    public static func shown(_ items: [AppMenuItem], option: Bool) -> [(item: AppMenuItem, alternate: Bool)] {
        var paired: [(item: AppMenuItem, alternate: Bool)] = []
        var index = 0
        while index < items.count {
            let item = items[index]
            if index + 1 < items.count, isAlternate(items[index + 1], of: item) {
                paired.append(option ? (items[index + 1], true) : (item, false))
                index += 2
            } else {
                paired.append((item, false))
                index += 1
            }
        }
        var shown: [(item: AppMenuItem, alternate: Bool)] = []
        for entry in paired {
            if entry.item.isSeparator {
                if let last = shown.last, !last.item.isSeparator { shown.append(entry) }
            } else if !entry.item.title.isEmpty {
                shown.append(entry)
            }
        }
        if shown.last?.item.isSeparator == true { shown.removeLast() }
        return shown
    }

    /// Tanner's rule: an item directly after another is its Option variant when it has the
    /// same key, the same modifiers and ⌥, and the same first five characters of title (all of
    /// the shorter one's, if it is shorter). ⌘H then ⌥⌘H, Hide and Hide Others, macOS shows both.
    public static func isAlternate(_ variant: AppMenuItem, of item: AppMenuItem) -> Bool {
        guard let base = item.shortcut, let other = variant.shortcut,
              base.keyIdentity == other.keyIdentity, other.option, !base.option,
              base.shift == other.shift, base.control == other.control,
              base.command == other.command, base.function == other.function else { return false }
        if base.keyIdentity == "h", base.command, !base.shift, !base.control, !base.function { return false }
        let a = Array(item.title.lowercased()), b = Array(variant.title.lowercased())
        let length = min(5, a.count, b.count)
        return length > 0 && a.prefix(length) == b.prefix(length)
    }

    /// The rows of one menu. A disabled item has no action, so it is not a control; a mark column
    /// is there only when something in the menu has a mark, so the titles line up.
    static func rowNodes(_ items: [(item: AppMenuItem, alternate: Bool)], option: Bool) -> [Node] {
        let marks = items.contains { $0.item.mark != nil }
        return items.map { entry in
            let item = entry.item
            if item.isSeparator { return .separator }
            var children: [Node] = []
            if marks { children.append(.text(item.mark ?? "", classes: ["mark"])) }
            children.append(.text(item.title))
            children.append(.spacer())
            if let shortcut = item.shortcut { children.append(.text(shortcut.text, classes: ["shortcut"])) }
            var actions = NodeActions()
            if item.enabled {
                if let submenu = item.submenu {
                    let rows = rowNodes(shown(submenu, option: option), option: option)
                    if !rows.isEmpty {
                        actions.submenu = rows
                        children.append(.icon("chevron.right", classes: ["arrow"]))
                    }
                } else {
                    actions.click = "\(pressVerb) \(item.path.map(String.init).joined(separator: "."))"
                }
            }
            var classes: [String] = []
            if !actions.isControl { classes.append("disabled") }
            if entry.alternate { classes.append("alternate") }
            return Node(.row(Container(children: children)), classes: classes, actions: actions)
        }
    }

    /// What shows when bario may not read other apps' menus: why, and the way to the setting.
    public static func needsAccess(app: String) -> Node {
        .column([
            .row([.text("Showing \(app.isEmpty ? "this app" : app)'s menus needs Accessibility")],
                 classes: ["note"]),
            .separator,
            Node(.row(Container(children: [.text("Open Accessibility Settings…")])),
                 actions: NodeActions(click: "exec open "
                     + "'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'")),
        ])
    }

    /// What shows for an app that did not answer.
    public static func notResponding(app: String) -> Node {
        .row([.text("\(app.isEmpty ? "The app" : app) is not responding")], classes: ["disabled"])
    }

    /// The path a `press` names, from its argument: `2.5.0`.
    public static func path(_ argument: String) -> [Int]? {
        let parts = argument.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }
}
