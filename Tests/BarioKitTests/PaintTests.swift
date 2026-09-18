import AppKit
import Testing
@testable import BarioKit

@Suite("Colour resolution")
struct ColorResolverTests {
    @Test("literals, accent, currentColor and none")
    func basics() {
        let resolver = ColorResolver(dark: false, accent: RGBA(r: 1, g: 0, b: 0),
                                     current: RGBA(r: 0, g: 1, b: 0))
        #expect(resolver.resolve(.rgba(RGBA(r: 0.5, g: 0.5, b: 0.5))).r == 0.5)
        #expect(resolver.resolve(.accent).r == 1)
        #expect(resolver.resolve(.current).g == 1)
        #expect(resolver.resolve(Color.none).a == 0)
    }

    @Test("a mix blends after both ends resolve, so system colours animate")
    func mixing() {
        let resolver = ColorResolver(accent: RGBA(r: 1, g: 0, b: 0), current: RGBA(r: 0, g: 0, b: 1))
        let mixed = resolver.resolve(.mix(.accent, .current, 0.5))
        #expect(abs(Double(mixed.r) - 0.5) < 0.001)
        #expect(abs(Double(mixed.b) - 0.5) < 0.001)
    }

    @Test("system() names follow the appearance")
    @MainActor
    func systemColors() {
        let light = ColorResolver(dark: false).resolve(.system("labelColor"))
        let dark = ColorResolver(dark: true).resolve(.system("labelColor"))
        #expect(light != dark)
        // A name that is not an NSColor is a visible mistake, not an invisible one.
        let bogus = ColorResolver().resolve(.system("notAColorAtAll"))
        #expect(bogus.r == 1 && bogus.b == 1 && bogus.g == 0)
    }
}

@Suite("Rounded rectangles")
struct RoundedRectTests {
    @Test("zero radius is the rect itself")
    func square() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(RoundedRect.path(in: rect, corners: .zero).boundingBox == rect)
    }

    @Test("radii are clamped to half the shorter side")
    func clamping() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 4)
        let path = RoundedRect.path(in: rect, corners: Corners(50))
        #expect(path.boundingBox.width <= 10.001)
        #expect(path.boundingBox.height <= 4.001)
    }

    @Test("one rounded corner leaves the others square")
    func perCorner() {
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        let path = RoundedRect.path(in: rect,
                                    corners: Corners(topLeft: 8, topRight: 0, bottomRight: 0, bottomLeft: 0))
        #expect(path.contains(CGPoint(x: 19, y: 19)))     // square top-right
        #expect(!path.contains(CGPoint(x: 0.5, y: 19.5))) // rounded top-left
    }
}

@Suite("Pixels")
@MainActor
struct PainterTests {
    let size = CGSize(width: 200, height: 24)

    func paint(_ kdl: String, css: String,
               content: [String: Node] = [:],
               hole: Hole = Hole(),
               dark: Bool = false,
               backdrop: CGImage? = nil) throws -> CGImage {
        let config = try ConfigLoader.parse(kdl)
        let sheet = try Stylesheet.parse(css)
        let display = DisplayInfo(displayID: 1, name: "T",
                                  frame: CGRect(x: 0, y: 0, width: size.width, height: 900),
                                  scale: 2, stripHeight: size.height)
        var states: [String: ModuleHost.ItemState] = [:]
        for item in config.bars[0].items.flatMap(\.flattened) {
            states[item.name] = ModuleHost.ItemState(
                result: RenderResult(content: content[item.name] ?? .text(item.name)), rendered: true)
        }
        let builder = SceneBuilder(cascade: Cascade(stylesheet: sheet, dark: dark),
                                   metrics: CoreTextMetrics())
        let scene = builder.build(bar: config.bars[0], display: display,
                                  items: config.bars[0].items, states: states)

        let image = BackdropImage()
        image.set(backdrop ?? Shot.checkerboard(width: 400, height: 48))
        var resolver = ColorResolver(dark: dark)
        resolver.current = resolver.resolve(scene.style.color)
        guard let out = Offscreen.render(scene, backdrop: image, resolver: resolver, hole: hole, scale: 2) else {
            throw ModuleError("render failed")
        }
        return out
    }

