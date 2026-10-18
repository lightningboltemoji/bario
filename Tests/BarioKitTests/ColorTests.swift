import Foundation
import Testing
@testable import BarioKit

/// Oklab, gamut mapping, contrast, and the CSS Color 4 and 5 functions built on them
/// (PLAN.md step 1).
@Suite("Colour")
struct ColorTests {
    func color(_ value: String) throws -> Color {
        let sheet = try Stylesheet.parse("item { color: \(value) }")
        var style = Style()
        let declaration = sheet.rules[0].declarations[0]
        try style.apply(.color, declaration.value, at: declaration.position)
        return style.color
    }

    func rgba(_ value: String) throws -> RGBA {
        guard case .rgba(let rgba) = try color(value) else {
            Issue.record("\(value) did not fold to a colour")
            return RGBA(r: 1, g: 0, b: 1)
        }
        return rgba
    }

    func message(_ css: String) -> CSSError? {
        do {
            _ = try Stylesheet.parse(css)
            return nil
        } catch {
            return error as? CSSError
        }
    }

    func close(_ a: RGBA, _ b: RGBA, within tolerance: Double = 0.002) -> Bool {
        abs(Double(a.r - b.r)) <= tolerance && abs(Double(a.g - b.g)) <= tolerance
            && abs(Double(a.b - b.b)) <= tolerance && abs(Double(a.a - b.a)) <= tolerance
    }

    // MARK: Oklab

    @Test("sRGB converts to OKLCH as Oklab says it should")
    func conversions() {
        let red = OKLCH(RGBA(r: 1, g: 0, b: 0))
        #expect(abs(red.l - 0.628) < 0.001)
        #expect(abs(red.c - 0.258) < 0.001)
        #expect(abs(red.h - 29.2) < 0.1)

        let white = OKLCH(RGBA(r: 1, g: 1, b: 1))
        #expect(abs(white.l - 1) < 1e-4)
        #expect(white.c < OKLCH.achromatic)
        #expect(white.h == 0, "a grey has no hue")

        let blue = OKLCH(RGBA(r: 0, g: 0, b: 1))
        #expect(abs(blue.l - 0.452) < 0.001)
        #expect(abs(blue.c - 0.313) < 0.001)
        #expect(abs(blue.h - 264.05) < 0.1)
    }

    @Test("colours go to Oklab and back unchanged")
    func roundTrips() {
        for r in stride(from: 0.0, through: 1, by: 0.125) {
            for g in stride(from: 0.0, through: 1, by: 0.125) {
                for b in stride(from: 0.0, through: 1, by: 0.125) {
                    let color = RGBA(r: r, g: g, b: b)
                    #expect(close(OKLCH(color).rgba(), color, within: 1e-6), "\(color)")
                    #expect(close(Oklab(color).rgba(), color, within: 1e-6), "\(color)")
                }
            }
        }
    }

