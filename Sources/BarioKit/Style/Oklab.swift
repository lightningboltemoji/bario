import Foundation

// Oklab and OKLCH, the perceptual space every colour function and the wallpaper palette work
// in. Oklab is Björn Ottosson's, who put it in the public domain ("feel free to use it any way
// you please"); the matrices below are his published ones. Colours come in and go out as sRGB,
// as every other colour in bario does: whatever lands outside sRGB is brought back in by
// lowering its chroma at the same lightness and hue (PLAN.md W4).

/// A colour in Oklab: lightness from 0 to 1, then green to red and blue to yellow, each about
/// ±0.4 for what a display can show. Named as CSS names the channels.
public struct Oklab: Sendable, Hashable {
    public var l: Double
    public var a: Double
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// From linear-light sRGB. Channels outside 0…1 are colours outside sRGB, such as a Display
    /// P3 capture read through extended linear sRGB, and they convert as they are.
    public init(linearRed r: Double, green g: Double, blue b: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.l = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// From an sRGB colour, ignoring its alpha.
    public init(_ rgba: RGBA) {
        self.init(linearRed: SRGB.linear(Double(rgba.r)), green: SRGB.linear(Double(rgba.g)),
                  blue: SRGB.linear(Double(rgba.b)))
    }

    /// Linear-light sRGB, unclamped.
    public var linear: (r: Double, g: Double, b: Double) {
        let l = pow3(self.l + 0.3963377774 * a + 0.2158037573 * b)
        let m = pow3(self.l - 0.1055613458 * a - 0.0638541728 * b)
        let s = pow3(self.l - 0.0894841775 * a - 1.2914855480 * b)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    public var lch: OKLCH {
        let c = (a * a + b * b).squareRoot()
        // A grey has no hue to speak of, and CSS calls it 0.
        guard c >= OKLCH.achromatic else { return OKLCH(l: l, c: c, h: 0) }
        let h = atan2(b, a) * 180 / .pi
        return OKLCH(l: l, c: c, h: h < 0 ? h + 360 : h)
    }

    /// In sRGB, with chroma lowered at the same lightness and hue until it fits.
    public func rgba(alpha: Double = 1) -> RGBA { lch.rgba(alpha: alpha) }

    /// Euclidean distance, ΔE in Oklab's own units: about 0.02 is just noticeable.
    public func distance(to other: Oklab) -> Double {
        let (dl, da, db) = (l - other.l, a - other.a, b - other.b)
        return (dl * dl + da * da + db * db).squareRoot()
    }
}

private func pow3(_ x: Double) -> Double { x * x * x }

/// Oklab in polar form: lightness, chroma and hue in degrees. Chroma runs from 0, grey, to
/// about 0.32, the most saturated blue sRGB has.
public struct OKLCH: Sendable, Hashable {
    public var l: Double
    public var c: Double
    /// Degrees, 0 up to 360.
    public var h: Double

    /// Below this chroma a colour is a grey, and its hue is noise.
    public static let achromatic = 1e-4

    public init(l: Double, c: Double, h: Double) {
        self.l = l
        self.c = c
        self.h = h
    }

    public init(_ rgba: RGBA) { self = Oklab(rgba).lch }

    public var lab: Oklab {
        let radians = h * .pi / 180
        return Oklab(l: l, a: c * cos(radians), b: c * sin(radians))
    }

    /// Whether sRGB holds this colour as it is.
    public var inSRGB: Bool { OKLCH.fits(lab.linear) }

    /// The colour in sRGB. Lightness is clamped to 0…1; inside that, chroma comes down,
    /// bisected, until the colour fits, so lightness and hue are kept (PLAN.md W4).
    public func rgba(alpha: Double = 1) -> RGBA {
        let alpha = CGFloat(min(1, max(0, alpha.isNaN ? 0 : alpha)))
        guard l < 1 else { return RGBA(r: 1, g: 1, b: 1, a: alpha) }
        guard l > 0 else { return RGBA(r: 0, g: 0, b: 0, a: alpha) }
        var shown = OKLCH(l: l, c: max(0, c), h: h)
        if !shown.inSRGB {
            shown.c = OKLCH.bisect(l: l, h: h, below: shown.c)
        }
        let linear = shown.lab.linear
        func encode(_ channel: Double) -> CGFloat { CGFloat(SRGB.encoded(min(1, max(0, channel)))) }
        return RGBA(r: encode(linear.r), g: encode(linear.g), b: encode(linear.b), a: alpha)
    }

    /// The most chroma sRGB holds at a lightness and hue: what relative chroma is measured
    /// against, as saturation is in HSL.
    public static func maxChroma(l: Double, h: Double) -> Double {
        guard l > 0, l < 1 else { return 0 }
        return bisect(l: l, h: h, below: 0.5)
    }

    /// The largest chroma under `limit` that fits in sRGB at this lightness and hue. Along a
    /// line of constant lightness and hue, sRGB is one run from the grey axis outwards.
    private static func bisect(l: Double, h: Double, below limit: Double) -> Double {
        var fits = 0.0, overflows = limit
        for _ in 0..<24 {
            let mid = (fits + overflows) / 2
            if OKLCH(l: l, c: mid, h: h).inSRGB { fits = mid } else { overflows = mid }
        }
        return fits
    }

    /// A hair of slack, so a colour that came from sRGB goes back unchanged despite rounding.
    private static func fits(_ linear: (r: Double, g: Double, b: Double)) -> Bool {
        let range = -1e-6...(1 + 1e-6)
        return range.contains(linear.r) && range.contains(linear.g) && range.contains(linear.b)
    }
}

/// The sRGB transfer function, mirrored through zero so that extended values convert too.
public enum SRGB {
    public static func linear(_ encoded: Double) -> Double {
        let x = abs(encoded)
        let y = x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        return encoded < 0 ? -y : y
    }

    public static func encoded(_ linear: Double) -> Double {
        let x = abs(linear)
        let y = x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        return linear < 0 ? -y : y
    }
}

/// WCAG 2's contrast: what `contrast-color()`, `on()` and a scheme's `on-` roles promise.
public enum WCAG {
    public static let white = RGBA(r: 1, g: 1, b: 1)
    public static let black = RGBA(r: 0, g: 0, b: 0)

    /// Relative luminance, 0 for black to 1 for white. Alpha is ignored: what a translucent
    /// colour ends up over is not known here.
    public static func luminance(_ color: RGBA) -> Double {
        func channel(_ value: CGFloat) -> Double { SRGB.linear(min(1, max(0, Double(value)))) }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }

    /// From 1, the same colour, to 21, black on white.
    public static func ratio(_ a: RGBA, _ b: RGBA) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Whether white contrasts with `color` at least as much as black does.
    public static func prefersWhite(on color: RGBA) -> Bool {
        ratio(white, color) >= ratio(black, color)
    }

    /// `contrast-color()`: white or black, whichever contrasts more.
    public static func contrastColor(_ color: RGBA) -> RGBA {
        prefersWhite(on: color) ? white : black
    }
}

// MARK: - Readable partners

extension OKLCH {
    /// This colour if it contrasts with `background` by `ratio`; otherwise the nearest colour of
    /// the same chroma and hue towards white (`lighter`) or black that does, or that extreme
    /// itself when even it falls short. The solver behind `on()` and a scheme's `on-` roles
    /// (PLAN.md W12, W16): it starts where it is told and moves only as far as the ratio needs,
    /// so a pair that already reads keeps the crispness it started with.
    public func readable(against background: RGBA, ratio: Double, lighter: Bool) -> RGBA {
        let start = rgba()
        guard WCAG.ratio(start, background) < ratio else { return start }
        let extreme = OKLCH(l: lighter ? 1 : 0, c: c, h: h).rgba()
        guard WCAG.ratio(extreme, background) >= ratio else { return extreme }
        // `enough` always meets the ratio and `short` never does, so what comes back meets it.
        var short = l, enough = lighter ? 1.0 : 0.0
        for _ in 0..<24 {
            let mid = (short + enough) / 2
            if WCAG.ratio(OKLCH(l: mid, c: c, h: h).rgba(), background) >= ratio {
                enough = mid
            } else {
                short = mid
            }
        }
        return OKLCH(l: enough, c: c, h: h).rgba()
    }

    /// `on(<colour>, <ratio>)`: a readable partner for any colour. It keeps the colour's hue
    /// and half its chroma, on whichever side black or white contrasts more, starting crisp at
    /// L 0.97 or 0.25 and moving further only when short of the ratio. 4.5:1 is always within
    /// reach; nothing much above 4.58:1 is against a colour of middle luminance, and there it
    /// comes as close as it can.
    public static func on(_ background: RGBA, ratio: Double = 4.5) -> RGBA {
        let opaque = RGBA(r: background.r, g: background.g, b: background.b)
        let base = OKLCH(opaque)
        let lighter = WCAG.prefersWhite(on: opaque)
        return OKLCH(l: lighter ? 0.97 : 0.25, c: base.c / 2, h: base.h)
            .readable(against: opaque, ratio: ratio, lighter: lighter)
    }
}
