import AppKit
import Foundation
import Testing
@testable import BarioKit

/// Schemes (PLAN.md step 4): `@scheme`, `scheme()`, and the themes they generate.
@Suite("Schemes")
struct SchemeTests {
    static let seeds: [(String, RGBA)] = [
        ("near-grey", RGBA(r: 0.5, g: 0.5, b: 0.505)),
        ("very light", RGBA(r: 1, g: 0.985, b: 0.91)),
        ("very dark", RGBA(r: 0.04, g: 0.04, b: 0.12)),
        ("red", RGBA(r: 1, g: 0, b: 0)),
        ("yellow", RGBA(r: 1, g: 0.9, b: 0)),
        ("green", RGBA(r: 0.1, g: 0.6, b: 0.2)),
        ("blue", RGBA(r: 0, g: 0.3, b: 1)),
        ("accent", Palette.defaultAccent),
    ]
    static let harmonies: [Harmony] = [.tonal, .analogous, .complementary, .split, .triadic, .monochrome,
                                       .angles(50, 180)]

    func scheme(_ seed: RGBA, _ harmony: Harmony = .tonal, chroma: SchemeRule.Chroma = .scale(1),
                contrast: Double = 4.5, dark: Bool = false) -> Scheme {
        Scheme(Scheme.Key(seed: seed, harmony: harmony, chroma: chroma, contrast: contrast, dark: dark))
    }

    func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    func style(_ css: String, palette: Palette? = nil, dark: Bool = false) throws -> Style {
        let cascade = Cascade(stylesheet: try Stylesheet.parse(css),
                              environment: StyleEnvironment(dark: dark, palette: palette))
        let result = cascade.style(for: [StyleNode(type: "item")])
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
        return result.style
    }

    func color(_ css: String, palette: Palette? = nil, dark: Bool = false) throws -> RGBA? {
        guard case .rgba(let rgba) = try style(css, palette: palette, dark: dark).color else { return nil }
        return rgba
    }

    // MARK: The plan's cases

    @Test("every on- role meets its contrast in every harmony and appearance, whatever the seed")
    func onRolesMeetContrast() {
        var worst = Double.infinity
        for (name, seed) in SchemeTests.seeds {
            for harmony in SchemeTests.harmonies {
                for chroma in [SchemeRule.Chroma.scale(1), .scale(2), .seed] {
                    for dark in [false, true] {
                        let scheme = scheme(seed, harmony, chroma: chroma, dark: dark)
                        for role in Scheme.Role.allCases {
                            for partner in role.partners {
                                let ratio = WCAG.ratio(scheme[role], scheme[partner])
                                worst = min(worst, ratio)
                                let label = "\(name) \(harmony) \(dark ? "dark" : "light")"
                                #expect(ratio >= 4.5, "\(label): \(role.rawValue) on \(partner.rawValue) is \(ratio):1")
                            }
                        }
                        let outline = WCAG.ratio(scheme[.outline], scheme[.surface])
                        #expect(outline >= 3 && outline < 3.05, "\(name): outline is \(outline):1 on surface")
                    }
                }
            }
        }
        #expect(worst >= 4.5)
    }

