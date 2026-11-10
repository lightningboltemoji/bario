import AppKit
import Testing
@testable import BarioKit

/// Menus, from the content model up: templates, the config, actions, style,
/// layout, and the frame loop opening, presenting and closing them.
@Suite("Menu content")
struct MenuContentTests {
    func reader(_ state: JSONValue, item: String = "x") -> StateReader {
        StateReader(root: .object([item: state]), item: item)
    }

    func template(_ kdl: String) throws -> ContentTemplate {
        let nodes = try KDL.parse(kdl)
        let (content, template) = try KDLNode.menuContent(nodes, at: .start)
        #expect(content == nil, "these all read state")
        return try #require(template)
    }

    @Test("each repeats its children for every element, reading the element first")
    func each() throws {
        let menu = try template("""
        each "outputs" { row class="{state}" { text "{name}"; text "{device}" } }
        """)
        let node = try menu.render(reader([
            "device": "Speakers",
            "outputs": [["name": "One", "state": "selected"], ["name": "Two"]],
        ]))
        guard case .column(let column) = node.kind else { Issue.record("not a column"); return }
        #expect(column.children.count == 2)
        #expect(column.children[0].classes == ["selected"])
        #expect(column.children[1].classes == [])
        #expect(column.children[0].children.map(\.kind) == [.text("One"), .text("Speakers")],
                "a slot the element has not falls back to the item")
        #expect(try menu.render(reader([:])).children.isEmpty, "no list is no rows")
    }

    @Test("if keeps its children while a value is truthy, and if \"!…\" while it is not")
    func conditions() throws {
        let menu = try template("""
        if "ssid" { text "{ssid}" }
        if "!ssid" { text "no network" }
        """)
        #expect(try menu.render(reader(["ssid": "home"])).children.map(\.kind) == [.text("home")])
        #expect(try menu.render(reader(["ssid": .null])).children.map(\.kind) == [.text("no network")])
    }

    @Test("a slot starting with / reads from the root of the store, and the read is recorded")
    func absolute() throws {
        let menu = try template(#"text "{/volume.level}%""#)
        let state = StateReader(root: .object(["apple": [:], "volume": ["level": 40]]), item: "apple")
        #expect(try menu.render(state).kind == .text("40%"))
        #expect(state.paths.contains("volume.level"))
    }

    @Test("a slot in an action is one word, whatever is in it")
    func quotedActions() throws {
        let menu = try template(#"row on-click="output {id}" { text "{id}" }"#)
        let hostile = "it's; rm -rf ~"
        let node = try menu.render(reader(["id": .string(hostile)]))
        #expect(node.actions.click == "output 'it'\\''s; rm -rf ~'")
        #expect(Action.parse(try #require(node.actions.click))
                == .module("output", .object(["args": .array([.string(hostile)])])))
    }

    @Test("several nodes in a menu are a column; one is itself")
    func implicitColumn() throws {
        let one = try KDLNode.menuContent(try KDL.parse(#"row { text "a" }"#), at: .start)
        #expect(one.content.map { if case .row = $0.kind { true } else { false } } == true)
        let two = try KDLNode.menuContent(try KDL.parse(#"text "a"; text "b""#), at: .start)
        #expect(two.content?.children.count == 2)
    }

    @Test("controls, separators and sliders read from KDL")
    func kdl() throws {
        let (content, _) = try KDLNode.menuContent(try KDL.parse("""
        row on-click="exec open -a Music" keep-open=#true id="music" { text "Music" }
        separator
        slider value=0.4 on-change="set-level"
        """), at: .start)
        let children = try #require(content?.children)
        #expect(children[0].actions == NodeActions(click: "exec open -a Music", keepOpen: true))
        #expect(children[0].id == "music")
        #expect(children[1].kind == .spacer(Spacer()))
        #expect(children[1].classes == ["separator"])
        #expect(children[2].kind == .slider(Meter(value: 0.4)))
        #expect(children[2].actions.change == "set-level")
    }

    @Test("a malformed shortcut in a menu is an error where it was written")
    func badShortcut() {
        #expect(throws: KDLError.self) {
            _ = try KDLNode.menuContent(try KDL.parse(#"row on-click="key hyper+q" { text "x" }"#), at: .start)
        }
        #expect(throws: KDLError.self) {
            _ = try KDLNode.menuContent(try KDL.parse(#"each { text "x" }"#), at: .start)
        }
    }

    @Test("a node's actions and a slider travel as JSON and back")
    func json() throws {
        let node = Node(.slider(Meter(value: 0.5, width: 80)), id: "level",
                        actions: NodeActions(change: "set-level", keepOpen: true))
        let decoded = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(node))
        #expect(decoded == node)
        let pushed = try JSONDecoder().decode(Node.self, from: Data(#"{"text": "Hi", "on-click": "reload"}"#.utf8))
        #expect(pushed.kind == .text("Hi"))
        #expect(pushed.actions.click == "reload")
    }
}

@Suite("Menu config and verbs")
struct MenuConfigTests {
    @Test("an item's menu is the host's, not its module's")
    func parsed() throws {
        let config = try ConfigLoader.parse("""
        bar {
          item "wifi" module="wifi" format="{icon}" {
            menu align="end" { row { text "{ssid}" } }
          }
        }
        """)
        let item = try #require(config.item(named: "wifi"))
        #expect(item.menu?.align == .end)
        #expect(item.menu?.template != nil)
        #expect(item.options["menu"] == nil, "the module never sees its menu")
    }

    @Test("only items have menus, and a source is never shown")
    func errors() {
        #expect(throws: KDLError.self) {
            _ = try ConfigLoader.parse(#"bar { group "g" { item "a" module="text"; menu { text "x" } } }"#)
        }
        #expect(throws: KDLError.self) {
            _ = try ConfigLoader.parse(#"source "s" module="data" { menu { text "x" } }; bar { spacer }"#)
        }
        #expect(throws: KDLError.self) {
            _ = try ConfigLoader.parse(#"bar { item "a" module="text" { menu align="middle" { text "x" } } }"#)
        }
    }

    @Test("menu and send are the host's verbs; confined, everything but menu is the module's")
    func verbs() {
        #expect(Action.parse("menu") == .menu(nil))
        #expect(Action.parse("menu wifi") == .menu("wifi"))
        #expect(Action.parse("send volume up 5")
                == .send("volume", "up", .object(["args": .array([.string("5")])])))
        #expect(Action.parse("send volume") == nil)
        #expect(Action.parse("exec rm -rf ~", confined: true)
                == .module("exec", .object(["args": .array([.string("rm"), .string("-rf"), .string("~")])])))
        #expect(Action.parse("menu", confined: true) == .menu(nil))
        #expect(throws: ActionError.self) { try Action.validate("send volume") }
        #expect(throws: ActionError.self) { try Action.validate("menu a b") }
    }
}

@Suite("Menu style and layout")
struct MenuLayoutTests {
    let display = DisplayInfo(displayID: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 400, height: 900),
                              scale: 2, stripHeight: 24)

    func styled(_ menu: Node, css: String, item: String = "wifi", classes: [String] = [],
                interaction: Styler.NodeInteraction = .init()) throws -> StyledMenu {
        let config = try ConfigLoader.parse(#"bar { group "status" { item "\#(item)" module="text" } }"#)
        var state = ModuleHost.ItemState(result: RenderResult(content: .text("x"), classes: classes), rendered: true)
        state.rendered = true
        let styler = Styler(cascade: Cascade(stylesheet: try Stylesheet.parse(css)))
        return styler.style(menu: menu, of: item, bar: config.bars[0], states: [item: state],
                            interaction: interaction)
    }

    func layout(_ styled: StyledMenu, anchor: CGRect = CGRect(x: 100, y: 876, width: 30, height: 24),
                align: Align = .start) -> MenuScene {
        BarLayout(metrics: FixedMetrics()).layout(menu: styled, anchor: anchor, top: 876, align: align, on: display)
    }

    @Test("selected under its item, inheriting from the bar and not the bubble")
    func cascade() throws {
        let menu = try styled(.column([.text("Signal")]), css: """
        bar { color: blue; font-size: 10pt }
        #wifi { color: red; font-size: 30pt }
        #status #wifi.on menu { padding: 7pt }
        """, classes: ["on"])
        #expect(menu.style.padding == Insets(7), "groups, the item and its classes select it")
        #expect(menu.content.children[0].style.color == .rgba(RGBA(r: 0, g: 0, b: 1)), "the bar's colour")
        #expect(menu.content.children[0].style.font.size == 10)
    }

    @Test("only a control hovers, found by its path in the tree")
    func hover() throws {
        let tree = Node.column([
            Node.row([.text("info")]),
            Node(.row(Container(children: [.text("go")])), actions: NodeActions(click: "reload")),
        ])
        let css = "row:hover { opacity: 0.5 }"
        let hovered = try styled(tree, css: css, interaction: .init(hovered: [1]))
        #expect(hovered.content.children[1].style.opacity == 0.5)
        let info = try styled(tree, css: css, interaction: .init(hovered: [0]))
        #expect(info.content.children[0].style.opacity == 1, "an information row is no control")
    }

    @Test("rows stretch to the panel, a spacer pushes a value right, and a slider takes its row")
    func stretch() throws {
        let tree = Node.column([
            .row([.text("Signal"), .spacer(), .text("-52")]),
            .row([.icon("sun.max"), Node(.slider(Meter(value: 0.5)), actions: NodeActions(change: "x"))]),
        ])
        let menu = layout(try styled(tree, css: "menu { padding: 5pt; min-width: 200pt } row { gap: 0 }"))
        let panel = try #require(menu.item)
        let content = try #require(panel.content)
        #expect(menu.panel.w == 200)
        let row = content.children[0]
        #expect(row.frame.w == 190, "the panel less its padding")
        #expect(row.children[2].frame.right == row.frame.right, "the value at the right edge")
        let slider = content.children[1].children[1]
        #expect(slider.frame.right == content.children[1].frame.right)
        #expect(slider.frame.x == content.children[1].frame.x + 12, "after the icon")
    }

    @Test("a separator's margin is room around it, not part of it")
    func separator() throws {
        let tree = Node.column([.text("a"), .separator, .text("b")])
        let menu = layout(try styled(tree, css: "menu { min-width: 100pt } .separator { padding: 0.5pt 0; margin: 4pt 10pt }"))
        let line = try #require(menu.item?.content?.children[1])
        #expect(line.frame.h == 1)
        #expect(line.frame.w == 80)
        #expect(line.frame.x == (menu.item?.content?.frame.x ?? 0) + 10)
    }

    @Test("it hangs from the bar under its item, and stays on the display")
    func placement() throws {
        let styledMenu = try styled(.text("hello"), css: "menu { margin: 5pt 0 0 0; min-width: 100pt }")
        let start = layout(styledMenu)
        let box = start.panel.offsetBy(dx: start.frame.minX, dy: start.frame.minY)
        #expect(box.x == 100, "its left edge under the item's")
        #expect(box.top == 876 - 5, "the margin is the gap below the bar")

        let end = layout(styledMenu, align: .end)
        #expect(end.panel.offsetBy(dx: end.frame.minX, dy: end.frame.minY).right == 130)

        let edge = layout(styledMenu, anchor: CGRect(x: 380, y: 876, width: 20, height: 24))
        #expect(edge.panel.offsetBy(dx: edge.frame.minX, dy: edge.frame.minY).right == 400 - 6,
                "moved in from the display's edge")
    }

    @Test("its opacity and transform are the window's, and the rest is the panel's")
    func surface() throws {
        let menu = layout(try styled(.text("x"), css: """
        menu { opacity: 0.8; background: red; transform: translateY(2pt) }
        menu:leaving { opacity: 0 }
        """))
        #expect(menu.scene.style.opacity == 0.8)
        #expect(menu.scene.style.background == .none)
        #expect(menu.item?.style.opacity == 1)
        #expect(menu.item?.style.background == .color(.rgba(RGBA(r: 1, g: 0, b: 0))))
        #expect(menu.scene.leaving?.opacity == 0)
    }

    @Test("glass parses, with its two knobs")
    func glass() throws {
        let sheet = try Stylesheet.parse("menu { background: glass(clear, rgba(0, 0, 255, 0.2)) }")
        let style = Cascade(stylesheet: sheet).style(for: [StyleNode(type: "menu")]).style
        #expect(style.background == .glass(Glass(clear: true, tint: .rgba(RGBA(r: 0, g: 0, b: 1, a: 0.2)))))
    }
}

// MARK: - The frame loop

/// A menu whose tree is its state's `label`, counting how often it is asked; nothing at all
/// while its state says `none`. Its bubble goes while its state says `hide`.
actor MenuTestModule: Module {
    private(set) var menus = 0

    func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: .text(state.value("text")?.stringValue ?? "item"),
                     visible: state.value("hide")?.boolValue != true)
    }

    func menu(_ state: StateReader) async throws -> Node? {
        menus += 1
        if state.value("none")?.boolValue == true { return nil }
        return .column([Node(.text(state.value("label")?.stringValue ?? "menu"),
                             actions: NodeActions(click: "reload"))])
    }
}

/// A bubble whose class is its state's `on`, and a menu that never changes.
actor ClassyModule: Module {
    func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: .text("a"), classes: state.value("on")?.boolValue == true ? ["on"] : [])
    }

    func menu(_ state: StateReader) async throws -> Node? { .text("same") }
}

