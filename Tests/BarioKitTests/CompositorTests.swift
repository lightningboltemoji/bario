import AppKit
import Testing
@testable import BarioKit

/// The compositor on detached layer trees: what a commit makes, keeps, removes and draws.
/// PLAN.md step 1.
@Suite("Compositor")
@MainActor
struct CompositorTests {
    static let base = "bar { padding: 0; gap: 0; background: none } item { padding: 2pt; background: none }\n"

    let host = CALayer()
    let compositor: Compositor
    let backdrop = BackdropImage()

    init() {
        compositor = Compositor(host: host)
        backdrop.set(Shot.checkerboard(width: 400, height: 48))
    }

    /// On a display with a 24pt menu bar; `height` is the bar's own.
    func scene(_ items: String, css: String = "", content: [String: Node] = [:],
               width: Double = 200, height: Double? = nil) throws -> Scene {
        let config = try ConfigLoader.parse("bar { \(height.map { "height \($0); " } ?? "")\(items) }")
        let sheet = try Stylesheet.parse(CompositorTests.base + css)
        let display = config.strip(on: DisplayInfo(displayID: 1, name: "T",
                                                   frame: CGRect(x: 0, y: 0, width: width, height: 900),
                                                   scale: 2, stripHeight: 24))
        var states: [String: ModuleHost.ItemState] = [:]
        for item in config.bars[0].items.flatMap(\.flattened) {
            states[item.name] = ModuleHost.ItemState(
                result: RenderResult(content: content[item.name] ?? .text(item.name)), rendered: true)
        }
        return SceneBuilder(cascade: Cascade(stylesheet: sheet), metrics: FixedMetrics())
            .build(bar: config.bars[0], display: display, items: config.bars[0].items, states: states)
    }

    @discardableResult
    func commit(_ scene: Scene, hole: Hole = Hole(), scale: CGFloat = 2, dark: Bool = false,
                moving: Bool = false, sceneChanged: Bool = true) -> CommitReport {
        compositor.commit(Presentation(scene: scene, hole: hole, isMoving: moving),
                          inputs: Compositor.Inputs(backdrop: backdrop, resolver: ColorResolver(dark: dark),
                                                    scale: scale),
                          sceneChanged: sceneChanged)
    }

    /// The layer holding an item's drawn pixels: coverage under a tint, or a raster.
    func raster(_ item: String, _ path: [Int] = []) -> CALayer? {
        guard let record = compositor.node(.node(item: item, key: .path(path))) else { return nil }
        return record.role == .coverage ? record.inner : record.leaf
    }

    // MARK: Reconciliation

