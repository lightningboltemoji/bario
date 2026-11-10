import AppKit
import Testing
@testable import BarioKit

/// Submenus and the front app's menus: the content model, style and
/// placement, the frame loop's chain of menus, and what an app's menu bar becomes.
@Suite("Submenu content")
struct SubmenuContentTests {
    func menu(_ kdl: String) throws -> (content: Node?, template: ContentTemplate?) {
        let nodes = try KDL.parse(kdl)
        return try KDLNode.menuContent(nodes, at: .start)
    }

    @Test("submenu is a block inside a node: its rows, and a control however few actions it has")
    func kdl() throws {
        let content = try #require(try menu("""
        row { text "More"; submenu { row on-click="reload" { text "Inner" }; separator } }
        """).content)
        #expect(content.children.map(\.kind) == [.text("More")], "the submenu is not one of its children")
        #expect(content.actions.isControl)
        let submenu = try #require(content.actions.submenu)
        #expect(submenu.count == 2)
        #expect(submenu[0].actions.click == "reload")
        #expect(submenu[1].classes == ["separator"])
    }

    @Test("each and if work inside a submenu, and one that comes to nothing is none")
    func templated() throws {
        let template = try #require(try menu("""
        row { text "Networks"; submenu { each "others" { row on-click="join {ssid}" { text "{ssid}" } } } }
        """).template)
        let some = try template.render(StateReader(root: ["x": ["others": [["ssid": "a"], ["ssid": "b"]]]], item: "x"))
        #expect(some.actions.submenu?.count == 2)
        #expect(some.actions.submenu?[1].actions.click == "join 'b'")
        let none = try template.render(StateReader(root: ["x": [:]], item: "x"))
        #expect(none.actions.submenu == nil)
        #expect(!none.actions.isControl)
    }

    @Test("a submenu travels as JSON and back, as a list or one node")
    func json() throws {
        let node = Node(.row(Container(children: [.text("More")])),
                        actions: NodeActions(submenu: [.text("a"), .text("b")]))
        let decoded = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(node))
        #expect(decoded == node)
        let one = try JSONDecoder().decode(Node.self, from: Data(#"{"text": "x", "submenu": {"text": "y"}}"#.utf8))
        #expect(one.actions.submenu == [.text("y")])
    }

    @Test("a submenu written wrong says so where it is written")
    func errors() {
        #expect(throws: KDLError.self) { try menu(#"row submenu="x" { text "a" }"#) }
        #expect(throws: KDLError.self) { try menu(#"row { text "a"; submenu { text "b" }; submenu { text "c" } }"#) }
        #expect(throws: KDLError.self) { try menu(#"row { text "a"; submenu }"#) }
    }
}

@Suite("Submenu style and layout")
struct SubmenuLayoutTests {
    let display = DisplayInfo(displayID: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 400, height: 900),
                              scale: 2, stripHeight: 24)

    func styled(_ menu: Node, css: String, depth: Int = 0,
                interaction: Styler.NodeInteraction = .init()) throws -> StyledMenu {
        let config = try ConfigLoader.parse(#"bar { item "app" module="text" }"#)
        let state = ModuleHost.ItemState(result: RenderResult(content: .text("x")), rendered: true)
        let styler = Styler(cascade: Cascade(stylesheet: try Stylesheet.parse(css)))
        return styler.style(menu: menu, of: "app", bar: config.bars[0], states: ["app": state],
                            interaction: interaction, depth: depth)
    }

    func submenu(_ styled: StyledMenu, beside parent: CGRect, row: CGRect, scroll: CGFloat = 0,
                 reveal: [Int]? = nil) -> MenuScene {
        BarLayout(metrics: FixedMetrics()).layout(submenu: styled, beside: parent, row: row, top: 876,
                                                  on: display, scroll: scroll, reveal: reveal)
    }

    func box(_ scene: MenuScene) -> CGRect { scene.panel.offsetBy(dx: scene.frame.minX, dy: scene.frame.minY) }

    @Test("menu reaches every level, and menu menu only submenus")
    func cascade() throws {
        let css = "menu { padding: 3pt } menu menu { padding: 9pt }"
        #expect(try styled(.text("a"), css: css).style.padding == Insets(3))
        #expect(try styled(.text("a"), css: css, depth: 1).style.padding == Insets(9))
        #expect(try styled(.text("a"), css: css, depth: 2).style.padding == Insets(9))
    }

    @Test("the row a submenu hangs from is :open")
    func open() throws {
        let tree = Node.column([
            Node(.row(Container(children: [.text("more")])), actions: NodeActions(submenu: [.text("x")])),
            Node(.row(Container(children: [.text("go")])), actions: NodeActions(click: "reload")),
        ])
        let menu = try styled(tree, css: "row:open { opacity: 0.5 }", interaction: .init(open: [0]))
        #expect(menu.content.children[0].style.opacity == 0.5)
        #expect(menu.content.children[1].style.opacity == 1)
    }

    @Test("beside its parent, its first row level with its row, the gap its margin-left")
    func beside() throws {
        let styledMenu = try styled(.column([.text("one"), .text("two")]),
                                    css: "menu { padding: 4pt; margin: 0 0 0 3pt; min-width: 80pt }")
        let parent = CGRect(x: 100, y: 600, width: 120, height: 270)
        let row = CGRect(x: 104, y: 800, width: 112, height: 14)
        let placed = box(submenu(styledMenu, beside: parent, row: row))
        #expect(placed.x == 220 + 3)
        #expect(placed.top == 814 + 4, "its padding above its first row")
        let first = try #require(submenu(styledMenu, beside: parent, row: row).item?.content?.children[0])
        let scene = submenu(styledMenu, beside: parent, row: row)
        #expect(first.frame.offsetBy(dx: scene.frame.minX, dy: scene.frame.minY).top == row.top)
    }

    @Test("on the left when the display has no room on the right, and on the display")
    func flips() throws {
        let styledMenu = try styled(.text("one"), css: "menu { margin: 0 0 0 3pt; min-width: 80pt }")
        let parent = CGRect(x: 250, y: 600, width: 120, height: 270)
        let placed = box(submenu(styledMenu, beside: parent, row: CGRect(x: 254, y: 800, width: 112, height: 14)))
        #expect(placed.right == 250 - 3)

        let low = box(submenu(styledMenu, beside: CGRect(x: 100, y: 0, width: 120, height: 40),
                              row: CGRect(x: 104, y: 2, width: 112, height: 14)))
        #expect(low.y == 6, "kept off the display's bottom edge")
    }

    @Test("a menu taller than its room is cut to fit, and scrolls within it")
    func scrolls() throws {
        let rows = (0..<100).map { Node.text("row \($0)") }
        let styledMenu = try styled(.column(rows), css: "menu { min-width: 80pt }")
        let parent = CGRect(x: 100, y: 600, width: 120, height: 270)
        let row = CGRect(x: 104, y: 800, width: 112, height: 14)
        let top = submenu(styledMenu, beside: parent, row: row)
        #expect(box(top).h == 876 - 12, "the room below the bar, less the edges")
        #expect(box(top).top == 876 - 6, "an edge below the bar")
        #expect(top.scroll == 0)
        let first = { (scene: MenuScene) in scene.item!.content!.children[0].frame.top }
        #expect(first(top) == top.panel.top)

        let down = submenu(styledMenu, beside: parent, row: row, scroll: 50)
        #expect(down.scroll == 50)
        #expect(first(down) == top.panel.top + 50, "its rows moved up")
        #expect(Double(submenu(styledMenu, beside: parent, row: row, scroll: 99_999).scroll) == 1400 - 864,
                "no further than its last row")
        #expect(submenu(styledMenu, beside: parent, row: row, scroll: -5).scroll == 0)

        let revealed = submenu(styledMenu, beside: parent, row: row, reveal: [80])
        let last = revealed.item!.content!.children[80].frame
        #expect(last.y >= revealed.panel.y && last.top <= revealed.panel.top, "scrolled into view")
    }
}

@Suite("Submenus in the frame loop")
@MainActor
struct SubmenuFrameTests {
    static let checker = Shot.checkerboard(width: 800, height: 48)!

    final class Made {
        var menus: [RecordingMenuSurface] = []
        var submenus: [RecordingMenuSurface] = []
    }

    /// A bar with one item whose menu has: a plain row, "more" opening a submenu (whose second
    /// row opens another), and "other" opening a submenu of its own.
    func started(css: String = "menu { min-width: 150pt } menu menu { min-width: 100pt }") async throws -> (Harness, Made) {
        ModuleRegistry.registerBuiltIns()
        let h = try Harness("""
        item "a" module="text" {
          content { text "a" }
          menu {
            row on-click="reload" { text "plain" }
            if "!gone" {
              row { text "more"; submenu {
                row on-click="reload" { text "inner" }
                row { text "deeper"; submenu { row on-click="reload" { text "deepest" } } }
              } }
            }
            row { text "other"; submenu { row on-click="reload" { text "other inner" } } }
          }
        }
        """, css: css)
        let made = Made()
        h.loop.makeMenuSurface = { _ in
            let surface = RecordingMenuSurface()
            made.menus.append(surface)
            return surface
        }
        h.loop.makeSubmenuSurface = { _ in
            let surface = RecordingMenuSurface()
            made.submenus.append(surface)
            return surface
        }
        await h.start()
        h.loop.setBackdrop(SubmenuFrameTests.checker, for: 1)
        await h.settle()
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        #expect(h.loop.menu != nil)
        return (h, made)
    }

    /// The middle of the node at `path` in an open menu, on screen.
    func point(_ path: [Int], in menu: Menu?, dx: CGFloat = 0, dy: CGFloat = 0) throws -> CGPoint {
        let menu = try #require(menu)
        let node = try #require(menu.presentation?.scene.items.first?.content?.node(at: path))
        return CGPoint(x: menu.surface.frame.minX + node.frame.midX + dx, y: menu.surface.frame.minY + node.frame.midY + dy)
    }

    @Test("hovering a row with a submenu opens it beside the row, in a window of its own")
    func opens() async throws {
        let (h, made) = try await started()
        h.loop.pointerMoved(to: try point([1], in: h.loop.menu))
        await h.settle()
        let submenu = try #require(h.loop.submenus.first)
        #expect(submenu.row == [1])
        #expect(submenu.depth == 1)
        #expect(made.submenus.count == 1)
        #expect(made.submenus.first?.visible == true)
        let root = try #require(h.loop.menu?.panelFrame)
        let box = try #require(submenu.panelFrame)
        #expect(box.x >= root.right, "to the right of its parent")
        let row = try point([1], in: h.loop.menu)
        let inner = try point([0], in: submenu)
        #expect(abs(inner.y - row.y) < 0.5, "its first row level with its row")
    }

    @Test("another control closes it; the panel between controls and the space off it do not")
    func closesOnAnotherControl() async throws {
        let (h, made) = try await started()
        h.loop.pointerMoved(to: try point([1], in: h.loop.menu))
        await h.settle()
        #expect(h.loop.submenus.count == 1)

        h.loop.pointerMoved(to: CGPoint(x: 390, y: 100))
        await h.settle()
        #expect(h.loop.submenus.count == 1, "off every panel, it stays")

        // Straight down onto the plain row: not heading for the submenu.
        h.loop.pointerMoved(to: try point([0], in: h.loop.menu))
        await h.settle()
        await h.drain()
        #expect(h.loop.submenus.isEmpty)
        #expect(made.submenus.first?.closed == true)
    }

    @Test("on its way to the submenu the pointer crosses other rows without them taking over")
    func aiming() async throws {
        let (h, _) = try await started()
        let root = try #require(h.loop.menu?.panelFrame)
        let start = try point([1], in: h.loop.menu)
        h.loop.pointerMoved(to: CGPoint(x: root.minX + 10, y: start.y))
        await h.settle()
        #expect(h.loop.submenus.first?.row == [1])

        // Right and a row down, onto "other", heading for the submenu's near edge.
        let other = try point([2], in: h.loop.menu)
        h.loop.pointerMoved(to: CGPoint(x: root.maxX - 3, y: other.y))
        await h.settle()
        #expect(h.loop.submenus.first?.row == [1], "still on its way")
        #expect(h.loop.menu?.hovered == [1])

        // It stopped there: the row under it takes over.
        h.scheduler.advance(by: FrameLoop.aimDelay + 0.01)
        await h.settle()
        #expect(h.loop.menu?.hovered == [2])
        #expect(h.loop.submenus.first?.row == [2])
    }

    @Test("submenus open from submenus, and close together")
    func chain() async throws {
        let (h, made) = try await started()
        h.loop.pointerMoved(to: try point([1], in: h.loop.menu))
        await h.settle()
        let first = try #require(h.loop.submenus.first)
        h.loop.pointerMoved(to: try point([1], in: first))
        await h.settle()
        #expect(h.loop.submenus.count == 2)
        #expect(h.loop.submenus.last?.depth == 2)
        #expect(h.loop.menu?.hovered == nil, "the pointer is not over the root")
        #expect(h.loop.openMenus.count == 3)

        h.loop.closeMenu()
        await h.drain()
        #expect(h.loop.openMenus.isEmpty)
        #expect(made.submenus.allSatisfy { $0.closed })
        #expect(made.menus.allSatisfy { $0.closed })
    }

    @Test("→ opens the submenu and moves into it, ← comes back out")
    func keys() async throws {
        let (h, _) = try await started()
        h.loop.moveMenuHover(by: 1)
        h.loop.moveMenuHover(by: 1)
        h.scheduler.run()
        #expect(h.loop.menu?.hovered == [1])
        #expect(h.loop.submenus.isEmpty, "moving onto it with the keys does not open it")

        #expect(h.loop.openSubmenuFromKeys())
        await h.settle()
        let submenu = try #require(h.loop.submenus.first)
        #expect(submenu.hovered == [0])
        #expect(h.loop.keyMenu === submenu)
        h.loop.moveMenuHover(by: 1)
        #expect(submenu.hovered == [1], "the arrows move in the submenu now")

        #expect(h.loop.closeSubmenuFromKeys())
        await h.settle()
        #expect(h.loop.submenus.isEmpty)
        #expect(h.loop.menu?.hovered == [1])
        #expect(!h.loop.closeSubmenuFromKeys(), "← in the root does nothing")
    }

    @Test("a new render of the root reaches the submenu, and closes it when its row has gone")
    func rendersReach() async throws {
        let (h, _) = try await started()
        h.loop.pointerMoved(to: try point([1], in: h.loop.menu))
        await h.settle()
        #expect(h.loop.submenus.count == 1)
        // Off every panel, so nothing under the pointer opens anything again.
        h.loop.pointerMoved(to: CGPoint(x: 390, y: 100))
        await h.settle()
        #expect(h.loop.submenus.count == 1)
        await h.host.store.merge(.object(["gone": true]), at: "a")
        await h.settle()
        await h.drain()
        #expect(h.loop.submenus.isEmpty, "row 1 is now \"other\", whose submenu is not this one's")
    }

    @Test("an open menu that read the modifier keys renders again when they change")
    func modifiers() async throws {
        ModuleRegistry.registerBuiltIns()
        let h = try Harness("""
        item "a" module="text" {
          content { text "a" }
          menu {
            if "!/modifiers.option" { row on-click="reload" { text "Quit" } }
            if "/modifiers.option" { row on-click="reload" { text "Quit and Keep Windows" } }
          }
        }
        """)
        let surface = RecordingMenuSurface()
        h.loop.makeMenuSurface = { _ in surface }
        await h.start()
        h.loop.setBackdrop(SubmenuFrameTests.checker, for: 1)
        await h.settle()
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        func label() -> String? {
            guard case .text(let text)? = surface.presentations.last?.scene.items.first?.content?.children.first?.children.first?.kind
            else { return nil }
            return text
        }
        #expect(label() == "Quit")
        await h.host.store.replace(ModifierKeys(option: true).json, at: ModifierKeys.storeKey)
        await h.settle()
        #expect(label() == "Quit and Keep Windows")
    }

    @Test("modifiers is bario's key in the store, so nothing else can be called that")
    func reservedName() {
        #expect(throws: KDLError.self) { try ConfigLoader.parse(#"bar { item "modifiers" module="text" }"#) }
    }

    @Test("the wheel scrolls a menu taller than its room")
    func wheel() async throws {
        let rows = (0..<100).map { "row on-click=\"reload\" { text \"row \($0)\" }" }.joined(separator: "\n")
        ModuleRegistry.registerBuiltIns()
        let h = try Harness("""
        item "a" module="text" { content { text "a" }; menu { \(rows) } }
        """)
        h.loop.makeMenuSurface = { _ in RecordingMenuSurface() }
        await h.start()
        h.loop.setBackdrop(SubmenuFrameTests.checker, for: 1)
        await h.settle()
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        let menu = try #require(h.loop.menu)
        #expect(menu.scroll == 0)
        h.loop.scrollMenu(menu, by: -40)
        await h.settle()
        #expect(menu.scroll == 40)
        h.loop.scrollMenu(menu, by: 100)
        await h.settle()
        #expect(menu.scroll == 0, "never above its first row")
    }
}

@Suite("App menus")
struct AppMenuTests {
    func item(_ title: String, _ key: String? = nil, modifiers: Int = 0, enabled: Bool = true,
              mark: String? = nil, path: [Int] = []) -> AppMenuItem {
        AppMenuItem(title, enabled: enabled, mark: mark,
                    shortcut: key.flatMap { MenuShortcut(character: $0, glyph: nil, modifiers: modifiers) }, path: path)
    }

    @Test("shortcuts are written as macOS writes them")
    func shortcuts() {
        func text(_ character: String?, glyph: Int? = nil, _ modifiers: Int) -> String? {
            MenuShortcut(character: character, glyph: glyph, modifiers: modifiers)?.text
        }
        #expect(text("n", 0) == "⌘N")
        #expect(text("W", 3) == "⌥⇧⌘W")
        #expect(text("q", 4) == "⌃⌘Q")
        #expect(text("\t", glyph: 2, 12) == "⌃⇥", "8 is no Command")
        #expect(text("\t", glyph: 2, 13) == "⌃⇧⇥")
        #expect(text("\r", glyph: 11, 1) == "⇧⌘↩")
        #expect(text("\u{F700}", glyph: 104, 2) == "⌥⌘↑")
        #expect(text("\u{8}", glyph: 23, 0) == "⌘⌫")
        #expect(text("\u{F70B}", 0) == "⌘F8")
        #expect(text("F", 24) == "fn F", "16 is fn")
        #expect(text(nil, 0) == nil)
        #expect(text("\u{F7FF}", 0) == nil, "a key it cannot print is no shortcut")
    }

    @Test("Option variants by Tanner's rule: same key, plus ⌥, same first five characters")
    func alternates() {
        #expect(AppMenus.isAlternate(item("Quit and Keep Windows", "Q", modifiers: 2), of: item("Quit Ghostty", "Q")))
        #expect(AppMenus.isAlternate(item("Close Tab", "W", modifiers: 2), of: item("Close", "W")))
        #expect(AppMenus.isAlternate(item("Close All Windows", "W", modifiers: 3), of: item("Close Window", "W", modifiers: 1)))
        #expect(AppMenus.isAlternate(item("Minimize All", "M", modifiers: 2), of: item("Minimize", "M")))
        #expect(AppMenus.isAlternate(item("Undo All", "Z", modifiers: 2), of: item("Undo", "Z")),
                "all of a title shorter than five")
        #expect(!AppMenus.isAlternate(item("Hide Others", "H", modifiers: 2), of: item("Hide Ghostty", "H")),
                "Hide Others always shows")
        #expect(!AppMenus.isAlternate(item("Save As…", "S", modifiers: 2), of: item("Show Sidebar", "S")),
                "a shortcut with Option in it is not a variant of everything on its key")
        #expect(!AppMenus.isAlternate(item("Close Window", "W", modifiers: 1), of: item("Close", "W")),
                "Shift is not Option")
        #expect(!AppMenus.isAlternate(item("Zoom All"), of: item("Zoom")), "no shortcut, no pair")
    }

    @Test("a variant shows in its item's place while Option is held, and not before")
    func shown() {
        let items = [item("Close", "W"), item("Close Tab", "W", modifiers: 2), item("Close Window", "W", modifiers: 1)]
        #expect(AppMenus.shown(items, option: false).map(\.item.title) == ["Close", "Close Window"])
        let held = AppMenus.shown(items, option: true)
        #expect(held.map(\.item.title) == ["Close Tab", "Close Window"])
        #expect(held.map(\.alternate) == [true, false])
    }

    @Test("separators never double or end a menu, and untitled views are left out")
    func separators() {
        let separator = AppMenuItem("")
        let view = AppMenuItem("", submenu: [item("search")])
        let items = [separator, item("Copy"), separator, separator, view, item("Paste"), separator]
        #expect(AppMenus.shown(items, option: false).map(\.item.title) == ["Copy", "", "Paste"])
    }

    @Test("the menu: App and the app's titles, each opening its items, which press by path")
    func tree() throws {
        let menus = [
            AppMenuItem("Ghostty", submenu: [item("About Ghostty", path: [1, 0]), item("Quit Ghostty", "Q", path: [1, 1])],
                        path: [1]),
            AppMenuItem("Edit", submenu: [item("Undo", "Z", enabled: false, path: [2, 0]),
                                          AppMenuItem("", path: [2, 1]),
                                          item("Copy", "C", path: [2, 2])], path: [2]),
            AppMenuItem("Window", submenu: [item("Front", mark: "✓", path: [3, 0]), item("Back", path: [3, 1]),
                                            AppMenuItem("Arrange", submenu: [item("Left", path: [3, 2, 0])], path: [3, 2])],
                        path: [3]),
            AppMenuItem("Empty", submenu: [], path: [4]),
        ]
        let menu = try #require(AppMenus.menu(menus, option: false))
        #expect(menu.children.count == 3, "a menu with nothing in it is left out")
        #expect(menu.children.map { $0.children.first?.kind } == [.text("App"), .text("Edit"), .text("Window")])
        #expect(menu.children[0].children.last?.classes == ["arrow"])

        let app = try #require(menu.children[0].actions.submenu)
        #expect(app[1].actions.click == "press 1.1")
        #expect(app[1].children.last?.kind == .text("⌘Q"))
        #expect(app[1].children.last?.classes == ["shortcut"])

        let edit = try #require(menu.children[1].actions.submenu)
        #expect(edit[0].classes == ["disabled"])
        #expect(!edit[0].actions.isControl)
        #expect(edit[1].classes == ["separator"])

        let window = try #require(menu.children[2].actions.submenu)
        #expect(window[0].children.first?.kind == .text("✓"))
        #expect(window[1].children.first?.kind == .text(""), "the mark column holds its place")
        #expect(window[1].children.first?.classes == ["mark"])
        #expect(window[2].actions.submenu?.first?.actions.click == "press 3.2.0")
        #expect(window[2].actions.click == nil)
        #expect(edit[2].children.first?.kind == .text("Copy"), "no marks in Edit, no column")
    }

    @Test("a press names its item by path")
    func path() {
        #expect(AppMenus.path("2.5.0") == [2, 5, 0])
        #expect(AppMenus.path("2.x") == nil)
        #expect(AppMenus.path("") == nil)
    }
}