@MainActor
final class RecordingMenuSurface: MenuSurface {
    private(set) var frame = CGRect.zero
    let hostLayer = CALayer()
    private(set) var presentations: [Presentation] = []
    private(set) var visible = false
    private(set) var closed = false
    private(set) var takesPointer = false

    func place(_ frame: CGRect) { self.frame = frame }
    func presented(_ presentation: Presentation) { presentations.append(presentation) }
    func setVisible(_ visible: Bool) { self.visible = visible }
    func setTakesPointer(_ takes: Bool) { takesPointer = takes }
    func close() { closed = true }

    /// The text of the menu's first row, as last presented.
    var label: String? {
        guard case .text(let text)? = presentations.last?.scene.items.first?.content?.children.first?.kind
        else { return nil }
        return text
    }
}

@Suite("Menus in the frame loop")
@MainActor
struct MenuFrameTests {
    static let checker = Shot.checkerboard(width: 800, height: 48)!

    final class Made {
        var surfaces: [RecordingMenuSurface] = []
    }

    /// A running bar of the given items, on screen, making recording surfaces for menus.
    func started(_ items: String, css: String = "", modules: [String: MenuTestModule] = [:]) async throws
        -> (Harness, Made) {
        ModuleRegistry.registerBuiltIns()
        for (name, module) in modules { ModuleRegistry.register(name) { _ in module } }
        ModuleRegistry.register("menu-test") { _ in MenuTestModule() }
        let h = try Harness(items, css: css)
        let made = Made()
        h.loop.makeMenuSurface = { _ in
            let surface = RecordingMenuSurface()
            made.surfaces.append(surface)
            return surface
        }
        await h.start()
        h.loop.setBackdrop(MenuFrameTests.checker, for: 1)
        await h.settle()
        #expect(h.surface.visible)
        return (h, made)
    }

