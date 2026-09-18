import AppKit
import Testing
@testable import BarioKit

@Suite("Custom renderers")
@MainActor
struct RendererTests {
    static let ringPath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("examples/ring.wat").path

    let size = CGSize(width: 120, height: 24)

    func host(path: String = RendererTests.ringPath, type: String = "ring") -> RendererHost {
        let host = RendererHost()
        host.load([RendererConfig(nodeType: type, path: path, options: .object([:]),
                                  position: .start)], store: StateStore())
        return host
    }

    func scene(_ content: Node, css: String = "", renderers: RendererHost?) throws -> Scene {
        let config = try ConfigLoader.parse(#"bar { item "cpu" module="data" }"#)
        let sheet = try Stylesheet.parse("bar { padding: 0; background: none }\nitem { padding: 0 }\n" + css)
        let display = DisplayInfo(displayID: 1, name: "T",
                                  frame: CGRect(x: 0, y: 0, width: size.width, height: 900),
                                  scale: 2, stripHeight: size.height)
        let states = ["cpu": ModuleHost.ItemState(result: RenderResult(content: content), rendered: true)]
        let builder = SceneBuilder(cascade: Cascade(stylesheet: sheet), metrics: CoreTextMetrics(),
                                   renderers: renderers, resolver: ColorResolver())
        return builder.build(bar: config.bars[0], display: display,
                             items: config.bars[0].items, states: states)
    }

    func node(_ scene: Scene) -> SceneNode? { scene.allItems.first?.content }

    /// Renderers draw at commit, so a drawing is read from the compositor that committed it.
    func drawing(_ scene: Scene, renderers: RendererHost) -> DisplayList? {
        let compositor = Compositor(host: CALayer())
        compositor.commit(Presentation(scene: scene),
                          inputs: Compositor.Inputs(backdrop: BackdropImage(), resolver: ColorResolver(),
                                                    scale: 2, renderers: renderers),
                          sceneChanged: true)
        return compositor.drawing(.node(item: "cpu", key: .path([])))?.list
    }

    // MARK: Registration

    @Test("a registered node type is measured and drawn by its renderer")
    func registration() throws {
        let renderers = host()
        #expect(renderers.nodeTypes == ["ring"])
        #expect(renderers.has("ring"))

        let tree = Node(.custom("ring", .object(["value": .number(0.7)])))
        let scene = try scene(tree, renderers: renderers)
        guard let node = node(scene) else { Issue.record("no content"); return }
        // The renderer said 28×24 when asked to measure.
        #expect(Double(node.frame.width) == 28)
        #expect(node.displayList == nil, "layout measures, and leaves drawing to commit")
        let list = drawing(scene, renderers: renderers)
        #expect(list != nil)
        #expect(list?.problems.isEmpty == true)
        // A track arc and a value arc.
        #expect(list?.ops.count == 2)
    }

    @Test("the value in the node reaches the drawing")
    func valueReachesTheOps() throws {
        let renderers = host()
        func endAngle(_ value: Double) throws -> Double? {
            let tree = Node(.custom("ring", .object(["value": .number(value)])))
            guard let list = drawing(try scene(tree, renderers: renderers), renderers: renderers),
                  list.ops.count > 1,
                  case .stroke(_, let path) = list.ops[1],
                  case .arc(_, _, _, _, let to) = path.commands[0] else { return nil }
            return to
        }
        // -90 is the top; a full turn is 360.
        #expect(try endAngle(0.25) == 0)
        #expect(try endAngle(0.5) == 90)
        #expect(try endAngle(0.7) == 162)      // the design document's own example
        #expect(try endAngle(1) == 270)

        // Nothing to draw at zero: just the track.
        let empty = Node(.custom("ring", .object(["value": .number(0)])))
        #expect(drawing(try scene(empty, renderers: renderers), renderers: renderers)?.ops.count == 1)
    }

    @Test("an unregistered node type takes no room and does not break the bar")
    func unregistered() throws {
        let tree = Node(.custom("sparkle", .object(["value": .number(1)])))
        let scene = try scene(tree, renderers: host())
        #expect(Double(node(scene)?.frame.width ?? -1) == 0)
        #expect(drawing(scene, renderers: host()) == nil)
    }

    @Test("a renderer that is not there is one warning, not a dead bar")
    func missing() {
        let renderers = host(path: "/nowhere/ring.wasm", type: "ring")
        #expect(!renderers.has("ring"))
    }

    // MARK: Theming

    @Test("the style handed to a renderer has colours already resolved")
    func styleJSON() throws {
        var style = Style.initial
        style.color = .accent
        style.strokeWidth = 3
        style.custom["--ring-width"] = [.number(3, unit: "pt")]
        let resolver = ColorResolver(accent: RGBA(r: 1, g: 0, b: 0, a: 1))
        let json = style.json(resolver: resolver)

        #expect(json["color"]?.stringValue == "#ff0000ff")
        #expect(json["stroke-width"]?.doubleValue == 3)
        #expect(json["custom"]?["--ring-width"]?.stringValue == "3pt")
        #expect(json["font"]?["size"]?.doubleValue == 12)
        // currentColor resolves against the node's own colour, so fill follows it.
        #expect(json["fill"]?.stringValue == "#ff0000ff")
    }

    @Test("a renderer's ops are themed by the stylesheet that addresses its node")
    func themingReachesTheOps() throws {
        let renderers = host()
        let tree = Node(.custom("ring", .object(["value": .number(0.7)])))
        let scene = try scene(tree, css: """
        :root { --track: rgb(0, 255, 0) }
        #cpu ring { color: rgb(255, 0, 0); stroke-width: 3pt }
        """, renderers: renderers)
        guard let node = node(scene), let list = drawing(scene, renderers: renderers) else {
            Issue.record("no drawing"); return
        }
        guard case .stroke(let track, _) = list.ops[0],
              case .stroke(let value, _) = list.ops[1] else { Issue.record("not strokes"); return }
        #expect(track.color == "var(--track)")
        #expect(value.color == "currentColor")

        // Both resolve against the node's own style when painted.
        let painter = CanvasPainter(style: node.style, resolver: ColorResolver())
        #expect(painter.color("currentColor").srgbParts[0] == 1)
        #expect(painter.color("var(--track)").srgbParts[1] == 1)
    }

    @Test("a renderer's drawing reaches the pixels")
    func painted() throws {
        let renderers = host()
        let tree = Node(.custom("ring", .object(["value": .number(1)])))
        let scene = try scene(tree, css: "#cpu ring { color: rgb(255, 0, 0); stroke-width: 4pt }",
                              renderers: renderers)
        let backdrop = BackdropImage()
        var resolver = ColorResolver()
        resolver.current = resolver.resolve(scene.style.color)
        guard let image = Offscreen.render(scene, backdrop: backdrop, resolver: resolver, scale: 2,
                                           renderers: renderers),
              let node = node(scene) else { Issue.record("no render"); return }

        // The ring is centred at (14, 12) in the node's own top-left space with radius 9.
        let left = CGPoint(x: node.frame.minX + 14 - 9, y: node.frame.maxY - 12)
        let centre = CGPoint(x: node.frame.minX + 14, y: node.frame.maxY - 12)
        let onStroke = Offscreen.pixel(image, atPoint: left, size: size)
        let inMiddle = Offscreen.pixel(image, atPoint: centre, size: size)
        #expect(onStroke?.isClose(to: Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1), tolerance: 0.15) == true,
                "expected the ring's stroke, got \(String(describing: onStroke))")
        #expect((inMiddle?.a ?? 1) < 0.1, "the middle of a ring is a hole")
    }

