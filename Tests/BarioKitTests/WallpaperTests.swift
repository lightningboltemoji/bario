import AppKit
import Testing
@testable import BarioKit

/// Palettes as a style input (PLAN.md step 3): `wallpaper()` substituted by the cascade, and the
/// frame loop restyling, waiting and publishing for them.
@Suite("wallpaper() in the stylesheet")
struct WallpaperStyleTests {
    /// Orange is the vibrant slot and the seed; the rest is a dull blue-grey.
    static let orange: Palette = Palette.extract(PaletteTests.image([
        (PaletteTests.vivid(l: 0.66, h: 50), 60),
        (PaletteTests.eightBit(OKLCH(l: 0.55, c: 0.04, h: 240).rgba()), 140),
    ]))
    static let blue: Palette = Palette.extract(PaletteTests.image([
        (PaletteTests.vivid(l: 0.6, h: 255), 60),
        (PaletteTests.eightBit(OKLCH(l: 0.55, c: 0.04, h: 120).rgba()), 140),
    ]))

    func style(_ css: String, palette: Palette?, accent: RGBA = Palette.defaultAccent,
               path: [StyleNode] = [StyleNode(type: "item")]) throws -> Style {
        let cascade = Cascade(stylesheet: try Stylesheet.parse(css),
                              environment: StyleEnvironment(accent: accent, palette: palette))
        var parent: Style?
        for depth in 1...path.count {
            let result = cascade.style(for: Array(path.prefix(depth)), inheriting: parent)
            #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
            parent = result.style
        }
        return parent!
    }

    func background(_ css: String, palette: Palette?, accent: RGBA = Palette.defaultAccent) throws -> RGBA? {
        guard case .color(.rgba(let rgba)) = try style(css, palette: palette, accent: accent).background else {
            return nil
        }
        return rgba
    }

    @Test("a slot becomes the palette's colour, wherever a colour goes")
    func substituted() throws {
        let palette = WallpaperStyleTests.orange
        #expect(palette[.vibrant].found)
        let vibrant = palette[.vibrant].rgba
        #expect(try background("item { background: wallpaper(vibrant) }", palette: palette) == vibrant)

        let style = try self.style("""
        :root { --x: wallpaper(vibrant); --glow: oklch(from wallpaper(vibrant) l c calc(h + 180)); }
        item { color: var(--x); border: 1pt var(--glow);
               background: linear-gradient(90deg, wallpaper(muted), var(--x));
               shadow: 0 1pt 2pt wallpaper(vibrant-dark); }
        """, palette: palette, path: [StyleNode(type: "bar"), StyleNode(type: "item")])
        #expect(style.color == .rgba(vibrant))
        #expect(style.custom["--x"] == [.color(vibrant)], "a custom property carries the real colour")
        #expect(style.custom["--x"]?.text == vibrant.hex, "which a renderer reads as hex")
        guard case .rgba(let glow) = style.borderColor else {
            Issue.record("a relative colour of the wallpaper folds: \(style.borderColor)")
            return
        }
        #expect(abs(OKLCH(glow).h - (OKLCH(vibrant).h + 180).truncatingRemainder(dividingBy: 360)) < 1.5)
        guard case .gradient(let gradient) = style.background else {
            Issue.record("not a gradient")
            return
        }
        #expect(gradient.stops.map(\.color) == [.rgba(palette[.muted].rgba), .rgba(vibrant)])
        #expect(style.shadow?.color == .rgba(palette[.vibrantDark].rgba))
    }

