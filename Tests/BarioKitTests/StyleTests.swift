import Testing
@testable import BarioKit

@Suite("Style")
struct StyleTests {
    func message(_ css: String) -> String {
        do {
            _ = try Stylesheet.parse(css)
            return "parsed, but should not have"
        } catch {
            return "\(error)"
        }
    }

    func style(_ css: String, _ path: [StyleNode], dark: Bool = false,
               inline: String = "") throws -> Style {
        let sheet = try Stylesheet.parse(css)
        let cascade = Cascade(stylesheet: sheet, dark: dark)
        let inlineDeclarations = inline.isEmpty ? [] : try Stylesheet.parseDeclarations(inline)
        var parent: Style?
        for depth in 1...path.count {
            let result = cascade.style(for: Array(path.prefix(depth)),
                                       inheriting: parent,
                                       inline: depth == path.count ? inlineDeclarations : [])
            #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
            parent = result.style
        }
        return parent!
    }

    // MARK: Parsing

    @Test("the design document's example stylesheet parses")
    func designExample() throws {
        let sheet = try Stylesheet.parse("""
        :root {
          --fg: system(labelColor);
          --bubble: rgba(255, 255, 255, 0.14);
        }
        bar   { background: backdrop; font: 12pt "SF Pro Text" medium; color: var(--fg); padding: 0 8pt; }
        item  { padding: 2pt 9pt; border-radius: 8pt; background: var(--bubble);
                transition: background 120ms ease-out, opacity 120ms; }
        item:hover { background: rgba(255, 255, 255, 0.24); }
        group#status { gap: 2pt; background: none; }
        group#status item { border-radius: 0; }
        group#status item:first-child { border-radius: 8pt 0 0 8pt; }
        group#status item:last-child  { border-radius: 0 8pt 8pt 0; }
        #battery.low       { background: rgba(255, 70, 70, 0.35); }
        #battery.charging .ico { color: system(systemGreenColor); }
        #clock { font-weight: semibold; }
        @media (prefers-color-scheme: dark) { :root { --bubble: rgba(0, 0, 0, 0.30); } }
        """)
        #expect(sheet.rules.count == 12)
        #expect(sheet.rules.last?.media == MediaQuery(appearance: .dark))
    }

    @Test("the built-in stylesheet parses")
    func builtIn() throws {
        #expect(try Stylesheet.parse(defaultStyleCSS).rules.count > 10)
    }

    @Test("comments and whitespace are not significant")
    func trivia() throws {
        let sheet = try Stylesheet.parse("/* a */ item /* b */ { /* c */ color: red; } ")
        #expect(sheet.rules.count == 1)
        #expect(sheet.rules[0].declarations.count == 1)
    }

    // MARK: Selectors