    // MARK: Budgets

    @Test("a renderer that overruns is dropped after three strikes")
    func budget() throws {
        let renderers = host()
        renderers.budget = 0        // everything overruns
        let tree = Node(.custom("ring", .object(["value": .number(0.5)])))
        for _ in 0..<3 { _ = try scene(tree, renderers: renderers) }
        #expect(!renderers.has("ring") || renderers.isStale("ring"))
        // And the bar carries on: the node simply takes no room.
        let after = try scene(tree, renderers: renderers)
        #expect(Double(node(after)?.frame.width ?? -1) == 0)
    }
}

@Suite("Rasters")
struct RasterTests {
    /// A 2×2 image of known colours, as premultiplied BGRA.
    static let bgra: [UInt8] = [
        0, 0, 255, 255,   255, 0, 0, 255,      // red, blue
        0, 255, 0, 255,   255, 255, 255, 255,  // green, white
    ]

    @Test("premultiplied BGRA becomes an image")
    func fromMemory() {
        let image = RasterCache.bgra(RasterTests.bgra, width: 2, height: 2)
        #expect(image?.width == 2)
        #expect(image?.height == 2)
        #expect(RasterCache.bgra([1, 2, 3], width: 2, height: 2) == nil)
        #expect(RasterCache.bgra(RasterTests.bgra, width: 0, height: 0) == nil)
    }