    func pixel(_ image: CGImage, _ x: Double, _ y: Double) -> Offscreen.Pixel {
        Offscreen.pixel(image, atPoint: CGPoint(x: x, y: y), size: size)
            ?? Offscreen.Pixel(r: 0, g: 0, b: 0, a: 0)
    }

    @Test("an item's background lands where the layout says it does")
    func background() throws {
        let image = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 4pt; border-radius: 0; background: rgb(255, 0, 0) }
        """)
        let inside = pixel(image, 10, 12)
        #expect(inside.isClose(to: Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1)))
        // Past the item, nothing was painted at all.
        #expect(pixel(image, 190, 12).a == 0)
    }

    @Test("the gap between two bubbles is genuinely transparent")
    func gaps() throws {
        let image = try paint("""
        bar { item "a" module="text"
              item "b" module="text" }
        """, css: """
        bar { padding: 0; gap: 20pt; background: none }
        item { padding: 0; background: rgb(0, 0, 255) }
        """)
        // The gap starts after "a" and is 20pt wide; sample its middle.
        #expect(pixel(image, 0.5, 12).a > 0.9)
        var found = false
        for x in stride(from: 1.0, to: 60.0, by: 1.0) where pixel(image, x, 12).a == 0 { found = true }
        #expect(found, "no transparent pixel between the bubbles")
    }

    @Test("the hole cuts through the bar and the bubbles on it")
    func punch() throws {
        let opaque = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: rgb(0, 128, 0) }
        item { padding: 4pt; background: rgb(255, 0, 0) }
        """)
        #expect(pixel(opaque, 10, 12).a > 0.9)

        let holed = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: rgb(0, 128, 0) }
        item { padding: 4pt; background: rgb(255, 0, 0) }
        """, hole: Hole(center: CGPoint(x: 10, y: 12), radius: 8, feather: 0, strength: 1))
        #expect(pixel(holed, 10, 12).a < 0.05, "the hole did not cut through")
        #expect(pixel(holed, 60, 12).a > 0.9, "the hole cut too much")
    }

    @Test("content never spills out of its bubble")
    func clipping() throws {
        let image = try paint(#"bar { item "a" module="text" max-width=20; item "b" module="text" }"#, css: """
        bar { padding: 0; gap: 10pt; background: none }
        item { padding: 0; background: none; color: rgb(255, 0, 0); font: 20pt system-ui bold }
        """, content: ["a": .text("MMMMMMMMMM"), "b": .text("")])
        var spilled = false
        for x in stride(from: 21.0, to: 29.0, by: 1.0) {
            for y in stride(from: 4.0, to: 20.0, by: 1.0) where pixel(image, x, y).a > 0 { spilled = true }
        }
        #expect(!spilled, "text painted in the gap after a 20pt bubble")
        #expect(pixel(image, 5, 12).a > 0 || pixel(image, 10, 12).a > 0 || pixel(image, 15, 12).a > 0,
                "the text inside the bubble is still there")
    }

    @Test("a group's background is under its items, not over them")
    func groupChrome() throws {
        let image = try paint(#"bar { group "g" { item "a" module="text" } }"#, css: """
        bar { padding: 0; background: none }
        group { padding: 4pt; background: rgb(0, 0, 255) }
        item { padding: 4pt; background: rgb(255, 0, 0) }
        """)
        // In the item's padding, clear of its text.
        #expect(pixel(image, 5, 12).isClose(to: Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1)))
        #expect(pixel(image, 2, 12).isClose(to: Offscreen.Pixel(r: 0, g: 0, b: 1, a: 1)))
    }

    @Test("a group's opacity fades what is inside it")
    func groupOpacity() throws {
        let image = try paint(#"bar { group "g" { item "a" module="text" } }"#, css: """
        bar { padding: 0; background: none }
        group { padding: 0; background: none; opacity: 0.5 }
        item { padding: 4pt; background: rgb(255, 0, 0) }
        """)
        #expect(abs(pixel(image, 1, 12).a - 0.5) < 0.02)
    }

    @Test("border-radius rounds the corner it names")
    func corners() throws {
        let image = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 6pt; background: rgb(255, 0, 0); border-radius: 10pt 0 0 0 }
        """)
        let item = CGPoint(x: 0.6, y: 23.4)          // top-left, inside the rounded-away corner
        #expect(pixel(image, item.x, item.y).a < 0.2)
        #expect(pixel(image, 0.6, 0.6).a > 0.8)      // bottom-left is square
    }

    @Test("@media (prefers-color-scheme: dark) reaches the pixels")
    func darkMode() throws {
        let css = """
        bar { padding: 0; background: none }
        item { padding: 4pt; background: rgb(255, 0, 0) }
        @media (prefers-color-scheme: dark) { item { background: rgb(0, 0, 255) } }
        """
        #expect(try pixel(paint(#"bar { item "a" module="text" }"#, css: css), 10, 12)
                .isClose(to: Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1)))
        #expect(try pixel(paint(#"bar { item "a" module="text" }"#, css: css, dark: true), 10, 12)
                .isClose(to: Offscreen.Pixel(r: 0, g: 0, b: 1, a: 1)))
    }

    @Test("a backdrop background shows the photograph through the bubble")
    func backdropBackground() throws {
        let strip = Shot.checkerboard(width: 400, height: 48, square: 400)!  // a flat grey
        let image = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 6pt; background: backdrop }
        """, backdrop: strip)
        let inside = pixel(image, 6, 12)
        #expect(inside.a > 0.9)
        // Grey, and neither of the two colours anything else here paints.
        #expect(abs(inside.r - inside.g) < 0.01 && abs(inside.g - inside.b) < 0.01)
        #expect(inside.r > 0.3 && inside.r < 0.85)
    }

    @Test("opacity 0 paints nothing")
    func opacity() throws {
        let image = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 4pt; background: rgb(255, 0, 0); opacity: 0 }
        """)
        #expect(pixel(image, 10, 12).a == 0)
    }

    @Test("contrast: auto picks dark text over a light backdrop and light over a dark one")
    func contrast() throws {
        func luminanceOfText(backdropGrey: Double) throws -> Double {
            let ctx = CGContext(data: nil, width: 400, height: 48, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(gray: backdropGrey, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 48))
            let strip = ctx.makeImage()!

            let config = try ConfigLoader.parse(#"bar { item "a" module="text" }"#)
            let sheet = try Stylesheet.parse("""
            bar { padding: 0; background: backdrop }
            item { padding: 0; background: none; contrast: auto; font: 20pt system-ui bold }
            """)
            let display = DisplayInfo(displayID: 1, name: "T",
                                      frame: CGRect(x: 0, y: 0, width: size.width, height: 900),
                                      scale: 2, stripHeight: size.height)
            let states = ["a": ModuleHost.ItemState(
                result: RenderResult(content: .text("MMMM")), rendered: true)]
            let builder = SceneBuilder(cascade: Cascade(stylesheet: sheet), metrics: CoreTextMetrics())
            let scene = builder.build(bar: config.bars[0], display: display,
                                      items: config.bars[0].items, states: states)
            let backdrop = BackdropImage()
            backdrop.set(strip)
            var resolver = ColorResolver()
            resolver.current = resolver.resolve(scene.style.color)
            let image = Offscreen.render(scene, backdrop: backdrop, resolver: resolver, scale: 2)!
            // The darkest pixel in the item's box is the text.
            var darkest = 1.0
            var lightest = 0.0
            for x in stride(from: 1.0, to: 40.0, by: 0.5) {
                for y in stride(from: 4.0, to: 20.0, by: 0.5) {
                    let p = pixel(image, x, y)
                    let l = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
                    darkest = Swift.min(darkest, l)
                    lightest = Swift.max(lightest, l)
                }
            }
            return backdropGrey > 0.5 ? darkest : lightest
        }
        #expect(try luminanceOfText(backdropGrey: 0.95) < 0.3, "expected dark text on a light backdrop")
        #expect(try luminanceOfText(backdropGrey: 0.05) > 0.7, "expected light text on a dark backdrop")
    }

    /// Four colours, one per quadrant of the bar: red top-left, green top-right, blue
    /// bottom-left, white bottom-right.
    static func quadrants(width: Int = 400, height: Int = 48) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width) / 2, h = CGFloat(height) / 2
        for (rect, color) in [(CGRect(x: 0, y: h, width: w, height: h), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
                              (CGRect(x: w, y: h, width: w, height: h), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
                              (CGRect(x: 0, y: 0, width: w, height: h), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
                              (CGRect(x: w, y: 0, width: w, height: h), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))] {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }

    @Test("a bubble on the backdrop shows its own slice of it, the right way up")
    func backdropSlice() throws {
        let image = try paint(#"bar { spacer; item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 5pt 20pt; background: backdrop; color: transparent }
        """, backdrop: PainterTests.quadrants())
        // "a" sits at the right end, so it shows the right half: green above, white below.
        #expect(pixel(image, 195, 20).isClose(to: Offscreen.Pixel(r: 0, g: 1, b: 0, a: 1), tolerance: 0.05))
        #expect(pixel(image, 195, 4).isClose(to: Offscreen.Pixel(r: 1, g: 1, b: 1, a: 1), tolerance: 0.05))
        #expect(pixel(image, 20, 12).a == 0, "nothing on the left")
    }

    @Test("a bar on the backdrop shows all of it, the right way up")
    func backdropBar() throws {
        let image = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: backdrop }
        item { padding: 0; background: none }
        """, content: ["a": .text("")], backdrop: PainterTests.quadrants())
        #expect(pixel(image, 20, 20).isClose(to: Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1), tolerance: 0.05))
        #expect(pixel(image, 180, 20).isClose(to: Offscreen.Pixel(r: 0, g: 1, b: 0, a: 1), tolerance: 0.05))
        #expect(pixel(image, 20, 4).isClose(to: Offscreen.Pixel(r: 0, g: 0, b: 1, a: 1), tolerance: 0.05))
    }

    @Test("a gradient runs the way its angle points")
    func gradients() throws {
        let vertical = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 5pt 40pt; color: transparent;
               background: linear-gradient(180deg, rgb(255, 0, 0), rgb(0, 0, 255)) }
        """, content: ["a": .text("x")])
        let top = pixel(vertical, 20, 23), bottom = pixel(vertical, 20, 1)
        #expect(top.r > 0.9 && top.b < 0.1, "180deg starts at the top, got \(top)")
        #expect(bottom.b > 0.9 && bottom.r < 0.1, "and ends at the bottom, got \(bottom)")

        let horizontal = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 5pt 40pt; color: transparent;
               background: linear-gradient(90deg, rgb(255, 0, 0), rgb(0, 0, 255)) }
        """, content: ["a": .text("x")])
        let left = pixel(horizontal, 1, 12), right = pixel(horizontal, 79, 12)
        #expect(left.r > 0.9 && left.b < 0.1, "90deg starts at the left, got \(left)")
        #expect(right.b > 0.9 && right.r < 0.1, "and ends at the right, got \(right)")
    }

    @Test("the hole's feather and half strength")
    func featheredHole() throws {
        let css = """
        bar { padding: 0; background: rgb(0, 128, 0) }
        item { padding: 0; background: none }
        """
        let image = try paint(#"bar { item "a" module="text" }"#, css: css, content: ["a": .text("")],
                              hole: Hole(center: CGPoint(x: 100, y: 12), radius: 12, feather: 8, strength: 0.5))
        // Clear in the middle at half strength, fading over the feather, untouched past it.
        #expect(abs(pixel(image, 100, 12).a - 0.5) < 0.04, "\(pixel(image, 100, 12))")
        #expect(abs(pixel(image, 108, 12).a - 0.75) < 0.08, "\(pixel(image, 108, 12))")
        #expect(pixel(image, 113, 12).a > 0.97)
        #expect(pixel(image, 150, 12).a > 0.99)
    }

    @Test("content is clipped to a rounded bubble")
    func roundedClip() throws {
        let canvas = Node(.canvas(CanvasNode(width: 60, height: 24, ops: [
            .object(["fill": .string("rgb(255, 0, 0)"),
                     "path": .array([.array([.string("rect"), .number(-10), .number(-10),
                                             .number(100), .number(100)])])]),
        ])))
        let image = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 0; background: none; border-radius: 12pt }
        """, content: ["a": canvas])
        #expect(pixel(image, 30, 12).isClose(to: Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1)))
        #expect(pixel(image, 0.5, 23.5).a < 0.05, "the rounded corner clips the drawing")
        #expect(pixel(image, 59.5, 0.5).a < 0.05)
    }

    @Test("text takes its tint")
    func textTint() throws {
        let image = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 0; background: none; color: rgb(255, 0, 0); font: 20pt system-ui bold }
        """, content: ["a": .text("MMMM")])
        var inked = 0
        for x in stride(from: 1.0, to: 60.0, by: 0.5) {
            for y in stride(from: 2.0, to: 22.0, by: 0.5) {
                let p = pixel(image, x, y)
                guard p.a > 0.95 else { continue }
                inked += 1
                #expect(p.r > 0.97 && p.g < 0.03 && p.b < 0.03, "\(p) at \(x), \(y)")
            }
        }
        #expect(inked > 50, "the text drew")
    }

    @Test("a meter fills as far as its value", arguments: [0.0, 0.5, 1.0])
    func meter(_ value: Double) throws {
        let image = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 0; background: none }
        meter { fill: rgb(255, 0, 0); track: rgb(0, 0, 255); stroke-width: 5pt }
        """, content: ["a": Node(.meter(Meter(value: value, width: 40)))])
        // 40×10, centred: y 7…17. Sample the middle of each quarter, clear of the round ends.
        let red = Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1), blue = Offscreen.Pixel(r: 0, g: 0, b: 1, a: 1)
        #expect(pixel(image, 12, 12).isClose(to: value > 0 ? red : blue), "\(pixel(image, 12, 12))")
        #expect(pixel(image, 28, 12).isClose(to: value > 0.5 ? red : blue), "\(pixel(image, 28, 12))")
        #expect(pixel(image, 45, 12).a == 0, "nothing past the meter")
    }

    @Test("a hierarchical symbol keeps its own shades of its colour")
    func hierarchicalSymbol() throws {
        func opaque(_ rendering: String) throws -> (count: Int, reddish: Bool) {
            let image = try paint(#"bar { item "a" module="text" }"#, css: """
            bar { padding: 0; background: none }
            item { padding: 0; background: none }
            icon { icon-size: 20pt; icon-color: rgb(255, 0, 0); icon-rendering: \(rendering) }
            """, content: ["a": .icon("speaker.wave.3.fill")])
            var count = 0
            var reddish = true
            for x in stride(from: 0.0, to: 40.0, by: 0.5) {
                for y in stride(from: 0.0, to: 24.0, by: 0.5) {
                    let p = pixel(image, x, y)
                    if p.a > 0.9 { count += 1 }
                    if p.a > 0.2, !(p.r > 0.8 && p.g < 0.2 && p.b < 0.2) { reddish = false }
                }
            }
            return (count, reddish)
        }
        let flat = try opaque("monochrome")
        let shaded = try opaque("hierarchical")
        #expect(flat.reddish && shaded.reddish)
        #expect(flat.count > 100)
        #expect(Double(shaded.count) < Double(flat.count) * 0.9,
                "the waves are lighter than the speaker: \(shaded.count) against \(flat.count)")
    }

    @Test("offscreen, an animation is shown as far into it as asked: a quarter of a clockwise turn")
    func animationOffscreen() throws {
        // A bar from the centre of a 20×20 canvas to its right edge.
        let canvas = Node(.canvas(CanvasNode(width: 20, height: 20, ops: [
            .object(["fill": .string("rgb(255, 0, 0)"),
                     "path": .array([.array([.string("rect"), .number(10), .number(8),
                                             .number(10), .number(4)])])]),
        ])))
        let config = try ConfigLoader.parse(#"bar { item "a" module="text" }"#)
        let sheet = try Stylesheet.parse("""
        bar { padding: 0; background: none }
        item { padding: 0; background: none }
        @keyframes spin { to { transform: rotate(360deg) } }
        canvas { animation: spin 1s linear infinite }
        """)
        let display = DisplayInfo(displayID: 1, name: "T", frame: CGRect(x: 0, y: 0, width: 20, height: 900),
                                  scale: 2, stripHeight: 24)
        let scene = SceneBuilder(cascade: Cascade(stylesheet: sheet), metrics: CoreTextMetrics())
            .build(bar: config.bars[0], display: display, items: config.bars[0].items,
                   states: ["a": ModuleHost.ItemState(result: RenderResult(content: canvas), rendered: true)])
        let size = CGSize(width: 20, height: 24)
        func image(at time: Double) throws -> CGImage {
            try #require(Offscreen.render(scene, backdrop: BackdropImage(), resolver: ColorResolver(),
                                          scale: 2, at: time))
        }
        func alpha(_ image: CGImage, _ x: Double, _ y: Double) -> Double {
            Offscreen.pixel(image, atPoint: CGPoint(x: x, y: y), size: size)?.a ?? 0
        }
        // The canvas is centred at (10, 12), y up.
        let start = try image(at: 0)
        #expect(alpha(start, 16, 12) > 0.9, "at its start, the bar points right")
        #expect(alpha(start, 10, 6) < 0.1)
        let quarter = try image(at: 0.25)
        #expect(alpha(quarter, 16, 12) < 0.1, "a quarter in, it no longer points right")
        #expect(alpha(quarter, 10, 6) > 0.9, "it points down, having turned clockwise")
        #expect(alpha(quarter, 10, 18) < 0.1)
    }

    @Test("a raster shows its first row at the top")
    func rasterOrientation() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bario-quadrants-\(UUID().uuidString.prefix(6)).png")
        PNG.write(PainterTests.quadrants(width: 40, height: 20), to: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        let node = Node(.raster(RasterNode(width: 40, height: 20, source: .object(["path": .string(url.path)]))))
        let image = try paint(#"bar { item "a" module="text" }"#, css: """
        bar { padding: 0; background: none }
        item { padding: 0; background: none }
        """, content: ["a": node])
        // The raster is centred: y 2…22. Red was drawn top-left.
        #expect(pixel(image, 5, 18).isClose(to: Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1), tolerance: 0.05))
        #expect(pixel(image, 5, 6).isClose(to: Offscreen.Pixel(r: 0, g: 0, b: 1, a: 1), tolerance: 0.05))
    }
}

@Suite("Backdrop sampling")
struct BackdropTests {
    @Test("mean luminance reads the region it is given")
    func luminance() throws {
        let ctx = CGContext(data: nil, width: 100, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 20))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 20))

        let backdrop = BackdropImage(image: ctx.makeImage())
        let barSize = CGSize(width: 100, height: 20)
        let left = backdrop.meanLuminance(in: CGRect(x: 0, y: 0, width: 40, height: 20), barSize: barSize)
        let right = backdrop.meanLuminance(in: CGRect(x: 60, y: 0, width: 40, height: 20), barSize: barSize)
        #expect((left ?? 1) < 0.1)
        #expect((right ?? 0) > 0.9)
    }

    @Test("with no photograph there is nothing to sample")
    func empty() {
        let backdrop = BackdropImage()
        #expect(backdrop.meanLuminance(in: CGRect(x: 0, y: 0, width: 10, height: 10),
                                       barSize: CGSize(width: 10, height: 10)) == nil)
    }
}