    @Test("an item keeps its layers across a re-render and a transition")
    func keepsLayers() throws {
        let first = commit(try scene(#"item "a" module="text"; item "b" module="text""#))
        #expect(first.layersMade > 0)
        let a = compositor.layer(for: .item("a"))
        let drawn = raster("a")?.contents as AnyObject?
        #expect(a != nil)

        // New content for "a": the same layer, drawn again.
        let rerender = commit(try scene(#"item "a" module="text"; item "b" module="text""#,
                                        content: ["a": .text("aa")]))
        #expect(compositor.layer(for: .item("a")) === a)
        #expect(rerender.layersMade == 0)
        #expect(rerender.rasters == 1, "only the item whose content changed is drawn")
        #expect(raster("a")?.contents as AnyObject? !== drawn)

        // Mid-transition: a different frame, the same layer, nothing drawn.
        var animator = Animator()
        let before = try scene(#"item "a" module="text"; item "b" module="text""#,
                               css: "bar { transition: layout 100ms linear }", content: ["a": .text("aa")])
        let after = try scene(#"item "a" module="text"; item "b" module="text""#,
                              css: "bar { transition: layout 100ms linear }", content: ["a": .text("aaaaaa")])
        animator.retarget(before, at: 0)
        animator.retarget(after, at: 0)
        commit(try #require(animator.presented(at: 0)), moving: true)
        let b = compositor.layer(for: .item("b"))
        let moving = commit(try #require(animator.presented(at: 0.0371)), moving: true)
        #expect(compositor.layer(for: .item("a")) === a)
        #expect(compositor.layer(for: .item("b")) === b)
        #expect(moving.rasters == 0, "sliding moves layers and draws nothing")
        #expect(moving.layersMade == 0)
    }

    @Test("content that comes to rest off the pixel grid is drawn once more, on it")
    func pixelGrid() throws {
        let scene = try scene(#"item "a" module="text""#)
        commit(scene, scale: 2)
        let item = try #require(scene.allItems.first)
        let nudged = Animator.move(item, to: item.frame.offsetBy(dx: 0.3, dy: 0))
        var moved = scene
        moved.rows[0].items[0] = nudged
        #expect(commit(moved, scale: 2, moving: true).rasters == 0, "moving keeps its pixels")
        let content = try #require(raster("a"))
        #expect(content.frame.minX.truncatingRemainder(dividingBy: 0.5) != 0, "off the grid while it moves")
        #expect(commit(moved, scale: 2).rasters == 1, "at rest, drawn again")
        #expect(raster("a")!.frame.minX.truncatingRemainder(dividingBy: 0.5) == 0, "and on the grid")
        #expect(commit(moved, scale: 2).rasters == 0, "once")
    }

    @Test("items are added, removed and reordered by identity")
    func identity() throws {
        commit(try scene(#"item "a" module="text"; item "b" module="text""#))
        let a = compositor.layer(for: .item("a"))
        let b = compositor.layer(for: .item("b"))

        let reordered = commit(try scene(#"item "b" module="text"; item "c" module="text"; item "a" module="text""#))
        #expect(reordered.layersMade > 0, "c is new")
        #expect(reordered.layersRemoved == 0)
        let c = compositor.layer(for: .item("c"))
        let order = (compositor.root.sublayers ?? []).filter { $0 === a || $0 === b || $0 === c }
        #expect(order.count == 3 && order[0] === b && order[1] === c && order[2] === a,
                "sublayers follow the scene's order")
        #expect(reordered.rasters == 1, "only the new item is drawn")

        let removed = commit(try scene(#"item "c" module="text""#))
        #expect(removed.layersRemoved > 0)
        #expect(compositor.layer(for: .item("a")) == nil)
        #expect(a?.superlayer == nil)
        #expect(compositor.layer(for: .item("c")) === c)
    }

    @Test("spacers named alike are still told apart")
    func spacers() throws {
        let scene = try scene(#"item "a" module="text"; spacer; group "g" { item "b" module="text"; spacer; item "c" module="text" }"#,
                              css: "group { gap: 0 }")
        commit(scene)
        let names = scene.allItems.map(\.name)
        #expect(Set(names).count < names.count, "the fixture has a repeated name")
        #expect(compositor.layer(for: .item("spacer-2")) != nil)
        #expect(compositor.layer(for: .item("spacer-2#1")) != nil)
    }

    // MARK: What draws

    @Test("a hole-only commit sets the mask and draws nothing")
    func holeOnly() throws {
        let scene = try scene(#"item "a" module="text""#, css: "item { background: red }")
        commit(scene)
        let contents = raster("a")?.contents as AnyObject?
        let hole = Hole(center: CGPoint(x: 10, y: 12), radius: 8, strength: 1)
        let report = commit(scene, hole: hole, sceneChanged: false)
        #expect(!report.sceneChanged)
        #expect(report.rasters == 0)
        #expect(report.layersMade == 0)
        #expect(compositor.root.mask === compositor.hole.layer)
        #expect(raster("a")?.contents as AnyObject? === contents)

        // Gone again: no mask at all, so an idle bar composites without one.
        commit(scene, hole: Hole(), sceneChanged: false)
        #expect(compositor.root.mask == nil)
    }

    @Test("text, font, scale and appearance draw an item again; opacity does not")
    func rasterKey() throws {
        commit(try scene(#"item "a" module="text""#))
        #expect(commit(try scene(#"item "a" module="text""#)).rasters == 0, "nothing changed")
        #expect(commit(try scene(#"item "a" module="text""#, content: ["a": .text("b")])).rasters == 1)
        #expect(commit(try scene(#"item "a" module="text""#, css: "item { font-size: 14pt }",
                                 content: ["a": .text("b")])).rasters == 1)
        let styled = try scene(#"item "a" module="text""#, css: "item { font-size: 14pt }", content: ["a": .text("b")])
        #expect(commit(styled, scale: 1).rasters == 1)
        #expect(commit(styled, scale: 1, dark: true).rasters == 1)
        #expect(commit(styled, scale: 1, dark: true).rasters == 0)
        let faded = try scene(#"item "a" module="text""#, css: "item { font-size: 14pt; opacity: 0.4 }",
                              content: ["a": .text("b")])
        #expect(commit(faded, scale: 1, dark: true).rasters == 0, "opacity is the item layer's")
        #expect(compositor.layer(for: .item("a"))?.opacity == 0.4)
    }

    @Test("a new backdrop draws nothing: fills show the new capture")
    func backdropKey() throws {
        let scene = try scene(#"item "a" module="text"; item "b" module="text""#,
                              css: ".glass { background: backdrop }",
                              content: ["b": Node(.text("b"), classes: ["glass"])])
        commit(scene)
        backdrop.set(Shot.checkerboard(width: 400, height: 48, square: 4))
        #expect(commit(scene).rasters == 0)
        let fill = compositor.node(.node(item: "b", key: .path([])))?.chrome.fill
        #expect(fill?.contents as AnyObject? === backdrop.image)
    }

    // MARK: A layer per node

    @Test("a colour change on text or a monochrome symbol is a tint, and draws nothing")
    func tints() throws {
        let content: [String: Node] = ["a": .row(gap: 2, [.icon("wifi"), .text("12:00")])]
        commit(try scene(#"item "a" module="text""#, css: "item { color: rgb(0, 0, 0) }", content: content))
        let text = try #require(compositor.node(.node(item: "a", key: .path([1]))))
        #expect(text.role == .coverage)

        let recoloured = commit(try scene(#"item "a" module="text""#,
                                          css: "item { color: rgb(90, 0, 0) } icon { icon-color: rgb(0, 0, 80) }",
                                          content: content))
        #expect(recoloured.rasters == 0)
        #expect(text.leaf?.backgroundColor == CGColor(srgbRed: 90.0 / 255, green: 0, blue: 0, alpha: 1))
        let icon = try #require(compositor.node(.node(item: "a", key: .path([0]))))
        #expect(icon.leaf?.backgroundColor == CGColor(srgbRed: 0, green: 0, blue: 80.0 / 255, alpha: 1))

        // Light ink is drawn heavier than dark, so crossing sides draws the text once.
        let light = try scene(#"item "a" module="text""#, css: "item { color: rgb(250, 250, 250) }", content: content)
        #expect(commit(light).rasters == 1, "the text, not the symbol")
        #expect(commit(try scene(#"item "a" module="text""#, css: "item { color: rgb(220, 240, 255) }",
                                 content: content)).rasters == 0)
    }

    @Test("contrast: auto flipping retints, and draws only text that changes ink")
    func contrastFlip() throws {
        let content: [String: Node] = ["a": .row(gap: 2, [.icon("wifi"), .text("12:00")])]
        let scene = try scene(#"item "a" module="text""#, css: "item { contrast: auto }", content: content)
        backdrop.set(PaintTestImages.flat(0.95))
        commit(scene)
        let icon = try #require(compositor.node(.node(item: "a", key: .path([0]))))
        let dark = icon.leaf?.backgroundColor
        backdrop.set(PaintTestImages.flat(0.05))
        let flipped = commit(scene)
        #expect(icon.leaf?.backgroundColor != dark, "the symbol's tint followed the backdrop")
        #expect(flipped.rasters == 1, "and only the text was drawn, in light ink")
    }

    @Test("a clock tick draws one node")
    func clockTick() throws {
        func content(_ time: String) -> [String: Node] {
            ["clock": .row(gap: 4, [.icon("clock"), .text(time), Node(.graph(Graph(values: [1, 2, 3])))])]
        }
        commit(try scene(#"item "clock" module="text""#, content: content("12:00")))
        #expect(commit(try scene(#"item "clock" module="text""#, content: content("12:01"))).rasters == 1)
    }

    @Test("a meter's value is a width, and draws nothing")
    func meters() throws {
        func scene(_ value: Double) throws -> Scene {
            try self.scene(#"item "m" module="text""#, css: "meter { fill: red; track: blue }",
                           content: ["m": Node(.meter(Meter(value: value, width: 40)))])
        }
        #expect(commit(try scene(0.25)).rasters == 0)
        let meter = try #require(compositor.node(.node(item: "m", key: .path([]))))
        let fill = try #require(meter.inner)
        #expect(Double(fill.frame.width) == 10)
        #expect(commit(try scene(0.75)).rasters == 0)
        #expect(Double(fill.frame.width) == 30)
        commit(try scene(0))
        #expect(fill.isHidden)
    }

    @Test("a hierarchical symbol's colour is in its pixels, and draws it again")
    func hierarchical() throws {
        let content: [String: Node] = ["a": .icon("wifi")]
        commit(try scene(#"item "a" module="text""#, css: "icon { icon-rendering: hierarchical; icon-color: red }",
                         content: content))
        #expect(compositor.node(.node(item: "a", key: .path([])))?.role == .image)
        #expect(commit(try scene(#"item "a" module="text""#,
                                 css: "icon { icon-rendering: hierarchical; icon-color: blue }",
                                 content: content)).rasters == 1)
    }

    @Test("a node that changes role gets a new layer")
    func roles() throws {
        commit(try scene(#"item "a" module="text""#, content: ["a": .text("x")]))
        let text = compositor.layer(for: .node(item: "a", key: .path([])))
        commit(try scene(#"item "a" module="text""#, content: ["a": Node(.meter(Meter(value: 1, width: 10)))]))
        let meter = compositor.layer(for: .node(item: "a", key: .path([])))
        #expect(text != nil && meter != nil && text !== meter)
        #expect(text?.superlayer == nil)
    }

    @Test("a node with an id keeps its layer when its position changes")
    func nodeIDs() throws {
        commit(try scene(#"item "a" module="text""#,
                         content: ["a": .row(gap: 0, [Node(.text("x"), id: "value")])]))
        let value = compositor.layer(for: .node(item: "a", key: .id("value")))
        #expect(value != nil)
        commit(try scene(#"item "a" module="text""#,
                         content: ["a": .row(gap: 0, [.icon("wifi"), Node(.text("x"), id: "value")])]))
        #expect(compositor.layer(for: .node(item: "a", key: .id("value"))) === value)
    }

    @Test("a commit leaves no animations behind")
    func noImplicitAnimations() throws {
        commit(try scene(#"item "a" module="text""#))
        commit(try scene(#"item "a" module="text"; item "b" module="text""#,
                         css: "item { background: red; border-radius: 4pt; opacity: 0.5 }",
                         content: ["a": .text("moved")]),
               hole: Hole(center: CGPoint(x: 30, y: 12), radius: 10, strength: 0.5))
        func animated(_ layer: CALayer) -> [String] {
            (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animated)
                + (layer.mask.map(animated) ?? [])
        }
        #expect(animated(host).isEmpty)
    }

    // MARK: Transform and animation

    @Test("a transform is the layer's, about its centre")
    func transforms() throws {
        commit(try scene(#"item "a" module="text""#, css: "#a { transform: translate(3pt, 2pt) rotate(90deg) }"))
        let layer = try #require(compositor.layer(for: .item("a")))
        let expected = CATransform3DRotate(CATransform3DMakeTranslation(3, -2, 0), -.pi / 2, 0, 0, 1)
        #expect(CATransform3DEqualToTransform(layer.transform, expected))
        #expect(layer.anchorPoint == CGPoint(x: 0.5, y: 0.5))
    }

    @Test("an animation is added once, kept across commits, and replaced when it changes")
    func animationsAddedOnce() throws {
        let css = "@keyframes spin { to { transform: rotate(360deg) } } icon { animation: spin 1s linear infinite }"
        let content: [String: Node] = ["a": .row(gap: 0, [.icon("gear"), .text("busy")])]
        commit(try scene(#"item "a" module="text""#, css: css, content: content))
        let icon = try #require(compositor.layer(for: .node(item: "a", key: .path([0]))))
        let first = try #require(icon.animation(forKey: "bario.spin.transform.rotation.z") as? CAKeyframeAnimation)
        #expect(first.repeatCount == .infinity)
        #expect(first.values as? [Double] == [0, -2 * .pi], "a full clockwise turn")
        #expect(icon.animationKeys() == ["bario.spin.transform.rotation.z"], "only the component that moves")

        for index in 0..<10 {
            commit(try scene(#"item "a" module="text""#, css: css,
                             content: ["a": .row(gap: 0, [.icon("gear"), .text("busy \(index)")])]))
            #expect(icon.animation(forKey: "bario.spin.transform.rotation.z") === first)
        }

        commit(try scene(#"item "a" module="text""#,
                         css: css.replacingOccurrences(of: "1s", with: "2s"), content: content))
        let second = icon.animation(forKey: "bario.spin.transform.rotation.z")
        #expect(second != nil && second !== first)
        #expect(second?.duration == 2)

        commit(try scene(#"item "a" module="text""#, content: content))
        #expect(icon.animationKeys() == nil || icon.animationKeys()?.isEmpty == true, "gone with its declaration")
    }

    @Test("an animation that has run its course is not started again")
    func finishedAnimations() throws {
        let css = "@keyframes fade { from { opacity: 0 } } #a { animation: fade 100ms }"
        let host = CALayer()
        let compositor = Compositor(host: host)
        func commit(at time: CFTimeInterval) throws {
            compositor.commit(Presentation(scene: try scene(#"item "a" module="text""#, css: css)),
                              inputs: Compositor.Inputs(backdrop: backdrop, resolver: ColorResolver(),
                                                        scale: 2, animationTime: time),
                              sceneChanged: true)
        }
        try commit(at: 10)
        let layer = try #require(compositor.layer(for: .item("a")))
        let fade = try #require(layer.animation(forKey: "bario.fade.opacity"))
        #expect(fade.beginTime == 10)
        layer.removeAllAnimations()
        try commit(at: 10.05)
        let again = layer.animation(forKey: "bario.fade.opacity")
        #expect(again != nil, "lost while it should still run, so added again")
        layer.removeAllAnimations()
        try commit(at: 11)
        #expect(layer.animation(forKey: "bario.fade.opacity") == nil, "over, and not restarted")
    }

    // MARK: Chrome

    @Test("one radius on some corners is maskedCorners; radii that differ are a shape")
    func corners() throws {
        commit(try scene(#"item "a" module="text"; item "b" module="text""#, css: """
        #a { background: red; border-radius: 8pt 0 0 8pt }
        #b { background: red; border-radius: 8pt 4pt }
        """, content: ["a": .text("wide enough"), "b": .text("wide enough")]))
        let a = try #require(compositor.item(.item("a"))?.chrome.fill)
        #expect(Double(a.cornerRadius) == 8)
        #expect(a.maskedCorners == [.layerMinXMaxYCorner, .layerMinXMinYCorner],
                "CSS's top-left and bottom-left, with y running up")
        #expect(a.mask == nil)
        let b = try #require(compositor.item(.item("b"))?.chrome.fill)
        #expect(b.cornerRadius == 0)
        #expect(b.mask is CAShapeLayer)
    }

    // MARK: The bar's height

    @Test("a photograph stops at the bottom of the menu bar; a colour fills the whole bar")
    func hangingBar() throws {
        // 34pt on a 24pt menu bar: 10pt hang below it, over the live screen.
        commit(try scene(#"item "a" module="text""#, css: "bar { background: backdrop }", height: 34))
        #expect(compositor.root.bounds == CGRect(x: 0, y: 0, width: 200, height: 34))
        #expect(compositor.bar.fill?.bounds == CGRect(x: 0, y: 10, width: 200, height: 24))
        #expect(compositor.bar.fill?.contents as AnyObject? === backdrop.image)
        #expect(compositor.rest.fill == nil)

        commit(try scene(#"item "a" module="text""#, css: "bar { background: #336699 }", height: 34))
        #expect(compositor.bar.fill?.bounds == CGRect(x: 0, y: 0, width: 200, height: 34))
        #expect(compositor.bar.fill?.contents == nil)
    }

    @Test("under a bar shorter than the menu bar, the rest of the menu bar is the desktop")
    func shortBar() throws {
        commit(try scene(#"item "a" module="text""#, css: "bar { background: #336699 }", height: 16))
        #expect(compositor.root.bounds == CGRect(x: 0, y: 0, width: 200, height: 24))
        #expect(compositor.bar.fill?.bounds == CGRect(x: 0, y: 8, width: 200, height: 16))
        #expect(compositor.rest.fill?.bounds == CGRect(x: 0, y: 0, width: 200, height: 8))
        #expect(compositor.rest.fill?.contents as AnyObject? === backdrop.image)
        // Beneath the bar, not over it.
        let order = compositor.root.sublayers ?? []
        #expect(order.firstIndex { $0 === compositor.rest.fill }! < order.firstIndex { $0 === compositor.bar.fill }!)
    }

    // MARK: The hole

    @Test("the hole mask covers the bar with the lens at either end")
    func holeAtTheEnds() throws {
        let scene = try scene(#"item "a" module="text""#)
        commit(scene)
        for x in [0.0, 3, 197, 200] {
            commit(scene, hole: Hole(center: CGPoint(x: x, y: 12), radius: 20, strength: 1), sceneChanged: false)
            let mask = compositor.hole
            let lens = mask.lens.frame
            #expect(lens.midX == x && lens.width == 40)
            var covered = lens
            for band in mask.bands {
                #expect(band.frame.width >= 0 && band.frame.height >= 0, "no inverted band at x=\(x)")
                covered = covered.union(band.frame.isEmpty ? covered : band.frame)
            }
            #expect(covered.contains(scene.bounds), "the bands and lens cover the bar at x=\(x)")
            // No band reaches into the lens.
            for band in mask.bands where !band.frame.isEmpty {
                #expect(band.frame.intersection(lens).width <= 0.001 || band.frame.intersection(lens).height <= 0.001)
            }
        }
    }
}

/// Backdrops for tests.
enum PaintTestImages {
    static func flat(_ grey: Double, width: Int = 400, height: Int = 48) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: grey, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