    @Test("a raster from a file, and from inline PNG bytes")
    func fromFileAndPNG() throws {
        let cache = RasterCache()
        guard let checker = Shot.checkerboard(width: 8, height: 8, square: 4) else {
            Issue.record("no image"); return
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bario-raster-\(UUID().uuidString.prefix(6)).png")
        PNG.write(checker, to: url.path)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromFile = cache.image(for: .object(["path": .string(url.path)]), width: 8, height: 8)
        #expect(fromFile?.width == 8)

        let data = try Data(contentsOf: url)
        let inline = cache.image(for: .object(["png": .string(data.base64EncodedString())]),
                                 width: 8, height: 8)
        #expect(inline?.width == 8)

        // The second look is cached, and returns the same object.
        #expect(cache.image(for: .object(["path": .string(url.path)]), width: 8, height: 8) === fromFile)
        cache.clear()
    }

    @Test("a raster node is measured at its declared size and painted")
    @MainActor
    func inAScene() throws {
        guard let checker = Shot.checkerboard(width: 16, height: 16, square: 8) else {
            Issue.record("no image"); return
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bario-raster-\(UUID().uuidString.prefix(6)).png")
        PNG.write(checker, to: url.path)
        defer { try? FileManager.default.removeItem(at: url) }

        let tree = Node(.raster(RasterNode(width: 20, height: 16,
                                           source: .object(["path": .string(url.path)]))))
        let config = try ConfigLoader.parse(#"bar { item "a" module="data" }"#)
        let sheet = try Stylesheet.parse("bar { padding: 0; background: none } item { padding: 0 }")
        let display = DisplayInfo(displayID: 1, name: "T",
                                  frame: CGRect(x: 0, y: 0, width: 60, height: 900),
                                  scale: 2, stripHeight: 24)
        let states = ["a": ModuleHost.ItemState(result: RenderResult(content: tree), rendered: true)]
        let builder = SceneBuilder(cascade: Cascade(stylesheet: sheet), metrics: CoreTextMetrics())
        let scene = builder.build(bar: config.bars[0], display: display,
                                  items: config.bars[0].items, states: states)
        guard let node = scene.allItems.first?.content else { Issue.record("no content"); return }
        #expect(Double(node.frame.width) == 20)
        #expect(node.raster != nil)

        var resolver = ColorResolver()
        resolver.current = resolver.resolve(scene.style.color)
        guard let image = Offscreen.render(scene, backdrop: BackdropImage(), resolver: resolver,
                                           scale: 2) else { Issue.record("no render"); return }
        let pixel = Offscreen.pixel(image, atPoint: CGPoint(x: 4, y: 12), size: CGSize(width: 60, height: 24))
        #expect((pixel?.a ?? 0) > 0.9, "the raster should have painted something")
    }

    @Test("an unreadable source is nothing, not a crash")
    func missing() {
        let cache = RasterCache()
        #expect(cache.image(for: .object(["path": .string("/nowhere.png")]), width: 4, height: 4) == nil)
        #expect(cache.image(for: .object(["png": .string("not base64 @@@")]), width: 4, height: 4) == nil)
        #expect(cache.image(for: .object(["ptr": .number(0), "len": .number(16)]),
                            width: 2, height: 2, instance: nil) == nil)
    }
}
