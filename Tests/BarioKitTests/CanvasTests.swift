import AppKit
import Testing
@testable import BarioKit

@Suite("Display lists")
struct DisplayListTests {
    func parse(_ json: String) throws -> DisplayList {
        guard let ops = try JSONValue(parsing: json).arrayValue else {
            throw CanvasError("not an array")
        }
        return DisplayList.parse(ops)
    }

    @Test("the design document's ring parses op for op")
    func ring() throws {
        let list = try parse("""
        [
          { "stroke": { "color": "var(--track)", "width": 3 },
            "path": [["arc", 14, 12, 9, 0, 360]] },
          { "stroke": { "color": "currentColor", "width": 3, "cap": "round" },
            "path": [["arc", 14, 12, 9, -90, 162]] },
          { "text": "70", "at": [14, 12], "align": "center", "font": "9pt monospace" }
        ]
        """)
        #expect(list.problems.isEmpty, "\(list.problems)")
        #expect(list.ops.count == 3)

        guard case .stroke(let track, let trackPath) = list.ops[0] else {
            Issue.record("not a stroke"); return
        }
        #expect(track.color == "var(--track)")
        #expect(track.width == 3)
        #expect(trackPath.commands.count == 1)

        guard case .stroke(let value, _) = list.ops[1] else { Issue.record("not a stroke"); return }
        #expect(value.color == "currentColor")
        #expect(value.cap == .round)

        guard case .text(let text) = list.ops[2] else { Issue.record("not text"); return }
        #expect(text.text == "70")
        #expect(text.align == .center)
        #expect(text.font == "9pt monospace")
        #expect(text.at == CGPoint(x: 14, y: 12))
    }

    @Test("every path command")
    func pathCommands() throws {
        let list = try parse("""
        [{ "fill": "red", "path": [
            ["move", 0, 0], ["line", 1, 1], ["quad", 2, 2, 3, 3],
            ["curve", 4, 4, 5, 5, 6, 6], ["arc", 7, 7, 2, 0, 90],
            ["rect", 0, 0, 4, 4], ["round-rect", 0, 0, 4, 4, 1], ["close"]
        ]}]
        """)
        #expect(list.problems.isEmpty)
        guard case .fill(_, let path) = list.ops[0] else { Issue.record("not a fill"); return }
        #expect(path.commands.count == 8)
        #expect(!path.cgPath().isEmpty)
    }

    @Test("every op kind")
    func ops() throws {
        let list = try parse("""
        [
          { "fill": "red", "path": [["rect", 0, 0, 1, 1]] },
          { "stroke": { "color": "#fff", "width": 2, "dash": [2, 2], "join": "bevel" },
            "path": [["line", 1, 1]] },
          { "text": "x", "at": [0, 0] },
          { "image": "gear", "rect": [0, 0, 8, 8] },
          { "image": { "file": "/tmp/x.png" }, "at": [0, 0], "size": [4, 4] },
          { "clip": [["rect", 0, 0, 2, 2]] },
          { "transform": [1, 0, 0, 1, 5, 5] },
          { "translate": [1, 2], "rotate": 45, "scale": 2 },
          { "opacity": 0.5 },
          { "group": [{ "fill": "blue", "path": [["rect", 0, 0, 1, 1]] }] }
        ]
        """)
        #expect(list.problems.isEmpty, "\(list.problems)")
        #expect(list.ops.count == 10)
        guard case .group(let nested) = list.ops[9] else { Issue.record("not a group"); return }
        #expect(nested.ops.count == 1)
        guard case .transform(let matrix) = list.ops[6] else { Issue.record("not a transform"); return }
        #expect(matrix.tx == 5)
    }

    @Test("one bad op is dropped with a reason, the rest still draw")
    func problems() throws {
        let list = try parse("""
        [
          { "fill": "red", "path": [["rect", 0, 0, 1, 1]] },
          { "fill": "red", "path": [["wobble", 1]] },
          { "text": "x" },
          { "nonsense": 1 },
          { "fill": "red", "path": [["move", 1]] },
          { "stroke": { "color": "red", "cap": "flat" }, "path": [["line", 1, 1]] },
          { "fill": "blue", "path": [["rect", 0, 0, 1, 1]] }
        ]
        """)
        #expect(list.ops.count == 2)
        #expect(list.problems.count == 5)
        #expect(list.problems[0].contains("op 1"))
        #expect(list.problems[0].contains("not a path command"))
        #expect(list.problems[1].contains("\"at\""))
        #expect(list.problems[2].contains("no op in"))
        #expect(list.problems[3].contains("needs 2 numbers"))
        #expect(list.problems[4].contains("butt, round or square"))
    }

    @Test("colours resolve against the node's own style")
    func theming() throws {
        var style = Style.initial
        style.color = .accent
        style.custom["--track"] = [.hash("00ff00")]
        let resolver = ColorResolver(accent: RGBA(r: 1, g: 0, b: 0), current: RGBA(r: 1, g: 0, b: 0))
        let painter = CanvasPainter(style: style, resolver: resolver)

        let current = painter.color("currentColor").srgbParts
        #expect(current[0] == 1 && current[1] == 0)
        let track = painter.color("var(--track)").srgbParts
        #expect(track[1] == 1 && track[0] == 0)
        let literal = painter.color("#0000ff").srgbParts
        #expect(literal[2] == 1)
        // Something unreadable is a visible mistake, not an invisible one.
        let bogus = painter.color("not-a-colour").srgbParts
        #expect(bogus[0] == 1 && bogus[2] == 1)
    }