    @Test("selectors parse into parts, with CSS specificity")
    func selectors() throws {
        func parse(_ text: String) throws -> Selector {
            try SelectorParser.parse(text, at: .start)
        }
        #expect(try parse("item").parts == [SelectorPart(type: "item")])
        #expect(try parse("#battery .pct").parts.count == 2)
        #expect(try parse("item.a.b:hover").parts[0]
                == SelectorPart(type: "item", classes: ["a", "b"], states: [.hover]))
        #expect(try parse("#a").specificity == Specificity(ids: 1, classes: 0, types: 0))
        #expect(try parse("item.x:hover").specificity == Specificity(ids: 0, classes: 2, types: 1))
        #expect(try parse("group item").specificity == Specificity(ids: 0, classes: 0, types: 2))
    }

    @Test("descendant matching walks the whole ancestor path")
    func matching() throws {
        let path = [StyleNode(type: "bar"),
                    StyleNode(type: "group", id: "status"),
                    StyleNode(type: "item", id: "battery", classes: ["charging"]),
                    StyleNode(type: "text", classes: ["pct"])]
        func matches(_ text: String) throws -> Bool {
            try SelectorParser.parse(text, at: .start).matches(path)
        }
        #expect(try matches("text"))
        #expect(try matches(".pct"))
        #expect(try matches("#battery .pct"))
        #expect(try matches("group#status item text"))
        #expect(try matches("bar text"))
        #expect(try matches("*"))
        #expect(try !matches("item"))
        #expect(try !matches("#clock .pct"))
        #expect(try !matches("text group"))
        // :root is the bar.
        #expect(try SelectorParser.parse(":root", at: .start).matches([StyleNode(type: "bar")]))
    }

    // MARK: Cascade

    @Test("specificity, then source order, decides")
    func cascadeOrder() throws {
        let css = """
        item { color: red; }
        #a { color: green; }
        item { color: blue; }
        """
        let resolved = try style(css, [StyleNode(type: "item", id: "a")])
        #expect(resolved.color == .rgba(CSSValue.namedColors["green"]!))

        let later = try style("item { color: red } item { color: blue }", [StyleNode(type: "item")])
        #expect(later.color == .rgba(CSSValue.namedColors["blue"]!))
    }

    @Test("!important and inline style beat ordinary rules")
    func importantAndInline() throws {
        let node = [StyleNode(type: "item", id: "a")]
        #expect(try style("item { color: red !important } #a { color: blue }", node).color
                == .rgba(CSSValue.namedColors["red"]!))
        #expect(try style("#a { color: blue }", node, inline: "color: green").color
                == .rgba(CSSValue.namedColors["green"]!))
        #expect(try style("#a { color: blue !important }", node, inline: "color: green").color
                == .rgba(CSSValue.namedColors["blue"]!))
    }

    @Test("inherited properties come down, the rest reset")
    func inheritance() throws {
        let css = "bar { color: red; padding: 4pt; font-size: 14pt }"
        let resolved = try style(css, [StyleNode(type: "bar"), StyleNode(type: "item")])
        #expect(resolved.color == .rgba(CSSValue.namedColors["red"]!))
        #expect(resolved.font.size == 14)
        #expect(resolved.padding == .zero)          // padding does not inherit
    }

    @Test("var() resolves, falls back, and can be redefined further down")
    func variables() throws {
        let css = """
        :root { --fg: red; --pad: 3pt }
        item { color: var(--fg); padding: var(--pad); border-color: var(--missing, blue) }
        #b { --fg: green }
        """
        let a = try style(css, [StyleNode(type: "bar"), StyleNode(type: "item", id: "a")])
        #expect(a.color == .rgba(CSSValue.namedColors["red"]!))
        #expect(a.padding == Insets(3))
        #expect(a.borderColor == .rgba(CSSValue.namedColors["blue"]!))

        let b = try style(css, [StyleNode(type: "bar"), StyleNode(type: "item", id: "b")])
        #expect(b.color == .rgba(CSSValue.namedColors["green"]!))
    }

    @Test("an undefined var() drops that declaration and says so")
    func undefinedVariable() throws {
        let sheet = try Stylesheet.parse("item { color: var(--nope); opacity: 0.5 }")
        let result = Cascade(stylesheet: sheet).style(for: [StyleNode(type: "item")])
        #expect(result.diagnostics.count == 1)
        #expect("\(result.diagnostics[0])".contains("--nope"))
        #expect(result.style.opacity == 0.5)        // the rest of the rule still applies
    }

    @Test("a var() loop is caught")
    func variableLoop() throws {
        let sheet = try Stylesheet.parse(":root { --a: var(--b); --b: var(--a) } bar { color: var(--a) }")
        let result = Cascade(stylesheet: sheet).style(for: [StyleNode(type: "bar")])
        #expect(!result.diagnostics.isEmpty)
    }

    @Test("@media selects rules by appearance")
    func media() throws {
        let css = """
        :root { --bubble: white }
        @media (prefers-color-scheme: dark) { :root { --bubble: black } }
        item { background: var(--bubble) }
        """
        let path = [StyleNode(type: "bar"), StyleNode(type: "item")]
        #expect(try style(css, path, dark: false).background == .color(.rgba(CSSValue.namedColors["white"]!)))
        #expect(try style(css, path, dark: true).background == .color(.rgba(CSSValue.namedColors["black"]!)))
    }

    // MARK: Values

    @Test("colours in every accepted form")
    func colours() throws {
        func color(_ value: String) throws -> Color {
            try style("item { color: \(value) }", [StyleNode(type: "item")]).color
        }
        #expect(try color("#f00") == .rgba(RGBA(r: 1, g: 0, b: 0, a: 1)))
        #expect(try color("#ff0000") == .rgba(RGBA(r: 1, g: 0, b: 0, a: 1)))
        #expect(try color("#ff000080").doubleAlpha == 128.0 / 255)
        #expect(try color("rgb(255, 0, 0)") == .rgba(RGBA(r: 1, g: 0, b: 0, a: 1)))
        #expect(try color("rgba(255, 255, 255, 0.14)").doubleAlpha == 0.14)
        #expect(try color("hsl(120, 100%, 50%)") == .rgba(RGBA(r: 0, g: 1, b: 0, a: 1)))
        #expect(try color("system(labelColor)") == .system("labelColor"))
        #expect(try color("accent") == .accent)
        #expect(try color("currentColor") == .current)
        #expect(try color("none") == Color.none)
    }

    @Test("every property group has a working grammar")
    func properties() throws {
        let resolved = try style("""
        item {
          padding: 2pt 9pt;
          margin: 1pt;
          border: 1pt #333;
          border-radius: 8pt 0 0 8pt;
          min-width: 20pt; max-width: 80pt; width: 40pt;
          opacity: 0.8;
          gap: 3pt;
          background: backdrop blur(20pt) saturate(1.2);
          font: 12pt "SF Pro Text" medium;
          letter-spacing: 0.5pt;
          text-transform: uppercase;
          contrast: auto;
          icon-size: 13pt; icon-color: accent; icon-weight: bold; icon-rendering: hierarchical;
          fill: currentColor; track: #222; stroke-width: 1.5pt; line-cap: round;
          shadow: 0 1pt 3pt rgba(0, 0, 0, 0.4);
          transition: background 120ms ease-out, opacity 80ms linear 20ms;
        }
        """, [StyleNode(type: "item")])

        #expect(resolved.padding == Insets(top: 2, right: 9, bottom: 2, left: 9))
        #expect(resolved.margin == Insets(1))
        #expect(resolved.borderWidth == 1)
        #expect(resolved.borderRadius == Corners(topLeft: 8, topRight: 0, bottomRight: 0, bottomLeft: 8))
        #expect(resolved.minWidth == 20)
        #expect(resolved.maxWidth == 80)
        #expect(resolved.width == 40)
        #expect(resolved.opacity == 0.8)
        #expect(resolved.gap == 3)
        #expect(resolved.background == .backdrop(Backdrop(blur: 20, saturate: 1.2)))
        #expect(resolved.font == FontSpec(family: .named("SF Pro Text"), weight: 500, size: 12))
        #expect(resolved.letterSpacing == 0.5)
        #expect(resolved.textTransform == .uppercase)
        #expect(resolved.contrast == .auto)
        #expect(resolved.effectiveIconSize == 13)
        #expect(resolved.effectiveIconColor == .accent)
        #expect(resolved.iconRendering == .hierarchical)
        #expect(resolved.fill == .current)
        #expect(resolved.strokeWidth == 1.5)
        #expect(resolved.lineCap == .round)
        #expect(resolved.shadow?.blur == 3)
        #expect(resolved.transitions.count == 2)
        #expect(resolved.transitions[0] == Transition(property: "background", duration: 0.12,
                                                      delay: 0, easing: .easeOut))
        #expect(resolved.transitions[1] == Transition(property: "opacity", duration: 0.08,
                                                      delay: 0.02, easing: .linear))
        #expect(resolved.transition(for: "background")?.duration == 0.12)
    }

    @Test("a linear gradient background")
    func gradients() throws {
        let resolved = try style("item { background: linear-gradient(90deg, #000, #fff 80%) }",
                                 [StyleNode(type: "item")])
        guard case .gradient(let gradient) = resolved.background else { Issue.record("not a gradient"); return }
        #expect(gradient.angle == 90)
        #expect(gradient.stops.count == 2)
        #expect(gradient.stops[1].location == 0.8)
    }

    // MARK: Errors

    @Test("errors say what is wrong and where")
    func errors() throws {
        #expect(message("item { colour: red }").contains("unknown property 'colour'"))
        #expect(message("item { colour: red }").contains("did you mean 'color'"))
        #expect(message("item { color: rbga(0,0,0,1) }").contains("not a colour function"))
        #expect(message("item { color: #ff00000 }").contains("not a colour"))
        #expect(message("item { padding: 2em }").contains("lengths are in pt"))
        #expect(message("item { transition: background 120 }").contains("durations are in ms or s"))
        #expect(message("item { transition: wobble 1s }").contains("not a property"))
        #expect(message("item { contrast: loud }").contains("none, auto, light, dark"))
        #expect(message("item { hole: keep }").contains("unknown property 'hole'"))
        #expect(message("item:sleepy { color: red }").contains("unknown pseudo-class"))
        #expect(message("item > text { color: red }").contains("only combinator"))
        #expect(message("item[x=1] { color: red }").contains("attribute selectors"))
        #expect(message("@import \"x\";").contains("two at-rules, @media and @keyframes"))
        #expect(message("@media (width: 3) { item { color: red } }").contains("only media feature"))
        #expect(message("item { color red }").contains("expected :"))
        #expect(message("item { color: }").contains("no value"))
        #expect(message("item ").contains("no { } block"))
        #expect(message("/* unterminated").contains("unterminated /* comment"))
        // Position.
        #expect(message("item { color: red }\n\nitem { colour: red }").contains(":3:"))
    }

    // MARK: Interpolation

    @Test("interpolation is exact at both ends and blends in between")
    func interpolation() throws {
        let a = try style("item { opacity: 0; padding: 0; color: #000; border-radius: 0 }",
                          [StyleNode(type: "item")])
        let b = try style("item { opacity: 1; padding: 10pt; color: #fff; border-radius: 8pt }",
                          [StyleNode(type: "item")])
        #expect(Style.interpolated(from: a, to: b, t: 0).opacity == 0)
        #expect(Style.interpolated(from: a, to: b, t: 1).opacity == 1)
        let half = Style.interpolated(from: a, to: b, t: 0.5)
        #expect(half.opacity == 0.5)
        #expect(half.padding == Insets(5))
        #expect(half.borderRadius == Corners(4))
        #expect(half.color == .rgba(RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1)))
    }

    @Test("symbolic colours blend symbolically, so system colours still animate")
    func symbolicBlend() throws {
        let blended = Color.blend(.system("labelColor"), .accent, 0.25)
        #expect(blended == .mix(.system("labelColor"), .accent, 0.25))
        #expect(Color.blend(.system("labelColor"), .accent, 0) == .system("labelColor"))
        #expect(Color.blend(.system("labelColor"), .accent, 1) == .accent)
    }

    @Test("easings hit their ends and move monotonically")
    func easing() throws {
        for easing in [Easing.linear, .ease, .easeIn, .easeOut, .easeInOut] {
            #expect(easing.evaluate(0) == 0)
            #expect(easing.evaluate(1) == 1)
            var previous = -1.0
            for step in 0...20 {
                let value = easing.evaluate(Double(step) / 20)
                #expect(value >= previous - 1e-6)
                previous = value
            }
        }
        #expect(abs(Easing.linear.evaluate(0.5) - 0.5) < 1e-9)
        #expect(Easing.easeOut.evaluate(0.5) > 0.5)
        #expect(Easing.easeIn.evaluate(0.5) < 0.5)
    }

    @Test("changedProperties reports exactly what an animator must start")
    func changes() throws {
        let a = try style("item { opacity: 1; color: #000 }", [StyleNode(type: "item")])
        let b = try style("item { opacity: 0.5; color: #000 }", [StyleNode(type: "item")])
        #expect(a.changedProperties(against: b) == [.opacity])
    }

    // MARK: Transform and animation

    @Test("transform parses its parts in any order, and eases part by part")
    func transform() throws {
        let node = [StyleNode(type: "item")]
        let spun = try style("item { transform: scale(1.5) rotate(90deg) translate(4pt, -2pt) }", node).transform
        #expect(spun == Transform(translateX: 4, translateY: -2, rotate: 90, scaleX: 1.5, scaleY: 1.5))
        #expect(try style("item { transform: rotate(0.5turn) scale(2, 3) }", node).transform
                == Transform(rotate: 180, scaleX: 2, scaleY: 3))
        #expect(try style("item { transform: none }", node).transform == .identity)
        #expect(StyleProperty.animatable.contains(.transform))

        var halfway = try style("item { transform: rotate(360deg) translate(10pt) }", node)
        halfway.blend(.transform, from: Style.initial, t: 0.5)
        #expect(halfway.transform == Transform(translateX: 5, rotate: 180),
                "a full turn eases through half a turn, not through no turn at all")

        #expect(message("item { transform: skew(10deg) }").contains("translate(), rotate() and scale()"))
        #expect(message("item { transform: rotate(10) }").contains("angles are in deg or turn"))
        #expect(message("item { transform: rotate(1deg) rotate(2deg) }").contains("once"))
        #expect(message("item { transform: translate(1pt, 2pt, 3pt) }").contains("an x and an optional y"))
    }

    @Test("@keyframes and animation parse, and the cascade gives each node its keyframes")
    func animations() throws {
        let css = """
        :root { --far: 8pt }
        @keyframes spin { to { transform: rotate(360deg) } }
        @keyframes pulse { from, to { opacity: 1 } 40% { opacity: 0.3; transform: translate(var(--far)) } }
        item { animation: spin 1s linear infinite, pulse 600ms ease-in-out 100ms 3 alternate }
        """
        let resolved = try style(css, [StyleNode(type: "bar"), StyleNode(type: "item")])
        #expect(resolved.animations.count == 2)
        let spin = resolved.animations[0]
        #expect(spin.name == "spin" && spin.duration == 1 && spin.easing == .linear)
        #expect(spin.iterations == .infinity && !spin.alternate && spin.delay == 0)
        #expect(spin.keyframes == [Keyframe(offset: 1, transform: Transform(rotate: 360))])
        let pulse = resolved.animations[1]
        #expect(pulse.duration == 0.6 && pulse.delay == 0.1 && pulse.iterations == 3 && pulse.alternate)
        #expect(pulse.easing == .easeInOut)
        #expect(pulse.keyframes.map(\.offset) == [0, 0.4, 1])
        #expect(pulse.keyframes[1] == Keyframe(offset: 0.4, transform: Transform(translateX: 8), opacity: 0.3),
                "var() inside a keyframe resolves against the node")

        // The later sheet's keyframes win, as a socket style delta should.
        let base = try Stylesheet.parse("@keyframes spin { to { transform: rotate(90deg) } }")
        let delta = try Stylesheet.parse("@keyframes spin { to { transform: rotate(180deg) } }")
        let merged = base.appending(delta)
        #expect(merged.keyframes["spin"]?.stops.first?.declarations.first?.value.text == "rotate(180deg)")
    }

    @Test("an animation naming no @keyframes is a diagnostic, and the rest still apply")
    func unknownAnimation() throws {
        let sheet = try Stylesheet.parse("item { opacity: 0.5; animation: nowhere 1s }")
        let result = Cascade(stylesheet: sheet).style(for: [StyleNode(type: "item")])
        #expect(result.style.animations.isEmpty)
        #expect(result.style.opacity == 0.5)
        #expect(result.diagnostics.map(\.message) == ["no @keyframes named 'nowhere'"])
    }

    @Test("keyframes and animations say what is wrong")
    func animationErrors() {
        #expect(message("@keyframes glow { to { color: red } }").contains("transform and opacity only, not 'color'"))
        #expect(message("@keyframes glow { half { opacity: 1 } }").contains("from, to or a percentage"))
        #expect(message("@keyframes { to { opacity: 1 } }").contains("needs a name"))
        #expect(message("@keyframes glow { }").contains("has no keyframes"))
        #expect(message("item { animation: spin }").contains("needs a duration"))
        #expect(message("item { animation: spin 1s wobbly }").contains("does not belong in an animation"))
        #expect(message("item { animation: spin 1s 2 3 }").contains("one iteration count"))
        #expect(message("item { transition: transform 1s }") == "parsed, but should not have" ,
                "transform transitions")
    }

}

extension Color {
    var doubleAlpha: Double? {
        if case .rgba(let rgba) = self { return Double(rgba.a) } else { return nil }
    }
}