    @Test("a colour beyond sRGB comes in by chroma alone, keeping lightness and hue")
    func gamutMapping() {
        for h in stride(from: 0.0, to: 360, by: 15) {
            for l in [0.2, 0.5, 0.7, 0.9] {
                let wild = OKLCH(l: l, c: 0.4, h: h)
                #expect(!wild.inSRGB)
                let mapped = OKLCH(wild.rgba())
                #expect(abs(mapped.l - l) < 0.002, "L \(l) h \(h) came back as \(mapped)")
                #expect(abs(mapped.h - h) < 0.5 || abs(abs(mapped.h - h) - 360) < 0.5,
                        "L \(l) h \(h) came back as \(mapped)")
                #expect(mapped.c < 0.4)
                #expect(abs(mapped.c - OKLCH.maxChroma(l: l, h: h)) < 0.002)
            }
        }
        #expect(OKLCH(l: 1.2, c: 0.1, h: 30).rgba() == RGBA(r: 1, g: 1, b: 1))
        #expect(OKLCH(l: -0.1, c: 0.1, h: 30).rgba() == RGBA(r: 0, g: 0, b: 0))
    }

    @Test("contrast is WCAG's, from 1 to 21")
    func contrast() {
        #expect(WCAG.ratio(WCAG.black, WCAG.white) == 21)
        #expect(WCAG.ratio(WCAG.white, WCAG.black) == 21)
        #expect(WCAG.ratio(RGBA(r: 0.3, g: 0.6, b: 0.2), RGBA(r: 0.3, g: 0.6, b: 0.2)) == 1)
        // #767676 is the classic just-passing grey on white.
        let grey = RGBA(r: 0x76 / 255.0, g: 0x76 / 255.0, b: 0x76 / 255.0)
        #expect(abs(WCAG.ratio(grey, WCAG.white) - 4.54) < 0.01)
        #expect(WCAG.contrastColor(RGBA(r: 1, g: 1, b: 0)) == WCAG.black)
        #expect(WCAG.contrastColor(RGBA(r: 0, g: 0, b: 0.6)) == WCAG.white)
    }

    // MARK: on()

    @Test("on() reaches 4.5:1 against every colour, and comes as close as it can to more")
    func onReaches() {
        var worst = Double.infinity
        for l in stride(from: 0.0, through: 1, by: 0.05) {
            for c in stride(from: 0.0, through: 0.3, by: 0.05) {
                for h in stride(from: 0.0, to: 360, by: 30) {
                    let background = OKLCH(l: l, c: c, h: h).rgba()
                    let ratio = WCAG.ratio(OKLCH.on(background), background)
                    worst = min(worst, ratio)
                    #expect(ratio >= 4.5, "on() of \(background.hex) is only \(ratio):1")

                    let best = max(WCAG.ratio(WCAG.white, background), WCAG.ratio(WCAG.black, background))
                    for asked in [7.0, 12, 21] {
                        let got = WCAG.ratio(OKLCH.on(background, ratio: asked), background)
                        if best >= asked {
                            #expect(got >= asked, "on(\(background.hex), \(asked)) is \(got):1")
                        } else {
                            #expect(abs(got - best) < 0.01,
                                    "on(\(background.hex), \(asked)) is \(got):1 where \(best):1 was possible")
                        }
                    }
                }
            }
        }
        #expect(worst >= 4.5)
    }

    @Test("on() keeps the colour's hue, and starts crisp rather than at the bare ratio")
    func onKeepsHue() {
        let blue = OKLCH(l: 0.45, c: 0.2, h: 260).rgba()
        let partner = OKLCH(OKLCH.on(blue))
        #expect(partner.l > 0.9, "white contrasts more with a dark blue, so it goes light")
        #expect(abs(partner.h - 260) < 3)
        #expect(WCAG.ratio(OKLCH.on(blue), blue) > 6, "crisp, not stopped at 4.5")

        let butter = OKLCH(l: 0.92, c: 0.08, h: 95).rgba()
        let ink = OKLCH(OKLCH.on(butter))
        #expect(abs(ink.l - 0.25) < 0.01, "already readable at its starting lightness")
        #expect(abs(ink.h - 95) < 3)
    }

    // MARK: CSS syntax

    @Test("oklch(), oklab() and the modern rgb() and hsl() parse to the colours they name")
    func absolute() throws {
        #expect(close(try rgba("oklch(0.628 0.2577 29.23)"), RGBA(r: 1, g: 0, b: 0), within: 0.003))
        #expect(close(try rgba("oklch(62.8% 64.4% 29.23deg)"), RGBA(r: 1, g: 0, b: 0), within: 0.003))
        #expect(close(try rgba("oklab(1 0 0)"), RGBA(r: 1, g: 1, b: 1)))
        #expect(try rgba("oklch(0.5 0.1 250 / 50%)").a == 0.5)
        #expect(try rgba("rgb(255 128 0)") == RGBA(r: 1, g: 128 / 255.0, b: 0))
        #expect(try rgba("rgb(255 128 0 / 0.25)").a == 0.25)
        #expect(try rgba("rgba(255, 128, 0, 0.25)") == RGBA(r: 1, g: 128 / 255.0, b: 0, a: 0.25))
        #expect(close(try rgba("hsl(120 100% 25%)"), RGBA(r: 0, g: 0.5, b: 0)))
        #expect(close(try rgba("hsl(0.5turn 100 50)"), RGBA(r: 0, g: 1, b: 1)))
        #expect(try rgba("oklch(0.7 none 30)") == OKLCH(l: 0.7, c: 0, h: 0).rgba())
    }

    @Test("the relative syntax reads the origin's channels, in any of the four spaces")
    func relative() throws {
        let origin = OKLCH(l: 0.6, c: 0.15, h: 40)
        let hex = origin.rgba().hex
        let rotated = OKLCH(try rgba("oklch(from \(hex) l c calc(h + 180))"))
        #expect(abs(rotated.h - 220) < 1)
        #expect(abs(rotated.l - 0.6) < 0.003)

        #expect(close(try rgba("oklch(from \(hex) l c h)"), origin.rgba()))
        #expect(close(try rgba("oklab(from \(hex) l a b)"), origin.rgba()))
        #expect(close(try rgba("rgb(from \(hex) r g b)"), origin.rgba()))
        #expect(close(try rgba("hsl(from \(hex) h s l)"), origin.rgba()))
        #expect(try rgba("rgb(from #ff8000 b g r)") == RGBA(r: 0, g: 128 / 255.0, b: 1))
        #expect(try rgba("rgb(from #ff800080 r g b)").a == 128 / 255.0, "alpha follows the origin")
        #expect(try rgba("rgb(from #ff800080 r g b / 1)").a == 1)
        #expect(try rgba("rgb(from rgb(255, 0, 0) r 255 b)") == RGBA(r: 1, g: 1, b: 0))
        #expect(abs(OKLCH(try rgba("oklch(from \(hex) calc(l + 10%) c h)")).l - 0.7) < 0.003)
    }

    @Test("calc() has precedence, parentheses, and units in the channel's own terms")
    func calc() throws {
        func l(_ expression: String) throws -> Double {
            OKLCH(try rgba("oklch(from #808080 \(expression) 0 0)")).l
        }
        let grey = OKLCH(RGBA(r: 128 / 255.0, g: 128 / 255.0, b: 128 / 255.0)).l
        #expect(abs(try l("calc(0.1 + 0.2 * 2)") - 0.5) < 1e-3)
        #expect(abs(try l("calc((0.1 + 0.2) * 2)") - 0.6) < 1e-3)
        #expect(abs(try l("calc(calc(0.1 + 0.2) * 2)") - 0.6) < 1e-3)
        #expect(abs(try l("calc(0.9 - 0.2 - 0.1)") - 0.6) < 1e-3, "left to right")
        #expect(abs(try l("calc(l / 2)") - grey / 2) < 1e-3)
        #expect(abs(try l("calc(l*2 - 0.5)") - (grey * 2 - 0.5)) < 1e-3)
        #expect(abs(try l("calc(l + 10%)") - (grey + 0.1)) < 1e-3, "a lightness's 100% is 1")
        #expect(abs(try l("calc(l + 2)") - 1) < 1e-4, "clamped")
        #expect(abs(try l("calc(l / 0)") - 1) < 1e-4, "infinite, then clamped, as in CSS")

        #expect(abs(try l("min(l, 0.3)") - 0.3) < 1e-3)
        #expect(abs(try l("max(l, 0.3, 0.2)") - grey) < 1e-3)
        #expect(abs(try l("clamp(0.2, l, 0.4)") - 0.4) < 1e-3)
        #expect(abs(try l("clamp(0.7, l, 0.4)") - 0.7) < 1e-3, "the least wins when they cross, as in CSS")
        #expect(abs(try l("calc(min(l, 0.3) * 2 + 0.1)") - 0.7) < 1e-3)
        #expect(abs(try l("min(l * 2, calc(0.2 + 0.3))") - 0.5) < 1e-3)
        #expect(abs(try l("max(10%, 0.05)") - 0.1) < 1e-3, "percentages in the channel's terms")
        let capped = OKLCH(try rgba("oklch(from oklch(0.6 0.2 140) 0.25 min(c, 0.05) h)"))
        #expect(abs(capped.c - 0.05) < 0.002)
        #expect(abs(capped.h - 140) < 1)

        let hue = OKLCH(try rgba("oklch(from oklch(0.6 0.1 30) l c calc(h + 0.25turn))")).h
        #expect(abs(hue - 120) < 0.5, "a hue takes angles")
        let chroma = OKLCH(try rgba("oklch(from oklch(0.6 0.05 30) l calc(c + 10%) h)")).c
        #expect(abs(chroma - 0.09) < 0.002, "a chroma's 100% is 0.4")
    }

    @Test("color-mix() mixes premultiplied, along the shorter hue, by CSS's percentages")
    func colorMix() throws {
        let fade = try rgba("color-mix(in oklch, #3366cc 70%, transparent)")
        #expect(close(RGBA(r: fade.r, g: fade.g, b: fade.b), RGBA(r: 0x33 / 255.0, g: 0x66 / 255.0, b: 0xcc / 255.0),
                      within: 0.003), "mixing with transparent fades, never darkens")
        #expect(abs(fade.a - 0.7) < 1e-6)

        #expect(try rgba("color-mix(in srgb, white, black)") == RGBA(r: 0.5, g: 0.5, b: 0.5))
        #expect(try rgba("color-mix(in srgb, white 25%, black)") == RGBA(r: 0.25, g: 0.25, b: 0.25))
        #expect(try rgba("color-mix(in srgb, white, black 25%)") == RGBA(r: 0.75, g: 0.75, b: 0.75))
        #expect(try rgba("color-mix(in srgb, 25% white, black)") == RGBA(r: 0.25, g: 0.25, b: 0.25),
                "the percentage may come first")
    }

    @Test("color-mix() keeps a grey from dragging the hue, and normalises its percentages")
    func colorMixHue() throws {
        let tint = OKLCH(try rgba("color-mix(in oklch, oklch(0.6 0.15 250), white)"))
        #expect(abs(tint.h - 250) < 1, "white takes the blue's hue")
        let between = OKLCH(try rgba("color-mix(in oklch, oklch(0.7 0.1 350), oklch(0.7 0.1 30))"))
        #expect(abs(between.h - 10) < 1, "the short way round, through 0")
        #expect(try rgba("color-mix(in srgb, white 40%, black 40%)") == RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.8),
                "under 100% in all is that much transparent")
        #expect(try rgba("color-mix(in srgb-linear, white, black)").r > 0.7, "linear light mixes brighter")
    }

    @Test("contrast-color() and on() fold for known colours")
    func contrastFunctions() throws {
        #expect(try rgba("contrast-color(yellow)") == WCAG.black)
        #expect(try rgba("contrast-color(#123)") == WCAG.white)
        let ink = try rgba("on(#3366cc)")
        #expect(WCAG.ratio(ink, RGBA(r: 0x33 / 255.0, g: 0x66 / 255.0, b: 0xcc / 255.0)) >= 4.5)
        #expect(try rgba("on(#3366cc, 7)") == WCAG.white, "5.4:1 is as far as #3366cc goes")
        let navy = RGBA(r: 0x10 / 255.0, g: 0x20 / 255.0, b: 0x40 / 255.0)
        #expect(WCAG.ratio(try rgba("on(#102040, 12)"), navy) >= 12)
    }

    // MARK: Folding

    @Test("a function of known colours folds; one of accent, currentColor or system() waits for commit")
    func folding() throws {
        #expect(try color("oklch(from red l c calc(h + 50))").constant != nil)
        #expect(try color("color-mix(in oklch, red, oklch(from blue l c h))").constant != nil)
        #expect(try color("on(color-mix(in srgb, red, blue))").constant != nil)

        guard case .relative(let relative) = try color("oklch(from accent l c calc(h + 180))") else {
            Issue.record("should stay symbolic")
            return
        }
        #expect(relative.origin == .accent)
        guard case .mixed = try color("color-mix(in oklab, currentColor, white)") else {
            Issue.record("should stay symbolic")
            return
        }
        guard case .contrast(.system("labelColor")) = try color("contrast-color(system(labelColor))") else {
            Issue.record("should stay symbolic")
            return
        }
        guard case .on(.mixed, let ratio) = try color("on(color-mix(in oklab, accent, black), 7)") else {
            Issue.record("should stay symbolic, inside out")
            return
        }
        #expect(ratio == 7)
    }

    @Test("ColorResolver computes what folding left for commit")
    func resolvedAtCommit() throws {
        let accent = RGBA(r: 0.2, g: 0.4, b: 0.8)
        let resolver = ColorResolver(accent: accent, current: RGBA(r: 1, g: 0, b: 0))
        let hex = accent.hex

        #expect(close(resolver.resolve(try color("oklch(from accent l c calc(h + 180))")),
                      try rgba("oklch(from \(hex) l c calc(h + 180))"), within: 1e-6))
        #expect(close(resolver.resolve(try color("color-mix(in oklch, currentColor 30%, accent)")),
                      try rgba("color-mix(in oklch, red 30%, \(hex))"), within: 1e-6))
        #expect(resolver.resolve(try color("contrast-color(accent)")) == WCAG.white)
        #expect(close(resolver.resolve(try color("on(accent, 7)")), try rgba("on(\(hex), 7)"), within: 1e-6))
    }

    @Test("a transition between two folded colours eases through the colours between")
    func foldedTransition() throws {
        let a = try StyleTests().style("item { background: oklch(0.6 0.15 30) }", [StyleNode(type: "item")])
        let b = try StyleTests().style("item { background: oklch(from oklch(0.6 0.15 30) l c calc(h + 120)) }",
                                       [StyleNode(type: "item")])
        #expect(a.changedProperties(against: b).contains(.background))
        let half = Style.interpolated(from: a, to: b, t: 0.5)
        guard case .color(.rgba(let mid)) = half.background,
              case .color(.rgba(let x)) = a.background, case .color(.rgba(let y)) = b.background else {
            Issue.record("a folded colour eases as a colour, not as a symbolic mix: \(half.background)")
            return
        }
        #expect(mid != x && mid != y)
        #expect(close(mid, RGBA(r: (x.r + y.r) / 2, g: (x.g + y.g) / 2, b: (x.b + y.b) / 2), within: 1e-9))
    }

    // MARK: Tokens and errors

    @Test("+, - and * stand alone as delimiters; with a digit after them they are signs")
    func delimiters() throws {
        let value = try Stylesheet.parse("item { --x: calc(h + 50) calc(h - -5) a*2 +3 -b }").rules[0]
            .declarations[0].value
        #expect(value == [
            .function("calc", [[.ident("h"), .delim("+"), .number(50, unit: nil)]]),
            .function("calc", [[.ident("h"), .delim("-"), .number(-5, unit: nil)]]),
            .ident("a"), .delim("*"), .number(2, unit: nil),
            .number(3, unit: nil), .ident("-b"),
        ])
        #expect(CSSComponent.color(RGBA(r: 1, g: 0.5, b: 0, a: 0.5)).text == "#ff800080")
        #expect(CSSComponent.function("", [[.number(1, unit: nil)]]).text == "(1)")
    }

    @Test("every colour error names the problem and points at its line")
    func errors() {
        let cases: [(String, String)] = [
            ("oklch(from red l x h)", "'x' is not a channel of oklch(); they are l, c, h and alpha"),
            ("oklch(0.5 c 30)", "only the relative syntax"),
            ("oklch(from red l c calc(h +50))", "needs an operator before '50'"),
            ("oklch(from red l c calc(h + ))", "ends with an operator"),
            ("oklch(0.5 0.1 30%)", "a hue is a number of degrees or an angle"),
            ("oklch(0.5 0.1pt 30)", "a chroma is a number or a percentage"),
            ("oklch(0.5 0.1)", "oklch() takes a lightness, a chroma, a hue"),
            ("oklch(from)", "needs a colour after from"),
            ("rgb(1 2 3 / 4 / 5)", "rgb() takes red, green, blue"),
            ("color-mix(in hsv, red, blue)", "mixes in oklab, oklch, srgb or srgb-linear, not 'hsv'"),
            ("color-mix(in oklch, red 120%, blue)", "one percentage from 0% to 100%"),
            ("color-mix(in oklch, red 0%, blue 0%)", "more than 0%"),
            ("color-mix(red, blue)", "color-mix() takes a space and two colours"),
            ("on(red, 30)", "a contrast ratio from 1 to 21"),
            ("oklch(from red l min() h)", "min() takes one or more values"),
            ("oklch(from red l clamp(0, c) h)", "clamp() takes a least, a value and a most"),
            ("oklch(from red l min(c, x) h)", "'x' is not a channel of oklch()"),
            ("contrast-color(red, blue)", "contrast-color() takes one colour"),
            ("hwb(10 20% 30%)", "not a colour function"),
        ]
        for (value, expected) in cases {
            let error = message("bar { color: red }\n\nitem {\n  color: \(value);\n}")
            #expect(error?.message.contains(expected) == true, "\(value): \(error?.message ?? "parsed")")
            #expect(error?.position.line == 4, "\(value): \(error.map { "\($0.position)" } ?? "parsed")")
        }
    }
}