    @Test("a fallback stands in for a made-up slot and for no palette, never for a found one")
    func fallbacks() throws {
        let palette = WallpaperStyleTests.orange
        #expect(!palette[.vibrantDark].found)
        let red = RGBA(r: 1, g: 0, b: 0)
        #expect(try background("item { background: wallpaper(vibrant, red) }", palette: palette)
                == palette[.vibrant].rgba)
        #expect(try background("item { background: wallpaper(vibrant-dark, red) }", palette: palette) == red)
        #expect(try background("item { background: wallpaper(vibrant, red) }", palette: nil) == red)
        #expect(try style("item { background: wallpaper(vibrant, accent) }", palette: nil).background
                == .color(.accent), "a fallback is any colour, symbolic ones too")
        #expect(try background("item { --f: #00ff00; background: wallpaper(muted-light, var(--f)) }",
                               palette: nil) == RGBA(r: 0, g: 1, b: 0))
    }

    @Test("with no palette and no fallback a slot is made up from nothing, and a seed is the accent")
    func nothing() throws {
        let accent = RGBA(r: 0.1, g: 0.7, b: 0.3)
        let vibrant = try #require(try background("item { background: wallpaper(vibrant) }", palette: nil,
                                                  accent: accent))
        #expect(abs(OKLCH(vibrant).h - OKLCH(accent).h) < 1)
        #expect(abs(OKLCH(vibrant).l - 0.64) < 0.01)
        let muted = try #require(try background("item { background: wallpaper(muted) }", palette: nil))
        #expect(OKLCH(muted).c < 0.001, "a grey, there being nothing to take a hue from")
        #expect(try background("item { background: wallpaper(seed) }", palette: nil, accent: accent) == accent)
    }

    @Test("seeds count from the strongest; a missing one is its fallback, or else the first")
    func seeds() throws {
        let palette = WallpaperStyleTests.orange
        #expect(palette.seeds.count == 2)
        let first = palette.seeds[0].rgba, second = palette.seeds[1].rgba
        #expect(try background("item { background: wallpaper(seed) }", palette: palette) == first)
        #expect(try background("item { background: wallpaper(seed 1) }", palette: palette) == first)
        #expect(try background("item { background: wallpaper(seed 2) }", palette: palette) == second)
        #expect(try background("item { background: wallpaper(seed 3) }", palette: palette) == first)
        #expect(try background("item { background: wallpaper(seed 3, white) }", palette: palette)
                == RGBA(r: 1, g: 1, b: 1))
        #expect(try background("item { background: wallpaper(seed 2, white) }", palette: palette) == second)

        let grey = Palette.extract(PaletteTests.image([(RGBA(r: 0.5, g: 0.5, b: 0.5), 10)]))
        let accent = RGBA(r: 0.9, g: 0.3, b: 0.1)
        #expect(try background("item { background: wallpaper(seed) }", palette: grey, accent: accent) == accent)
        #expect(try background("item { background: wallpaper(seed, white) }", palette: grey)
                == RGBA(r: 1, g: 1, b: 1))
    }

    @Test("a slot or seed that does not exist is an error where it is written; the rest waits for the cascade")
    func errors() throws {
        func error(_ value: String) -> CSSError? {
            do {
                _ = try Stylesheet.parse("bar { color: red }\nitem {\n  background: \(value);\n}")
                return nil
            } catch {
                return error as? CSSError
            }
        }
        for (value, expected) in [
            ("wallpaper(vivid)", "'vivid' is not something a wallpaper has; its slots are dominant, vibrant"),
            ("oklch(from wallpaper(seed 5) l c h)", "takes 1 to 4, not '5'"),
            ("wallpaper(seed two)", "takes 1 to 4, not 'two'"),
            ("wallpaper()", "wallpaper() takes a slot or a seed"),
            ("wallpaper(vibrant, red, blue)", "wallpaper() takes a slot or a seed"),
            ("var(--x, wallpaper(nope))", "'nope' is not something a wallpaper has"),
        ] {
            let found = error(value)
            #expect(found?.message.contains(expected) == true, "\(value): \(found?.message ?? "parsed")")
            #expect(found?.position.line == 3, "\(value)")
        }
        // As with var(), the property's own grammar is checked once the colour is known.
        let sheet = try Stylesheet.parse("item { padding: wallpaper(vibrant) }")
        let result = Cascade(stylesheet: sheet).style(for: [StyleNode(type: "item")])
        #expect(result.diagnostics.count == 1)
    }

    @Test("a stylesheet says whether it is coloured from the wallpaper")
    func usesWallpaper() throws {
        #expect(try Stylesheet.parse("item { color: wallpaper(vibrant) }").usesWallpaper)
        #expect(try Stylesheet.parse(":root { --x: oklch(from wallpaper(seed) l c h) }").usesWallpaper)
        #expect(try !Stylesheet.parse("item { color: oklch(from accent l c h) }").usesWallpaper)
    }

    @Test("a display list reaches the wallpaper through var(), and not directly")
    func displayLists() throws {
        let custom: [String: [CSSComponent]] = ["--x": [.color(RGBA(r: 0, g: 0.5, b: 1))]]
        #expect(CanvasPainter.parseColor("var(--x)", custom: custom) == .rgba(RGBA(r: 0, g: 0.5, b: 1)))
        #expect(CanvasPainter.parseColor("oklch(from var(--x) l c h)", custom: custom)?.constant != nil)
        #expect(CanvasPainter.parseColor("wallpaper(vibrant)", custom: custom) == nil,
                "its raster key would not know the palette, so it would never redraw")
    }

    @Test("nothing in the config can be called wallpaper, which is bario's key in the store")
    func reservedKey() {
        for config in [#"bar { item "wallpaper" module="text" }"#,
                       #"source "wallpaper" module="exec" { command "true" }"# + "\nbar { }"] {
            #expect(throws: KDLError.self) { try ConfigLoader.parse(config) }
            do {
                _ = try ConfigLoader.parse(config)
            } catch {
                #expect("\(error)".contains("wallpaper palette"), "\(error)")
            }
        }
    }
}