    @Test("the font shorthand builds on the node's font")
    func fonts() throws {
        var style = Style.initial
        style.font = FontSpec(family: .system, weight: 400, size: 12)
        let painter = CanvasPainter(style: style, resolver: ColorResolver())
        #expect(painter.font(from: "9pt monospace") == FontSpec(family: .monospace, weight: 400, size: 9))
        #expect(painter.font(from: "semibold") == FontSpec(family: .system, weight: 600, size: 12))
    }
}

@Suite("Canvas painting")
@MainActor
struct CanvasPaintTests {
    let size = CGSize(width: 60, height: 24)

    func paint(_ ops: String, css: String = "") throws -> CGImage {
        let tree = "{ \"canvas\": { \"width\": 40, \"height\": 20, \"ops\": \(ops) } }"
        let node = try JSONDecoder().decode(Node.self, from: Data(tree.utf8))
        let config = try ConfigLoader.parse(#"bar { item "a" module="text" }"#)
        let sheet = try Stylesheet.parse("bar { padding: 0; background: none } item { padding: 0 }\n" + css)
        let display = DisplayInfo(displayID: 1, name: "T",
                                  frame: CGRect(x: 0, y: 0, width: size.width, height: 900),
                                  scale: 2, stripHeight: size.height)
        let states = ["a": ModuleHost.ItemState(result: RenderResult(content: node), rendered: true)]
        let builder = SceneBuilder(cascade: Cascade(stylesheet: sheet), metrics: CoreTextMetrics())
        let scene = builder.build(bar: config.bars[0], display: display,
                                  items: config.bars[0].items, states: states)
        let backdrop = BackdropImage()
        var resolver = ColorResolver()
        resolver.current = resolver.resolve(scene.style.color)
        guard let image = Offscreen.render(scene, backdrop: backdrop, resolver: resolver, scale: 2) else {
            throw CanvasError("render failed")
        }
        return image
    }

    func pixel(_ image: CGImage, _ x: Double, _ y: Double) -> Offscreen.Pixel {
        Offscreen.pixel(image, atPoint: CGPoint(x: x, y: y), size: size)
            ?? Offscreen.Pixel(r: 0, g: 0, b: 0, a: 0)
    }

    @Test("the origin is the node's top left, with y running down")
    func coordinates() throws {
        // A 10×4 rect at the top of a 40×20 canvas, which sits centred in a 24pt bar.
        let image = try paint(#"[{"fill": "rgb(255,0,0)", "path": [["rect", 0, 0, 10, 4]]}]"#)
        // The canvas box is y 2…22 in bar coordinates, so its top strip is y 18…22.
        #expect(pixel(image, 5, 20).isClose(to: Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1)))
        // …and the bottom of the canvas is untouched.
        #expect(pixel(image, 5, 4).a == 0)
    }

    @Test("currentColor is the item's colour")
    func currentColor() throws {
        let image = try paint(#"[{"fill": "currentColor", "path": [["rect", 0, 0, 40, 20]]}]"#,
                              css: "item { color: rgb(0, 0, 255) }")
        #expect(pixel(image, 20, 12).isClose(to: Offscreen.Pixel(r: 0, g: 0, b: 1, a: 1)))
    }

    @Test("var() in a display list resolves from the cascade")
    func variables() throws {
        let image = try paint(#"[{"fill": "var(--swatch)", "path": [["rect", 0, 0, 40, 20]]}]"#,
                              css: ":root { --swatch: rgb(0, 255, 0) }")
        #expect(pixel(image, 20, 12).isClose(to: Offscreen.Pixel(r: 0, g: 1, b: 0, a: 1)))
    }

    @Test("text is drawn upright, not mirrored")
    func textOrientation() throws {
        // "L" has its ink at the bottom. Drawn upside down, the ink would be at the top.
        let image = try paint("""
        [{"text": "L", "at": [2, 2], "valign": "top", "align": "start",
          "font": "16pt system-ui bold", "color": "rgb(255,0,0)"}]
        """)
        func ink(yRange: ClosedRange<Double>) -> Double {
            var total = 0.0
            for x in stride(from: 2.0, to: 14.0, by: 0.5) {
                for y in stride(from: yRange.lowerBound, to: yRange.upperBound, by: 0.5) {
                    total += pixel(image, x, y).a
                }
            }
            return total
        }
        // In bar coordinates the canvas top is y≈22 and its bottom y≈2; "L" is wide at its base,
        // which is *lower* on screen.
        #expect(ink(yRange: 4...9) > ink(yRange: 15...20))
    }

    @Test("a group's transform does not leak out of it")
    func groups() throws {
        let image = try paint("""
        [
          {"group": [
            {"transform": [1, 0, 0, 1, 20, 0]},
            {"fill": "rgb(255,0,0)", "path": [["rect", 0, 0, 5, 20]]}
          ]},
          {"fill": "rgb(0,0,255)", "path": [["rect", 0, 0, 5, 20]]}
        ]
        """)
        #expect(pixel(image, 22, 12).isClose(to: Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1)))
        #expect(pixel(image, 2, 12).isClose(to: Offscreen.Pixel(r: 0, g: 0, b: 1, a: 1)))
    }

    @Test("a canvas is clipped to its own frame")
    func clipping() throws {
        let image = try paint(#"[{"fill": "rgb(255,0,0)", "path": [["rect", -100, -100, 500, 500]]}]"#)
        // The canvas is 40pt wide inside a 60pt bar; past it, nothing.
        #expect(pixel(image, 20, 12).a > 0.9)
        #expect(pixel(image, 50, 12).a == 0)
    }
}

extension CGColor {
    /// Not named `components`: CGColor already has one, and an extension with the same name
    /// resolves to itself inside its own body and recurses until the stack gives out.
    var srgbParts: [Double] {
        guard let converted = converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        intent: .defaultIntent, options: nil),
              let parts = converted.components else { return [] }
        return parts.map { Double($0) }
    }
}
