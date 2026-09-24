import CoreGraphics
import Testing
@testable import BarioKit

@Suite("Flex")
struct FlexTests {
    @Test("naturals that fit are left alone")
    func fits() {
        let widths = Flex.solve([.init(natural: 10), .init(natural: 20)], available: 100, gap: 4)
        #expect(widths == [10, 20])
    }

    @Test("free space goes to grow, in proportion")
    func growth() {
        let widths = Flex.solve([
            .init(natural: 10, grow: 1),
            .init(natural: 10),
            .init(natural: 10, grow: 3),
        ], available: 70, gap: 0)
        #expect(widths == [20, 10, 40])
    }

    @Test("a spacer is an empty item with grow 1")
    func spacers() {
        let widths = Flex.solve([
            .init(natural: 20),
            .init(natural: 0, grow: 1),
            .init(natural: 20),
        ], available: 100, gap: 0)
        #expect(widths == [20, 60, 20])
    }

    @Test("growth stops at max-width and the rest goes elsewhere")
    func maxWidth() {
        let widths = Flex.solve([
            .init(natural: 10, max: 15, grow: 1),
            .init(natural: 10, grow: 1),
        ], available: 60, gap: 0)
        #expect(widths == [15, 45])
    }

    @Test("a deficit is taken from shrink, floored at min-width")
    func shrinking() {
        let widths = Flex.solve([
            .init(natural: 60, min: 40, shrink: 1),
            .init(natural: 60, min: 0, shrink: 1),
        ], available: 80, gap: 0)
        #expect(widths[0] == 40)
        #expect(abs(widths[1] - 40) < 0.01)
    }

    @Test("shrink 0 does not shrink")
    func noShrink() {
        let widths = Flex.solve([
            .init(natural: 60, shrink: 0),
            .init(natural: 60, min: 0, shrink: 1),
        ], available: 80, gap: 0)
        #expect(widths[0] == 60)
        #expect(abs(widths[1] - 20) < 0.01)
    }

    @Test("gaps come out of the available width")
    func gaps() {
        let widths = Flex.solve([.init(natural: 0, grow: 1), .init(natural: 0, grow: 1)],
                                available: 100, gap: 10)
        #expect(widths == [45, 45])
    }
}

@Suite("Scene layout")
struct SceneLayoutTests {
    /// 12pt font, half-width characters: "abc" is 18pt wide.
    let metrics = FixedMetrics(characterWidth: 0.5, height: 14)