    @Test("a menu opens after its first render, and not before")
    func opens() async throws {
        let (h, made) = try await started(#"item "a" module="menu-test""#)
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        #expect(h.loop.menu == nil)
        #expect(made.surfaces.isEmpty)
        await h.settle()
        let surface = try #require(made.surfaces.first)
        #expect(h.loop.menu?.item == "a")
        #expect(surface.visible)
        #expect(surface.takesPointer)
        #expect(surface.label == "menu")
        #expect(h.loop.menu?.panelFrame?.top == 876, "hanging from the bottom of the bar")
    }

    @Test("a menu with nothing in it opens nothing")
    func empty() async throws {
        let (h, made) = try await started(#"item "a" module="menu-test""#)
        await h.host.store.merge(.object(["none": true]), at: "a")
        await h.settle()
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        #expect(h.loop.menu == nil)
        #expect(h.loop.pendingMenu == nil)
        #expect(made.surfaces.isEmpty)
        #expect(h.host.menuState(for: "a") == nil, "and is not kept rendering")
    }

    @Test("a write re-renders an open menu, and not a closed one")
    func rendersWhileOpen() async throws {
        let module = MenuTestModule()
        let (h, made) = try await started(#"item "a" module="counted""#, modules: ["counted": module])
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        #expect(await module.menus == 1)

        await h.host.store.merge(.object(["label": "new"]), at: "a")
        await h.settle()
        #expect(await module.menus == 2)
        #expect(made.surfaces.first?.label == "new")

        h.loop.closeMenu()
        await h.drain()
        await h.host.store.merge(.object(["label": "newer"]), at: "a")
        await h.settle()
        #expect(await module.menus == 2, "closed, it costs nothing")
    }

    @Test("closing eases to :leaving, then the window goes")
    func closes() async throws {
        let (h, made) = try await started(#"item "a" module="menu-test""#, css: """
        menu { opacity: 1; transition: opacity 100ms linear }
        menu:leaving { opacity: 0 }
        """)
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        let surface = try #require(made.surfaces.first)

        h.loop.closeMenu()
        #expect(h.loop.menu == nil)
        #expect(h.loop.closingMenus.count == 1)
        #expect(!surface.takesPointer, "on its way out it takes nothing")
        h.scheduler.run()
        #expect(surface.visible, "still easing")
        await h.drain()
        #expect(!surface.visible)
        #expect(surface.closed)
        #expect(h.loop.closingMenus.isEmpty)
        #expect(surface.presentations.last?.scene.style.opacity ?? 1 < 0.01)
    }

    @Test("with nothing to ease to, a closed menu goes at once")
    func closesAtOnce() async throws {
        let (h, made) = try await started(#"item "a" module="menu-test""#)
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        h.loop.closeMenu()
        h.scheduler.run()
        #expect(made.surfaces.first?.closed == true)
    }

    @Test("while a menu is open its bar is shut, whatever Option says, and its item is :open")
    func barIsShut() async throws {
        let (h, _) = try await started(#"item "a" module="menu-test""#, css: "item:open { opacity: 0.5 }")
        let onBar = CGPoint(x: 3, y: 888)
        h.loop.pointerMoved(to: onBar)
        #expect(!h.loop.bars[0].isInteractive, "a lens without Option")

        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        h.loop.pointerMoved(to: onBar)
        #expect(h.loop.bars[0].isInteractive)
        #expect(h.surface.takesPointer)
        #expect(h.loop.bars[0].presentation?.scene.items.first?.style.opacity == 0.5)

        h.loop.closeMenu()
        await h.drain()
        #expect(!h.loop.bars[0].isInteractive)
        #expect(h.loop.bars[0].presentation?.scene.items.first?.style.opacity == 1)
    }

    @Test("moving onto another item whose click opens a menu switches to it")
    func switches() async throws {
        let (h, made) = try await started("""
        item "a" module="menu-test" on-click="menu"
        item "b" module="menu-test" on-click="menu"
        item "c" module="menu-test" on-click="reload"
        item "d" module="menu-test"
        """)
        await h.host.store.merge(.object(["label": "b's"]), at: "b")
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        let items = try #require(h.loop.bars[0].presentation?.scene.items)
        let b = items[1].frame, c = items[2].frame, d = items[3].frame

        h.loop.pointerMoved(to: CGPoint(x: c.midX, y: 876 + c.midY))
        await h.settle()
        #expect(h.loop.menu?.item == "a", "c's click does something else, so it has no menu to switch to")

        h.loop.pointerMoved(to: CGPoint(x: d.midX, y: 876 + d.midY))
        await h.settle()
        #expect(h.loop.menu?.item == "a", "d has a menu, but its click does not say to open it")

        h.loop.pointerMoved(to: CGPoint(x: b.midX, y: 876 + b.midY))
        await h.settle()
        #expect(h.loop.menu?.item == "b")
        #expect(h.loop.menu?.anchor.item == "b")
        #expect(made.surfaces.last?.label == "b's")
    }

    @Test("a click on an item with no menu closes the open one, and moving onto it does not")
    func emptyClick() async throws {
        let (h, _) = try await started(#"item "a" module="menu-test" on-click="menu"; item "b" module="menu-test" on-click="menu""#)
        await h.host.store.merge(.object(["none": true]), at: "b")
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        let b = try #require(h.loop.bars[0].presentation?.scene.items[1].frame)
        h.loop.pointerMoved(to: CGPoint(x: b.midX, y: 876 + b.midY))
        await h.settle()
        #expect(h.loop.menu?.item == "a")
        h.loop.toggleMenu("b", from: ItemRef(bar: 1, item: "b"))
        await h.settle()
        #expect(h.loop.menu == nil)
    }

    @Test("a click opens a menu only where on-click says menu")
    func explicitClick() async throws {
        let (h, _) = try await started("""
        item "a" module="menu-test" on-click="menu"
        item "b" module="menu-test"
        item "c" module="menu-test" on-click="menu a"
        """)
        #expect(h.loop.menuItem(forClickOn: "a") == "a")
        #expect(h.loop.menuItem(forClickOn: "b") == nil, "a menu nothing asks for opens on no click")
        #expect(h.loop.menuItem(forClickOn: "c") == "a")
    }

    @Test("an item that leaves the bar closes its menu")
    func itemLeaves() async throws {
        let (h, _) = try await started(#"item "a" module="menu-test"; item "b" module="menu-test""#)
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        #expect(h.loop.menu != nil)
        await h.host.store.merge(.object(["hide": true]), at: "a")
        await h.settle()
        await h.drain()
        #expect(h.loop.menu == nil)
    }

    @Test("toggling the open menu's own item closes it")
    func toggles() async throws {
        let (h, _) = try await started(#"item "a" module="menu-test""#)
        h.loop.toggleMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        #expect(h.loop.menu != nil)
        h.loop.toggleMenu("a", from: ItemRef(bar: 1, item: "a", node: [0]))
        #expect(h.loop.menu == nil)
    }

    @Test("a control under the pointer hovers, and the arrow keys move it")
    func hover() async throws {
        let (h, made) = try await started(#"item "a" module="menu-test""#, css: "text:hover { opacity: 0.4 }")
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        let menu = try #require(h.loop.menu)
        let row = try #require(menu.presentation?.scene.items.first?.content?.children.first)
        let surface = try #require(made.surfaces.first)
        h.loop.pointerMoved(to: CGPoint(x: surface.frame.minX + row.frame.midX, y: surface.frame.minY + row.frame.midY))
        await h.settle()
        #expect(menu.hovered == [0])
        #expect(surface.presentations.last?.scene.items.first?.content?.children.first?.style.opacity == 0.4)

        h.loop.pointerMoved(to: CGPoint(x: 390, y: 300))
        await h.settle()
        #expect(menu.hovered == nil)
        h.loop.moveMenuHover(by: 1)
        h.scheduler.run()
        #expect(menu.hovered == [0], "the keys put it on the first control")
        h.scheduler.run()
        #expect(menu.hovered == [0], "and it stays there until the pointer moves")
    }

    @Test("the menu restyles when its item's classes change")
    func itemClasses() async throws {
        ModuleRegistry.register("classy-test") { _ in ClassyModule() }
        let (h, made) = try await started(#"item "a" module="classy-test""#,
                                          css: "#a.on menu text { opacity: 0.3 }")
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        func opacity() -> Double? {
            made.surfaces.last?.presentations.last?.scene.items.first?.content?.style.opacity
        }
        #expect(opacity() == 1)
        await h.host.store.merge(.object(["on": true]), at: "a")
        await h.settle()
        #expect(opacity() == 0.3)
    }

    @Test("a dragged slider shows the dragged value until a render after the release")
    func drag() async throws {
        let (h, made) = try await started("""
        item "a" module="text" {
          content { text "a" }
          menu { slider value="{level}" on-change="set-level" }
        }
        """)
        await h.host.store.merge(.object(["level": 0.2]), at: "a")
        h.loop.openMenu("a", from: ItemRef(bar: 1, item: "a"))
        await h.settle()
        func value() -> Double? {
            guard case .slider(let meter)? = made.surfaces.last?.presentations.last?.scene.items.first?.content?.kind
            else { return nil }
            return meter.value
        }
        #expect(value() == 0.2)
        h.loop.dragMenu([], to: 0.7)
        h.scheduler.run()
        #expect(value() == 0.7)
        h.loop.releaseMenuDrag()
        await h.host.store.merge(.object(["level": 0.65]), at: "a")
        await h.settle()
        #expect(value() == 0.65, "the module's word, once it has had its say")
    }
}