@Suite("Palettes in the frame loop")
@MainActor
struct PaletteFrameTests {
    let checker = FrameLoopTests.checker

    func background(_ h: Harness, bar: Int = 0) -> RGBA? {
        guard case .color(.rgba(let rgba)) = h.surfaces[bar].presentations.last?.scene.allItems.first?.style.background
        else { return nil }
        return rgba
    }

    /// Bars on screen, each with a palette.
    func shown(_ items: String = #"item "a" module="echo-test""#, css: String, bars: Int = 1,
               palette: Palette = WallpaperStyleTests.orange) async throws -> Harness {
        let h = try Harness(items, css: css, bars: bars)
        await h.start()
        for id in 1...bars {
            h.loop.setBackdrop(checker, for: CGDirectDisplayID(id))
            h.loop.setPalette(palette, for: CGDirectDisplayID(id))
        }
        await h.settle()
        for surface in h.surfaces { #expect(surface.visible) }
        return h
    }

    @Test("a new palette restyles its bar and no other")
    func restylesItsBar() async throws {
        let h = try await shown(css: "item { background: wallpaper(vibrant) }", bars: 2)
        #expect(background(h, bar: 0) == WallpaperStyleTests.orange[.vibrant].rgba)
        let before = h.surfaces.map(\.presentations.count)

        #expect(h.loop.setPalette(WallpaperStyleTests.blue, for: 1))
        await h.settle()
        #expect(h.surfaces[0].presentations.count > before[0])
        #expect(background(h, bar: 0) == WallpaperStyleTests.blue[.vibrant].rgba)
        #expect(h.surfaces[1].presentations.count == before[1], "the other display's bar was not touched")
        #expect(background(h, bar: 1) == WallpaperStyleTests.orange[.vibrant].rgba)
    }

    @Test("an identical palette restyles nothing")
    func identical() async throws {
        let h = try await shown(css: "item { background: wallpaper(vibrant) }")
        let before = h.surface.presentations.count
        let frames = h.loop.frameCount
        #expect(!h.loop.setPalette(WallpaperStyleTests.orange, for: 1))
        #expect(h.scheduler.pending == nil)
        await h.settle()
        #expect(h.loop.frameCount == frames)
        #expect(h.surface.presentations.count == before)
    }

    @Test("the first frame waits for a palette, and comes in wearing its colours")
    func firstFrameWaits() async throws {
        let h = try Harness(#"item "a" module="echo-test""#, css: "item { background: wallpaper(vibrant) }")
        await h.start()
        h.loop.setBackdrop(checker, for: 1)
        await h.settle()
        #expect(!h.surface.visible, "every item rendered and a photograph, but no palette yet")

        h.loop.setPalette(WallpaperStyleTests.orange, for: 1)
        await h.settle()
        #expect(h.surface.visible)
        guard case .color(.rgba(let first))?? = h.surface.orderedInWith.first.map({
            $0?.scene.allItems.first?.style.background
        }) else {
            Issue.record("ordered in with nothing")
            return
        }
        #expect(first == WallpaperStyleTests.orange[.vibrant].rgba, "the wallpaper's colours, not a fallback")
    }

    @Test("the first frame waits for a palette only until the deadline, or a look that found none")
    func firstFrameGivesUp() async throws {
        let late = try Harness(#"item "a" module="echo-test""#, css: "item { background: wallpaper(vibrant) }")
        await late.start()
        late.loop.setBackdrop(checker, for: 1)
        await late.settle()
        #expect(!late.surface.visible)
        late.scheduler.advance(by: late.loop.revealDeadline + 0.01)
        await late.settle()
        #expect(late.surface.visible, "the deadline shows what there is")

        let none = try Harness(#"item "a" module="echo-test" style="background: wallpaper(muted)""#)
        await none.start()
        none.loop.setBackdrop(checker, for: 1)
        await none.settle()
        #expect(!none.surface.visible, "an item's own style asks for the wallpaper too")
        none.loop.foundNoPalette(for: 1)
        await none.settle()
        #expect(none.surface.visible, "there is no palette to wait for")
    }

    @Test("a bar coloured from nothing in the wallpaper does not wait for a palette")
    func noWait() async throws {
        let h = try Harness(#"item "a" module="echo-test""#, css: "item { background: red }")
        await h.start()
        h.loop.setBackdrop(checker, for: 1)
        await h.settle()
        #expect(h.surface.visible)
    }

    @Test("a canvas reading the wallpaper through var() redraws when the palette changes, and not otherwise")
    func canvasRedraws() async throws {
        let name = "swatch-\(UUID().uuidString)"
        ModuleRegistry.register(name) { _ in SwatchModule() }
        let h = try await shown(#"item "a" module="\#(name)""#, css: ":root { --x: wallpaper(vibrant) }")
        let canvas = try #require(h.surface.presentations.last?.scene.allItems.first?.content)
        guard case .canvas = canvas.kind else {
            Issue.record("not a canvas: \(canvas.kind)")
            return
        }

        h.loop.setPalette(WallpaperStyleTests.blue, for: 1)
        await h.settle()
        #expect(h.loop.bars[0].lastCommit?.rasters == 1, "a new vibrant, so the canvas is drawn again")

        var mutedOnly = WallpaperStyleTests.blue
        mutedOnly.slots[.muted] = Slot(color: Oklab(RGBA(r: 0.3, g: 0.6, b: 0.3)), cluster: nil)
        let frames = h.loop.frameCount
        #expect(h.loop.setPalette(mutedOnly, for: 1), "a new palette")
        await h.settle()
        #expect(h.loop.frameCount > frames, "which restyles the bar")
        #expect(h.loop.bars[0].lastCommit?.rasters == 0, "but the canvas's colours did not change, so neither did it")
    }

    @Test("a new wallpaper eases in through the stylesheet's own transition")
    func eases() async throws {
        let h = try await shown(css: "item { background: wallpaper(vibrant); transition: background 100ms linear }")
        let (from, to) = (WallpaperStyleTests.orange[.vibrant].rgba, WallpaperStyleTests.blue[.vibrant].rgba)
        h.loop.setPalette(WallpaperStyleTests.blue, for: 1)
        h.scheduler.run()
        #expect(h.scheduler.pending == .refresh, "moving")
        h.scheduler.advance(by: 0.05)
        h.scheduler.run()
        let mid = try #require(background(h))
        #expect(abs(mid.r - (from.r + to.r) / 2) < 0.02 && abs(mid.b - (from.b + to.b) / 2) < 0.02,
                "halfway between \(from.hex) and \(to.hex), got \(mid.hex)")
        await h.drain()
        #expect(background(h) == to)
    }

    @Test("the palette outlives a stylesheet reload")
    func survivesReload() async throws {
        let h = try await shown(css: "item { background: wallpaper(vibrant) }")
        h.style("item { background: wallpaper(muted) }")
        await h.settle()
        #expect(h.loop.bars[0].palette == WallpaperStyleTests.orange)
        #expect(background(h) == WallpaperStyleTests.orange[.muted].rgba)
    }

    @Test("every display's palette is in the store under wallpaper, the primary's again on its own")
    func store() async throws {
        let h = try await shown(css: "item { background: none }", bars: 2)
        h.loop.setPalette(WallpaperStyleTests.blue, for: 2)
        #expect(await eventually(within: 5) {
            await h.host.store.value(at: "wallpaper.displays")?.arrayValue?.last?["slots"]?["vibrant"]?["hex"]
                == .string(WallpaperStyleTests.blue[.vibrant].rgba.hex)
        })
        let value = try #require(await h.host.store.value(at: "wallpaper"))
        #expect(value["displays"]?.arrayValue?.map { $0["name"] } == [.string("T0"), .string("T1")])
        #expect(value["primary"]?["name"] == .string("T0"))
        #expect(value["primary"]?["primary"] == .bool(true))
        #expect(value["displays"]?.arrayValue?.last?["primary"] == .bool(false))
        #expect(value["primary"] == WallpaperStyleTests.orange.json(display: "T0", id: 1, primary: true))

        h.loop.removeBar(2)
        #expect(await eventually(within: 5) {
            await h.host.store.value(at: "wallpaper.displays")?.arrayValue?.count == 1
        })
    }

    @Test("a new accent re-chooses the made-up slots it coloured, and restyles")
    func accent() async throws {
        let ramp = (0..<100).map { x -> (RGBA, Int) in (RGBA(r: CGFloat(x) / 99, g: CGFloat(x) / 99, b: CGFloat(x) / 99), 1) }
        let grey = Palette.extract(PaletteTests.image(ramp))
        let h = try await shown(css: "item { background: wallpaper(vibrant) }", palette: grey)
        let green = RGBA(r: 0.2, g: 0.7, b: 0.3)
        h.loop.accentChanged(to: green)
        await h.settle()
        let shown = try #require(background(h))
        #expect(abs(OKLCH(shown).h - OKLCH(green).h) < 1)
        #expect(h.loop.bars[0].palette?.accent == green)
    }
}

/// A canvas filled with whatever `--x` is.
actor SwatchModule: Module {
    func render(_ state: StateReader) async throws -> RenderResult {
        let tree = #"{ "canvas": { "width": 20, "height": 10, "ops": [{"fill": "var(--x)", "path": [["rect", 0, 0, 20, 10]]}] } }"#
        return RenderResult(content: try JSONDecoder().decode(Node.self, from: Data(tree.utf8)))
    }
}