    @Test("a contrast out of reach comes as close as it can; one in reach is met")
    func higherContrast() {
        for (name, seed) in SchemeTests.seeds {
            for dark in [false, true] {
                let scheme = scheme(seed, contrast: 7, dark: dark)
                for role in Scheme.Role.allCases {
                    for partner in role.partners {
                        let background = scheme[partner]
                        let best = max(WCAG.ratio(WCAG.white, background), WCAG.ratio(WCAG.black, background))
                        let ratio = WCAG.ratio(scheme[role], background)
                        #expect(ratio >= 7 || abs(ratio - best) < 0.01,
                                "\(name) \(role.rawValue): \(ratio):1 where \(min(7, best)):1 was possible")
                    }
                }
            }
        }
    }

    @Test("the pairs start crisp rather than at the bare ratio")
    func crisp() {
        let scheme = scheme(RGBA(r: 0, g: 0.3, b: 1))
        #expect(WCAG.ratio(scheme[.onPrimaryContainer], scheme[.primaryContainer]) > 7)
        #expect(WCAG.ratio(scheme[.onSurface], scheme[.surface]) > 10)
    }

    @Test("monochrome has no chroma anywhere")
    func monochrome() {
        for (_, seed) in SchemeTests.seeds {
            for dark in [false, true] {
                let scheme = scheme(seed, .monochrome, chroma: .scale(3), dark: dark)
                for role in Scheme.Role.allCases {
                    #expect(OKLCH(scheme[role]).c < 0.001, "\(role.rawValue) of \(seed.hex)")
                }
            }
        }
    }

    @Test("named schemes resolve to their own seed")
    func named() throws {
        let palette = WallpaperStyleTests.orange
        let css = """
        @scheme --pop { seed: #0050ff; harmony: 50deg 180deg; }
        @scheme --warm { seed: oklch(from wallpaper(seed) l c calc(h + 20)); }
        """
        let pop = try #require(try color(css + "item { color: scheme(--pop primary) }", palette: palette))
        #expect(hueDistance(OKLCH(pop).h, OKLCH(RGBA(r: 0, g: 0.314, b: 1)).h) < 1)
        let plain = try #require(try color(css + "item { color: scheme(primary) }", palette: palette))
        #expect(hueDistance(OKLCH(plain).h, palette.seeds[0].color.lch.h) < 1, "the unnamed one grows from the wallpaper")
        let warm = try #require(try color(css + "item { color: scheme(--warm primary) }", palette: palette))
        #expect(hueDistance(OKLCH(warm).h, palette.seeds[0].color.lch.h + 20) < 1)
        let tertiary = try #require(try color(css + "item { color: scheme(--pop tertiary) }", palette: palette))
        #expect(hueDistance(OKLCH(tertiary).h, OKLCH(pop).h + 180) < 1, "the harmony's angles, as written")
    }

    @Test("a name no @scheme defines is a parse error; the sheets underneath count")
    func missingName() throws {
        do {
            _ = try Stylesheet.parse("@scheme --a { seed: red }\nbar { color: red }\nitem {\n  color: scheme(--b primary);\n}")
            Issue.record("parsed")
        } catch let error as CSSError {
            #expect(error.message.contains("no @scheme is called --b; this stylesheet has --a"), "\(error)")
            #expect(error.position.line == 4)
        }
        // A socket delta or a user's sheet over a sheet that defines it.
        let under = try Stylesheet.parse("@scheme --b { seed: red }")
        let delta = try Stylesheet.parse("item { color: scheme(--b primary) }", knownSchemes: Set(under.schemes.keys))
        _ = delta
        // The unnamed scheme is always there.
        _ = try Stylesheet.parse("item { color: scheme(on-surface) }")
    }

    // MARK: How it is built

    @Test("the defaults: the wallpaper's seed, tonal, chroma 1, contrast 4.5")
    func defaults() throws {
        let palette = WallpaperStyleTests.blue
        let seed = OKLCH(palette.seeds[0].rgba)
        let primary = OKLCH(try #require(try color("item { color: scheme(primary) }", palette: palette)))
        #expect(abs(primary.l - 0.52) < 0.003)
        #expect(abs(primary.c - 0.13) < 0.003)
        #expect(hueDistance(primary.h, seed.h) < 1)
        let dark = OKLCH(try #require(try color("item { color: scheme(primary) }", palette: palette, dark: true)))
        #expect(abs(dark.l - 0.80) < 0.003, "light or dark is the appearance")

        let explicit = try #require(try color("""
        @scheme { seed: wallpaper(seed); harmony: tonal; chroma: 1; contrast: 4.5; }
        item { color: scheme(primary) }
        """, palette: palette))
        #expect(OKLCH(explicit) == primary)

        let accent = OKLCH(try #require(try color("item { color: scheme(primary) }", palette: nil)))
        #expect(hueDistance(accent.h, OKLCH(Palette.defaultAccent).h) < 1, "no seed, so the accent")
    }

    @Test("harmonies place secondary and tertiary, quietly on the seed's hue where they say so")
    func harmonyHues() {
        let seed = RGBA(r: 0.1, g: 0.6, b: 0.2)
        let h = OKLCH(seed).h
        let tonal = scheme(seed, .tonal)
        #expect(hueDistance(OKLCH(tonal[.secondary]).h, h) < 1)
        #expect(abs(OKLCH(tonal[.secondary]).c - 0.35 * 0.13) < 0.002, "quiet")
        #expect(hueDistance(OKLCH(tonal[.tertiary]).h, h + 60) < 1)
        let triadic = scheme(seed, .triadic)
        #expect(hueDistance(OKLCH(triadic[.secondary]).h, h + 120) < 1)
        #expect(abs(OKLCH(triadic[.secondary]).c - 0.8 * 0.13) < 0.002, "its own hue")
        #expect(abs(OKLCH(triadic[.tertiary]).c - 0.75 * 0.13) < 0.002)
        #expect(hueDistance(OKLCH(scheme(seed, .analogous)[.secondary]).h, h - 30) < 1)
        #expect(hueDistance(OKLCH(scheme(seed, .split)[.tertiary]).h, h + 210) < 1)
        #expect(hueDistance(OKLCH(scheme(seed, .complementary)[.tertiary]).h, h + 180) < 1)
        #expect(OKLCH(tonal[.surface]).c < 0.013, "neutral, almost no chroma")
    }

    @Test("chroma scales, or follows the seed within 0.03 to 0.2")
    func chroma() {
        let dull = RGBA(r: 0.5, g: 0.52, b: 0.47)
        #expect(abs(OKLCH(scheme(dull, chroma: .seed)[.primary]).c - 0.03) < 0.002)
        let vivid = RGBA(r: 1, g: 0, b: 0)
        #expect(abs(OKLCH(scheme(vivid, chroma: .seed)[.primary]).c - 0.2) < 0.002)
        #expect(abs(OKLCH(scheme(vivid, chroma: .scale(0.5))[.primary]).c - 0.065) < 0.002)
    }

    @Test("a scheme's seed may be any colour a bar knows, accent and system() included")
    func seeds() throws {
        let accented = try #require(try color("@scheme { seed: accent }\nitem { color: scheme(primary) }"))
        #expect(hueDistance(OKLCH(accented).h, OKLCH(Palette.defaultAccent).h) < 1)
        let system = try #require(try color("@scheme { seed: system(systemPurpleColor) }\nitem { color: scheme(primary) }"))
        #expect(OKLCH(system).h > 280 && OKLCH(system).h < 330)
    }

    @Test("a later sheet's @scheme replaces an earlier one of the same name, as a socket delta does")
    func layering() throws {
        let base = try Stylesheet.parse("@scheme --pop { seed: red }\nitem { color: scheme(--pop primary) }")
        let delta = try Stylesheet.parse("@scheme --pop { seed: blue }", knownSchemes: Set(base.schemes.keys))
        let style = Cascade(stylesheet: base.appending(delta)).style(for: [StyleNode(type: "item")]).style
        guard case .rgba(let primary) = style.color else {
            Issue.record("not a colour")
            return
        }
        #expect(hueDistance(OKLCH(primary).h, OKLCH(RGBA(r: 0, g: 0, b: 1)).h) < 1)
    }

    @Test("every mistake in a scheme is an error where it is written")
    func errors() {
        func error(_ css: String) -> CSSError? {
            do {
                _ = try Stylesheet.parse("bar { color: red }\n" + css)
                return nil
            } catch {
                return error as? CSSError
            }
        }
        for (css, expected) in [
            ("@scheme {\n seed: red; hue: 30; }", "'hue' is not something @scheme takes"),
            ("@scheme {\n harmony: rainbow; }", "'rainbow' is not a harmony"),
            ("@scheme {\n harmony: 30deg; }", "is not a harmony"),
            ("@scheme {\n contrast: 30; }", "a ratio from 1 to 21"),
            ("@scheme {\n chroma: -1; }", "chroma is 0 or more"),
            ("@scheme {\n seed: currentColor; }", "cannot be currentColor"),
            ("@scheme {\n seed: oklch(from currentColor l c h); }", "cannot be currentColor"),
            ("@scheme {\n seed: var(--brand); }", "cannot read a custom property"),
            ("@scheme {\n seed: wallpaper(vivid); }", "is not something a wallpaper has"),
            ("@scheme {\n seed: rbg(1, 2, 3); }", "not a colour function"),
            ("@scheme pop { seed: red }", "expected { after @scheme"),
            ("@scheme -pop { seed: red }", "a custom name"),
            ("item {\n color: scheme(primary-fill); }", "'primary-fill' is not a scheme's role"),
            ("item {\n color: scheme(--a); }", "'' is not a scheme's role"),
        ] {
            let found = error(css)
            #expect(found?.message.contains(expected) == true, "\(css): \(found?.message ?? "parsed")")
            #expect(found?.position.line == 2 || found?.position.line == 3, "\(css): \(found.map { "\($0.position)" } ?? "")")
        }
    }
}

@Suite("Example themes")
struct ExampleThemeTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("examples/themes")

    @Test("each example theme parses over the built-in look and cascades cleanly, with a palette and without",
          arguments: ["slots.css", "schemes.css"])
    func parses(_ name: String) throws {
        let url = ExampleThemeTests.directory.appendingPathComponent(name)
        let sheet = try Stylesheet.parse(defaultStyleCSS).appending(Stylesheet.parse(contentsOf: url))
        #expect(sheet.usesWallpaper)
        let paths: [[StyleNode]] = [
            [StyleNode(type: "bar"), StyleNode(type: "item", id: "clock")],
            [StyleNode(type: "bar"), StyleNode(type: "item", id: "battery", classes: ["low"])],
            [StyleNode(type: "bar"), StyleNode(type: "item", id: "cpu", classes: ["graph"]), StyleNode(type: "graph")],
        ]
        for palette in [WallpaperStyleTests.orange, nil] {
            for dark in [false, true] {
                let cascade = Cascade(stylesheet: sheet, environment: StyleEnvironment(dark: dark, palette: palette))
                for path in paths {
                    var parent: Style?
                    for depth in 1...path.count {
                        let result = cascade.style(for: Array(path.prefix(depth)), inheriting: parent)
                        #expect(result.diagnostics.isEmpty, "\(name): \(result.diagnostics)")
                        parent = result.style
                    }
                }
            }
        }
    }
}

@Suite("Schemes in the frame loop")
@MainActor
struct SchemeFrameTests {
    @Test("a scheme grows from the new wallpaper's seed, and the bar keeps one per distinct key")
    func followsWallpaper() async throws {
        let h = try await PaletteFrameTests().shown(css: """
        @scheme --pop { seed: accent; harmony: triadic; }
        @scheme --twin { seed: accent; harmony: triadic; }
        item { background: scheme(primary); color: scheme(on-primary); border: 1pt scheme(--pop secondary); }
        """)
        func primary() -> RGBA? {
            guard case .color(.rgba(let rgba)) = h.surface.presentations.last?.scene.allItems.first?.style.background
            else { return nil }
            return rgba
        }
        let orange = try #require(primary())
        #expect(abs(OKLCH(orange).h - WallpaperStyleTests.orange.seeds[0].color.lch.h) < 1)
        #expect(h.loop.bars[0].schemeCache.count == 2, "the unnamed scheme, and one for the two that are the same")

        h.loop.setPalette(WallpaperStyleTests.blue, for: 1)
        await h.settle()
        let blue = try #require(primary())
        #expect(abs(OKLCH(blue).h - WallpaperStyleTests.blue.seeds[0].color.lch.h) < 1)
        #expect(h.loop.bars[0].schemeCache.count == 2, "the orange one is gone")
        #expect(h.loop.bars[0].schemeCache.keys.contains { $0.seed == WallpaperStyleTests.blue.seeds[0].rgba })

        h.loop.dark = true
        await h.settle()
        #expect(h.loop.bars[0].schemeCache.keys.allSatisfy { $0.dark }, "the appearance is part of the key")
        #expect(abs(OKLCH(try #require(primary())).l - 0.80) < 0.003)
    }
}
