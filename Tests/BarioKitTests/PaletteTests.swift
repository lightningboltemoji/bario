import CoreGraphics
import Foundation
import Testing
@testable import BarioKit

/// Extraction (PLAN.md step 2), on images the tests draw rather than wallpapers in the repo.
@Suite("Palette")
struct PaletteTests {
    /// Vertical stripes, each so many pixels wide, in sRGB or another space.
    static func image(_ stripes: [(RGBA, Int)], height: Int = 40,
                      space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        let width = stripes.reduce(0) { $0 + $1.1 }
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var x = 0
        for (color, w) in stripes {
            context.setFillColor(CGColor(colorSpace: space, components: [color.r, color.g, color.b, color.a])!)
            context.fill(CGRect(x: x, y: 0, width: w, height: height))
            x += w
        }
        return context.makeImage()!
    }

    /// What a colour is once it has been through an 8-bit image.
    static func eightBit(_ color: RGBA) -> RGBA {
        func q(_ c: CGFloat) -> CGFloat { (c * 255).rounded() / 255 }
        return RGBA(r: q(color.r), g: q(color.g), b: q(color.b))
    }

    static func vivid(l: Double, h: Double, share: Double = 0.98) -> RGBA {
        eightBit(OKLCH(l: l, c: OKLCH.maxChroma(l: l, h: h) * share, h: h).rgba())
    }

    func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    func expectGaps(_ palette: Palette, _ label: String) {
        let gap = Slot.gap - 1e-6
        for (base, dark, light) in [(Slot.Name.vibrant, Slot.Name.vibrantDark, Slot.Name.vibrantLight),
                                    (.muted, .mutedDark, .mutedLight)] {
            let l = palette[base].color.l
            #expect(palette[dark].color.l <= l - gap, "\(label): \(dark.rawValue) is too close to \(base.rawValue)")
            #expect(palette[light].color.l >= l + gap, "\(label): \(light.rawValue) is too close to \(base.rawValue)")
        }
    }

    // MARK: The plan's cases

    @Test("a solid colour is one cluster, the seed is its hue, and the slots it does not fit are made up")
    func solid() {
        // So light that no slot's range reaches it, with colour enough for a seed.
        let tint = OKLCH(l: 0.975, c: 0.035, h: 105)
        #expect(tint.inSRGB)
        let pixel = PaletteTests.eightBit(tint.rgba())
        let palette = Palette.extract(PaletteTests.image([(pixel, 100)]))
        #expect(palette.clusters.count == 1)
        #expect(abs(palette.clusters[0].population - 1) < 1e-9)
        #expect(palette.seeds.count == 1)
        #expect(hueDistance(palette.seeds[0].color.lch.h, OKLCH(pixel).h) < 0.5)
        #expect(palette[.dominant].found)
        for name in Slot.Name.chosen {
            #expect(!palette[name].found, "\(name.rawValue) was found in a colour too light for it")
        }

        // A vivid one fills vibrant and nothing else.
        let orange = PaletteTests.vivid(l: 0.66, h: 50)
        let vivid = Palette.extract(PaletteTests.image([(orange, 100)]))
        #expect(vivid.clusters.count == 1)
        #expect(hueDistance(vivid.seeds[0].color.lch.h, OKLCH(orange).h) < 0.5)
        #expect(vivid[.vibrant].found)
        #expect(Slot.Name.chosen.filter { vivid[$0].found } == [.vibrant])
    }

    @Test("70% of one colour and 30% of another makes the 70 dominant")
    func dominant() {
        let slate = PaletteTests.eightBit(OKLCH(l: 0.5, c: 0.04, h: 250).rgba())
        let orange = PaletteTests.vivid(l: 0.7, h: 55)
        let palette = Palette.extract(PaletteTests.image([(orange, 60), (slate, 140)]))
        #expect(palette.clusters.count == 2)
        #expect(abs(palette.clusters[0].population - 0.7) < 1e-9)
        #expect(palette[.dominant].color.distance(to: Oklab(slate)) < 1e-4)
        #expect(palette[.vibrant].color.distance(to: Oklab(orange)) < 1e-4)
    }