    func display(width: Double = 400, notch: CGRect? = nil) -> DisplayInfo {
        DisplayInfo(displayID: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: width, height: 900),
                    scale: 2, stripHeight: 24, isBuiltIn: notch != nil,
                    notch: notch.map { CGRect(x: $0.minX, y: 900 - 24, width: $0.width, height: 24) })
    }

    func scene(_ kdl: String, css: String = "", display: DisplayInfo? = nil,
               content: [String: Node] = [:], interaction: SceneBuilder.Interaction = .init()) throws -> Scene {
        let config = try ConfigLoader.parse(kdl)
        let sheet = try Stylesheet.parse(css)
        let builder = SceneBuilder(cascade: Cascade(stylesheet: sheet), metrics: metrics)
        var states: [String: ModuleHost.ItemState] = [:]
        for item in config.bars[0].items.flatMap(\.flattened) {
            var state = ModuleHost.ItemState()
            state.result = RenderResult(content: content[item.name] ?? .text(item.name))
            state.rendered = true
            states[item.name] = state
        }
        return builder.build(bar: config.bars[0], display: display ?? self.display(),
                             items: config.bars[0].items, states: states, interaction: interaction)
    }

    @Test("items lay out left to right inside the bar's padding")
    func basics() throws {
        let scene = try scene("""
        bar { item "a" module="text"
              item "bb" module="text" }
        """, css: "bar { padding: 0 8pt; gap: 6pt } item { padding: 0 }")
        #expect(scene.rows.count == 1)
        let items = scene.rows[0].items
        #expect(items.count == 2)
        #expect(items[0].frame.x == 8)
        #expect(items[0].frame.w == 6)          // "a" at 12pt
        #expect(items[1].frame.x == 8 + 6 + 6)
        #expect(items[1].frame.w == 12)         // "bb"
        #expect(scene.bounds.height == 24)
    }

    @Test("padding and border widen an item")
    func chrome() throws {
        let scene = try scene(#"bar { item "a" module="text" }"#,
                              css: "bar { padding: 0 } item { padding: 2pt 9pt; border: 1pt #000 }")
        #expect(scene.rows[0].items[0].frame.w == 6 + 18 + 2)
    }

    @Test("a spacer pushes the items either side of it apart")
    func spacer() throws {
        let scene = try scene("""
        bar { item "a" module="text"
              spacer
              item "b" module="text" }
        """, css: "bar { padding: 0; gap: 0 } item { padding: 0 }")
        let items = scene.rows[0].items
        #expect(items[0].frame.x == 0)
        #expect(items[2].frame.right == 400)
    }

    @Test("left / centre / right falls out of two spacers")
    func threeUp() throws {
        let scene = try scene("""
        bar { item "l" module="text"
              spacer
              item "c" module="text"
              spacer
              item "r" module="text" }
        """, css: "bar { padding: 0; gap: 0 } item { padding: 0 }")
        let items = scene.rows[0].items
        #expect(items[0].frame.x == 0)
        #expect(items[4].frame.right == 400)
        #expect(abs(items[2].frame.cx - 200) < 0.01)
    }

    @Test("items are centred vertically in the bar by default")
    func verticalAlignment() throws {
        let scene = try scene(#"bar { item "a" module="text" }"#, css: "item { padding: 0 }")
        let item = scene.rows[0].items[0]
        #expect(item.frame.h == 14)
        #expect(abs(item.frame.cy - 12) < 0.01)
    }

    @Test("content sits inside the item's padding box")
    func contentPlacement() throws {
        let scene = try scene(#"bar { item "a" module="text" }"#,
                              css: "bar { padding: 0 } item { padding: 2pt 9pt }")
        let item = scene.rows[0].items[0]
        guard let content = item.content else { Issue.record("no content"); return }
        #expect(content.frame.x == item.frame.x + 9)
        #expect(abs(content.frame.cy - item.frame.cy) < 0.01)
    }

    @Test("a group lays its children out as a row")
    func groups() throws {
        let scene = try scene("""
        bar { group "status" { item "a" module="text"; item "b" module="text" } }
        """, css: "bar { padding: 0 } group { gap: 2pt; padding: 0 } item { padding: 0 }")
        let group = scene.rows[0].items[0]
        #expect(group.kind == .group)
        #expect(group.children.count == 2)
        #expect(group.frame.w == 6 + 2 + 6)
        #expect(group.children[0].frame.right + 2 == group.children[1].frame.x)
    }

    @Test("first-child and last-child apply among the survivors")
    func siblingStates() throws {
        let scene = try scene("""
        bar { group "status" { item "a" module="text"; item "b" module="text"; item "c" module="text" } }
        """, css: """
        group item { border-radius: 0 }
        group item:first-child { border-radius: 8pt 0 0 8pt }
        group item:last-child { border-radius: 0 8pt 8pt 0 }
        """)
        let children = scene.rows[0].items[0].children
        #expect(children[0].style.borderRadius.topLeft == 8)
        #expect(children[1].style.borderRadius.isZero)
        #expect(children[2].style.borderRadius.topRight == 8)
    }

    @Test("an item whose module says invisible is not laid out")
    func invisible() throws {
        let config = try ConfigLoader.parse("""
        bar { item "a" module="text"; item "ci" module="data" }
        """)
        let builder = SceneBuilder(cascade: Cascade(stylesheet: Stylesheet()), metrics: metrics)
        var states: [String: ModuleHost.ItemState] = [:]
        states["a"] = ModuleHost.ItemState(result: RenderResult(content: .text("a")), rendered: true)
        states["ci"] = ModuleHost.ItemState(result: RenderResult(visible: false), rendered: true)
        let scene = builder.build(bar: config.bars[0], display: display(),
                                  items: config.bars[0].items, states: states)
        #expect(scene.rows[0].items.map(\.name) == ["a"])
    }

    @Test("an item that has never rendered takes no place: it has nothing to show yet")
    func unrendered() throws {
        let config = try ConfigLoader.parse("""
        bar { item "a" module="text"; item "later" module="text"; item "b" module="text" }
        """)
        let builder = SceneBuilder(cascade: Cascade(stylesheet: Stylesheet()), metrics: metrics)
        var states: [String: ModuleHost.ItemState] = [:]
        states["a"] = ModuleHost.ItemState(result: RenderResult(content: .text("a")), rendered: true)
        states["later"] = ModuleHost.ItemState()
        states["b"] = ModuleHost.ItemState(result: RenderResult(content: nil), rendered: true)
        let scene = builder.build(bar: config.bars[0], display: display(),
                                  items: config.bars[0].items, states: states)
        #expect(scene.rows[0].items.map(\.name) == ["a", "b"])
        #expect(scene.rows[0].items[1].states.contains(.empty), "rendered with nothing is a real state")
    }

    // MARK: Overflow

    @Test("overflow drops the lowest priority first, rightmost of a tie first")
    func overflow() throws {
        let scene = try scene("""
        bar { item "keep" module="text" priority=10
              item "low1" module="text"
              item "low2" module="text" }
        """, css: "bar { padding: 0; gap: 0 } item { padding: 0 }",
        display: display(width: 30))
        // "keep" is 24pt, each "lowN" is 24pt: only one fits.
        #expect(scene.rows[0].items.map(\.name) == ["keep"])
        #expect(scene.hidden.map(\.name) == ["low2", "low1"])
        #expect(scene.hidden[0].states.contains(.overflow))
    }

    @Test("an overflowed item is re-cascaded so the stylesheet can fade it")
    func overflowStyling() throws {
        let scene = try scene("""
        bar { item "keep" module="text" priority=10
              item "gone" module="text" }
        """, css: "bar { padding: 0; gap: 0 } item { padding: 0; opacity: 1 } item:overflow { opacity: 0 }",
        display: display(width: 26))
        #expect(scene.hidden.count == 1)
        #expect(scene.hidden[0].style.opacity == 0)
    }

    // MARK: The notch

    @Test("a notched display splits into two rows")
    func notchSplit() throws {
        let notched = display(width: 400, notch: CGRect(x: 170, y: 0, width: 60, height: 24))
        let scene = try scene("""
        bar { item "a" module="text"
              spacer
              item "clock" module="text"
              spacer
              item "b" module="text" }
        """, css: "bar { padding: 0; gap: 0 } item { padding: 0 }", display: notched)

        #expect(scene.rows.count == 2)
        #expect(scene.rows[0].frame.right == 170)
        #expect(scene.rows[1].frame.x == 230)
        // The straddling spacer is copied to the left row, so the clock hugs the notch.
        #expect(scene.rows[0].items.map(\.name) == ["a", "spacer-2"])
        #expect(scene.rows[1].items.map(\.name) == ["clock", "spacer-4", "b"])
        #expect(scene.rows[1].items[0].frame.x == 230)
        for item in scene.allItems {
            #expect(item.frame.x >= 230 || item.frame.right <= 170)
        }
    }

    @Test("an explicit notch marker splits exactly there")
    func notchMarker() throws {
        let notched = display(width: 400, notch: CGRect(x: 170, y: 0, width: 60, height: 24))
        let scene = try scene("""
        bar { item "a" module="text"
              item "b" module="text"
              notch
              item "c" module="text" }
        """, css: "bar { padding: 0; gap: 0 } item { padding: 0 }", display: notched)
        #expect(scene.rows[0].items.map(\.name) == ["a", "b"])
        #expect(scene.rows[1].items.map(\.name) == ["c"])
    }

    @Test("an item that is not shown before the marker does not move the split")
    func notchMarkerCountsShownItems() throws {
        let notched = display(width: 400, notch: CGRect(x: 170, y: 0, width: 60, height: 24))
        let config = try ConfigLoader.parse("""
        bar { item "gone" module="data"; item "b" module="text"; notch; item "c" module="text" }
        """)
        var states: [String: ModuleHost.ItemState] = [:]
        states["gone"] = ModuleHost.ItemState(result: RenderResult(visible: false), rendered: true)
        states["b"] = ModuleHost.ItemState(result: RenderResult(content: .text("b")), rendered: true)
        states["c"] = ModuleHost.ItemState(result: RenderResult(content: .text("c")), rendered: true)
        let scene = SceneBuilder(cascade: Cascade(stylesheet: Stylesheet()), metrics: metrics)
            .build(bar: config.bars[0], display: notched, items: config.bars[0].items, states: states)
        #expect(scene.rows[0].items.map(\.name) == ["b"])
        #expect(scene.rows[1].items.map(\.name) == ["c"])
    }

    @Test("without a notch, a marker splits at the screen's centre")
    func notchMarkerCentres() throws {
        // 180pt: it fits in a half, but one flex pass over the whole bar would put it across
        // the centre, at 52.5...232.5.
        let wide = String(repeating: "a", count: 30)
        let scene = try scene("""
        bar { spacer; item "\(wide)" module="text"; spacer
              notch
              spacer; item "b" module="text"; spacer }
        """, css: "bar { padding: 0; gap: 4pt } item { padding: 0 }")
        #expect(scene.rows.count == 2)
        #expect(scene.notch == nil)
        #expect(scene.rows[0].frame.right == 198)
        #expect(scene.rows[1].frame.x == 202)
        let left = try #require(scene.allItems.first { $0.name == wide })
        let right = try #require(scene.allItems.first { $0.name == "b" })
        #expect(left.frame.right <= 198)
        #expect(right.frame.x >= 202)
        // Each is centred in its own half.
        #expect(abs(left.frame.midX - 99) < 0.01)
        #expect(abs(right.frame.midX - 301) < 0.01)
    }

    @Test("an if-present marker does nothing without a notch")
    func notchIfPresentPlain() throws {
        let scene = try scene("""
        bar { item "a" module="text"
              spacer
              item "clock" module="text"
              notch "if-present"
              spacer
              item "b" module="text" }
        """, css: "bar { padding: 0; gap: 0 } item { padding: 0 }")
        #expect(scene.rows.count == 1)
        let clock = try #require(scene.allItems.first { $0.name == "clock" })
        #expect(abs(clock.frame.midX - 200) < 0.01)
    }

    @Test("an if-present marker picks the side of the notch")
    func notchIfPresentNotched() throws {
        let notched = display(width: 400, notch: CGRect(x: 170, y: 0, width: 60, height: 24))
        let scene = try scene("""
        bar { item "a" module="text"
              spacer
              item "clock" module="text"
              notch "if-present"
              spacer
              item "b" module="text" }
        """, css: "bar { padding: 0; gap: 0 } item { padding: 0 }", display: notched)
        #expect(scene.rows[0].items.map(\.name) == ["a", "spacer-2", "clock"])
        #expect(scene.rows[0].items[2].frame.right == 170)
        #expect(scene.rows[1].items.map(\.name) == ["spacer-5", "b"])
    }

    @Test("notch \"ignore\" opts out of avoidance entirely")
    func notchIgnore() throws {
        let notched = display(width: 400, notch: CGRect(x: 170, y: 0, width: 60, height: 24))
        let scene = try scene("""
        bar { notch "ignore"
              item "a" module="text"
              spacer
              item "b" module="text" }
        """, css: "bar { padding: 0; gap: 0 }", display: notched)
        #expect(scene.rows.count == 1)
        #expect(scene.notch == nil)
    }

    @Test("notch \"ignore\" treats the display as plain, so a marker splits at the centre")
    func notchIgnoreWithMarker() throws {
        let notched = display(width: 400, notch: CGRect(x: 170, y: 0, width: 60, height: 24))
        let scene = try scene("""
        bar { notch "ignore"
              item "a" module="text"; notch; item "b" module="text" }
        """, css: "bar { padding: 0; gap: 0 } item { padding: 0 }", display: notched)
        #expect(scene.notch == nil)
        #expect(scene.rows.count == 2)
        #expect(scene.rows[1].frame.x == 200)
    }

    // MARK: Content trees

    @Test("a content row measures to its children plus gaps")
    func contentRow() throws {
        let tree = Node.row(gap: 4, align: .center, [
            .icon("wifi"), .text("73", classes: ["pct"]), Node(.meter(Meter(value: 0.7, width: 24))),
        ])
        let scene = try scene(#"bar { item "battery" module="text" }"#,
                              css: "bar { padding: 0 } item { padding: 0 } icon { icon-size: 12pt }",
                              content: ["battery": tree])
        let item = scene.rows[0].items[0]
        #expect(item.frame.w == 12 + 4 + 12 + 4 + 24)
        guard let content = item.content else { Issue.record("no content"); return }
        #expect(content.children.count == 3)
        #expect(content.children[0].frame.x == item.frame.x)
        #expect(content.children[1].frame.x == item.frame.x + 16)
        #expect(content.children[2].frame.w == 24)
    }

    @Test("an icon-only item is a line tall, with the icon centred at its own size")
    func iconOnlyItemHeight() throws {
        let scene = try scene(#"bar { item "logo" module="text"; item "label" module="text" }"#,
                              css: "item { padding: 2pt 4pt } icon { icon-size: 10pt }",
                              content: ["logo": .icon("apple.logo"), "label": .text("abc")])
        let logo = scene.rows[0].items[0]
        let label = scene.rows[0].items[1]
        #expect(logo.frame.h == label.frame.h)
        #expect(logo.frame.h == 14 + 4)
        guard let icon = logo.content else { Issue.record("no content"); return }
        #expect(icon.frame.h == 10)
        #expect(icon.frame.cy == logo.frame.cy)
    }

    @Test("styles reach inside the content tree")
    func contentStyling() throws {
        let tree = Node.row([.text("x", classes: ["pct"])])
        let scene = try scene(#"bar { item "battery" module="text" }"#,
                              css: "#battery .pct { font-size: 20pt }",
                              content: ["battery": tree])
        let text = scene.rows[0].items[0].content?.children[0]
        #expect(text?.style.font.size == 20)
    }

    @Test("hit testing finds the innermost item")
    func hitTesting() throws {
        let scene = try scene("""
        bar { group "status" { item "a" module="text"; item "b" module="text" } }
        """, css: "bar { padding: 0 } group { padding: 0; gap: 0 } item { padding: 0 }")
        let b = scene.rows[0].items[0].children[1]
        #expect(scene.item(at: CGPoint(x: b.frame.midX, y: b.frame.midY))?.name == "b")
    }
}

/// swift-testing's `#expect` compares a `CGFloat` against a `Double` expression as two
/// different types and fails silently, so every geometry assertion here goes through these.
extension CGRect {
    var x: Double { Double(minX) }
    var y: Double { Double(minY) }
    var right: Double { Double(maxX) }
    var top: Double { Double(maxY) }
    var w: Double { Double(width) }
    var h: Double { Double(height) }
    var cx: Double { Double(midX) }
    var cy: Double { Double(midY) }
}