    @Test("a grey ramp has no seed, its vibrant slot is made up from the accent, and its muted slots stay grey")
    func greyRamp() {
        let ramp = (0..<200).map { x -> (RGBA, Int) in
            let v = CGFloat(x) / 199
            return (RGBA(r: v, g: v, b: v), 1)
        }
        let accent = RGBA(r: 0.2, g: 0.7, b: 0.3)
        let palette = Palette.extract(PaletteTests.image(ramp), accent: accent)
        #expect(palette.seeds.isEmpty)
        #expect(!palette[.vibrant].found)
        #expect(hueDistance(palette[.vibrant].color.lch.h, OKLCH(accent).h) < 0.5)
        #expect(palette[.vibrant].color.lch.c > 0.1, "a made-up vibrant is vibrant")
        for name in [Slot.Name.muted, .mutedDark, .mutedLight] {
            #expect(palette[name].color.lch.c < 0.01, "\(name.rawValue) is the image's own grey")
        }
        expectGaps(palette, "grey ramp")

        // Another accent moves the made-up vibrant slots, and nothing that was measured.
        let other = palette.with(accent: RGBA(r: 0.9, g: 0.2, b: 0.6))
        #expect(other.clusters == palette.clusters)
        #expect(other[.muted] == palette[.muted])
        #expect(hueDistance(other[.vibrant].color.lch.h, OKLCH(RGBA(r: 0.9, g: 0.2, b: 0.6)).h) < 0.5)
    }

    @Test("a vivid 3% patch on a dull field is vibrant but not the seed")
    func vividPatch() {
        let field = PaletteTests.eightBit(OKLCH(l: 0.55, c: 0.06, h: 140).rgba())
        let patch = PaletteTests.vivid(l: 0.62, h: 330)
        let palette = Palette.extract(PaletteTests.image([(field, 194), (patch, 6)]))
        #expect(palette[.vibrant].found)
        #expect(palette[.vibrant].color.distance(to: Oklab(patch)) < 1e-4)
        #expect(hueDistance(palette.seeds[0].color.lch.h, 140) < 3, "the broad wash is the seed")
        #expect(palette.seeds.contains { hueDistance($0.color.lch.h, OKLCH(patch).h) < 3 },
                "the patch is a lesser seed")
    }

    @Test("every family keeps its gap, whether its variants were found or made up")
    func gaps() {
        // A tempting dark candidate only 0.12 below the base, and a fair one further down.
        let stripes = PaletteTests.image([
            (PaletteTests.vivid(l: 0.64, h: 30), 50),
            (PaletteTests.vivid(l: 0.52, h: 30), 40),
            (PaletteTests.vivid(l: 0.33, h: 30), 20),
            (PaletteTests.vivid(l: 0.85, h: 95), 20),
            (PaletteTests.eightBit(OKLCH(l: 0.6, c: 0.03, h: 250).rgba()), 40),
            (PaletteTests.eightBit(OKLCH(l: 0.53, c: 0.03, h: 250).rgba()), 30),
        ])
        let palette = Palette.extract(stripes)
        expectGaps(palette, "stripes")
        #expect(palette[.vibrantDark].found)
        #expect(abs(palette[.vibrantDark].color.l - OKLCH(PaletteTests.vivid(l: 0.33, h: 30)).l) < 0.002,
                "the closer candidate was passed over for the gap")
        #expect(palette[.vibrantLight].found)
        #expect(!palette[.mutedDark].found, "0.53 is in muted-dark's range but too close to muted")
        #expect(!palette[.mutedLight].found)

        let solid = Palette.extract(PaletteTests.image([(PaletteTests.vivid(l: 0.5, h: 200), 50)]))
        expectGaps(solid, "solid")
        let field = Palette.extract(PaletteTests.image([
            (PaletteTests.eightBit(OKLCH(l: 0.75, c: 0.05, h: 80).rgba()), 190),
            (PaletteTests.vivid(l: 0.45, h: 260), 10),
        ]))
        expectGaps(field, "field")
    }

    @Test("an image whose biggest colour is its most vivid has dominant and vibrant the same, and says so")
    func dominantIsVibrant() {
        let orange = PaletteTests.vivid(l: 0.68, h: 50)
        let grey = PaletteTests.eightBit(OKLCH(l: 0.3, c: 0, h: 0).rgba())
        let palette = Palette.extract(PaletteTests.image([(orange, 120), (grey, 80)]))
        #expect(palette[.dominant].cluster == palette[.vibrant].cluster)
        #expect(palette[.dominant].color == palette[.vibrant].color)
        #expect(palette.dominantSameAs == .vibrant)
        let json = palette.json(display: "Test", id: 7, primary: true)
        #expect(json["slots"]?["dominant"]?["same-as"] == .string("vibrant"))
        #expect(json["slots"]?["vibrant"]?["same-as"] == nil)
    }

    @Test("the same image twice gives an identical palette")
    func deterministic() {
        var stripes: [(RGBA, Int)] = []
        for x in 0..<160 {
            let t = Double(x) / 159
            stripes.append((OKLCH(l: 0.3 + 0.6 * t, c: 0.05 + 0.15 * t, h: 360 * t).rgba(), 1))
        }
        stripes.append((PaletteTests.vivid(l: 0.6, h: 140), 40))
        let image = PaletteTests.image(stripes)
        let first = Palette.extract(image)
        #expect(first.clusters.count == 16)
        #expect(Palette.extract(image) == first)
        #expect(Palette.extract(PaletteTests.image(stripes)) == first, "drawn again, still the same")
    }

    @Test("a near-tie flips without the last palette and holds with it; a clear change still moves")
    func hysteresis() {
        let orange = PaletteTests.vivid(l: 0.64, h: 55)
        let blue = PaletteTests.vivid(l: 0.64, h: 250)
        let grey = PaletteTests.eightBit(OKLCH(l: 0.5, c: 0, h: 0).rgba())
        func image(orange o: Int, blue b: Int) -> CGImage {
            PaletteTests.image([(orange, o), (blue, b), (grey, 80)])
        }
        func vibrant(_ palette: Palette) -> RGBA { PaletteTests.eightBit(palette[.vibrant].rgba) }

        let before = Palette.extract(image(orange: 68, blue: 52))
        #expect(vibrant(before) == orange)
        let after = image(orange: 52, blue: 68)
        #expect(vibrant(Palette.extract(after)) == blue, "a fresh look takes the new favourite")
        #expect(vibrant(Palette.extract(after, previous: before)) == orange, "the last palette holds the near-tie")

        let clear = image(orange: 30, blue: 90)
        #expect(vibrant(Palette.extract(clear, previous: before)) == blue, "not a near-tie, so it moves")
    }

    // MARK: Beyond the plan's list

    @Test("a Display P3 image is measured beyond sRGB, and shown inside it")
    func displayP3() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let palette = Palette.extract(PaletteTests.image([(RGBA(r: 1, g: 0, b: 0), 50)], space: p3))
        let red = palette.clusters[0]
        #expect(!red.lch.inSRGB, "P3 red is outside sRGB")
        #expect(red.relativeChroma > 1)
        #expect(red.lch.c > OKLCH(RGBA(r: 1, g: 0, b: 0)).c)
        // Shown in sRGB at its own lightness and hue, as saturated as sRGB has there.
        let shown = OKLCH(red.rgba)
        #expect(abs(shown.l - red.lch.l) < 0.002)
        #expect(hueDistance(shown.h, red.lch.h) < 0.5)
        #expect(abs(shown.c - OKLCH.maxChroma(l: red.lch.l, h: red.lch.h)) < 0.002)
        #expect(palette[.vibrant].found, "a colour beyond sRGB is as vibrant as can be")
    }

    @Test("the store's entry has every slot, with hex, OKLCH and whether it was found")
    func json() {
        let palette = Palette.extract(PaletteTests.image([(PaletteTests.vivid(l: 0.6, h: 140), 30),
                                                          (RGBA(r: 0.9, g: 0.9, b: 0.9), 70)]))
        let json = palette.json(display: "Studio Display", id: 3, primary: true)
        #expect(json["name"] == .string("Studio Display"))
        #expect(json["id"] == .number(3))
        #expect(json["primary"] == .bool(true))
        #expect(json["clusters"]?.arrayValue?.count == 2)
        #expect(json["clusters"]?[index: 0]?["population"] == .number(0.7))
        let slots = json["slots"]?.objectValue ?? [:]
        #expect(Set(slots.keys) == Set(Slot.Name.allCases.map(\.rawValue)))
        #expect(slots["vibrant"]?["found"] == .bool(true))
        #expect(slots["vibrant-dark"]?["found"] == .bool(false))
        #expect(slots["vibrant"]?["hex"] == .string(palette[.vibrant].rgba.hex))
        #expect(slots["vibrant"]?["oklch"]?.arrayValue?.count == 3)
        #expect(json["seeds"]?.arrayValue?.isEmpty == false)

        let text = CLI.describePalette(json, title: "Studio Display", swatches: true)
        #expect(text.contains("vibrant-dark"))
        #expect(text.contains("made up"))
        #expect(text.contains("\u{1B}[48;2;"))
        #expect(!CLI.describePalette(json, title: "x", swatches: false).contains("\u{1B}"))
    }
}

private extension JSONValue {
    subscript(index index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
