import Foundation

// CSS Color 4 and 5, and bario's own on(): oklab() and oklch(); rgb() and hsl() in the modern
// and legacy syntaxes; the relative syntax, `oklch(from <colour> l c calc(h + 50))`, in all
// four; color-mix(); contrast-color(). A function whose inputs are all known computes to
// `.rgba` where it is parsed: at parse time for literals, and in the cascade once var() has
// been substituted. One with an input only commit knows, `accent`, `currentColor` or
// `system()`, stays symbolic and ColorResolver computes it, as it computes `accent`
// (PLAN.md W3, W13, W16).

// MARK: - Relative colours

/// A colour written in a space's own channels, from an origin colour: `rgb(from …)`,
/// `hsl(from …)`, `oklab(from …)` or `oklch(from …)`.
public struct RelativeColor: Sendable, Hashable {
    public enum Space: String, Sendable, Hashable {
        case rgb, hsl, oklab, oklch
    }

    public var space: Space
    public var origin: Color
    /// Three channels, then alpha.
    public var channels: [ColorCalc]

    /// The colour, given what its origin turned out to be.
    public func evaluate(_ origin: RGBA) -> RGBA {
        let values = space.values(of: origin)
        return space.color(channels.map { $0.evaluate(values) })
    }
}

/// One channel of a colour function: a number, a channel of the origin by name, or `calc()`,
/// `min()`, `max()` and `clamp()` over those. Percentages and angles are already in the
/// channel's own units.
public indirect enum ColorCalc: Sendable, Hashable {
    case number(Double)
    case channel(String)
    /// `+`, `-`, `*` or `/`.
    case operation(Character, ColorCalc, ColorCalc)
    case minimum([ColorCalc])
    case maximum([ColorCalc])

    func evaluate(_ channels: [String: Double]) -> Double {
        switch self {
        case .number(let value): return value
        case .channel(let name): return channels[name] ?? 0
        case .operation(let op, let a, let b):
            let (x, y) = (a.evaluate(channels), b.evaluate(channels))
            switch op {
            case "+": return x + y
            case "-": return x - y
            case "*": return x * y
            // Dividing by zero is infinite, and the channel's range then clamps it, as in CSS.
            default: return x / y
            }
        case .minimum(let terms): return terms.map { $0.evaluate(channels) }.min() ?? 0
        case .maximum(let terms): return terms.map { $0.evaluate(channels) }.max() ?? 0
        }
    }
}

extension RelativeColor.Space {
    /// A channel as the syntax sees it: its keyword, what 100% of it is, and whether it is a
    /// hue, which takes angles.
    struct Channel {
        var keyword: String
        var label: String
        var percent: Double
        var isHue = false
    }

    var channels: [Channel] {
        let alpha = Channel(keyword: "alpha", label: "alpha", percent: 1)
        switch self {
        case .rgb:
            return [Channel(keyword: "r", label: "red", percent: 255),
                    Channel(keyword: "g", label: "green", percent: 255),
                    Channel(keyword: "b", label: "blue", percent: 255), alpha]
        case .hsl:
            return [Channel(keyword: "h", label: "hue", percent: 0, isHue: true),
                    Channel(keyword: "s", label: "saturation", percent: 100),
                    Channel(keyword: "l", label: "lightness", percent: 100), alpha]
        case .oklab:
            return [Channel(keyword: "l", label: "lightness", percent: 1),
                    Channel(keyword: "a", label: "a", percent: 0.4),
                    Channel(keyword: "b", label: "b", percent: 0.4), alpha]
        case .oklch:
            return [Channel(keyword: "l", label: "lightness", percent: 1),
                    Channel(keyword: "c", label: "chroma", percent: 0.4),
                    Channel(keyword: "h", label: "hue", percent: 0, isHue: true), alpha]
        }
    }

    /// What the channel keywords mean for an origin colour: rgb's 0…255, hsl's 0…100, Oklab's
    /// and OKLCH's own units.
    func values(of color: RGBA) -> [String: Double] {
        let alpha = Double(color.a)
        switch self {
        case .rgb:
            return ["r": Double(color.r) * 255, "g": Double(color.g) * 255, "b": Double(color.b) * 255,
                    "alpha": alpha]
        case .hsl:
            let (h, s, l) = RelativeColor.hsl(of: color)
            return ["h": h, "s": s, "l": l, "alpha": alpha]
        case .oklab:
            let lab = Oklab(color)
            return ["l": lab.l, "a": lab.a, "b": lab.b, "alpha": alpha]
        case .oklch:
            let lch = OKLCH(color)
            return ["l": lch.l, "c": lch.c, "h": lch.h, "alpha": alpha]
        }
    }

    /// The colour four channel values make, each clamped to its range, in sRGB.
    func color(_ values: [Double]) -> RGBA {
        func clamp(_ x: Double, _ low: Double, _ high: Double) -> Double {
            x.isNaN ? low : min(high, max(low, x))
        }
        func hue(_ x: Double) -> Double {
            guard x.isFinite else { return 0 }
            let h = x.truncatingRemainder(dividingBy: 360)
            return h < 0 ? h + 360 : h
        }
        let alpha = clamp(values[3], 0, 1)
        switch self {
        case .rgb:
            return RGBA(r: CGFloat(clamp(values[0], 0, 255) / 255), g: CGFloat(clamp(values[1], 0, 255) / 255),
                        b: CGFloat(clamp(values[2], 0, 255) / 255), a: CGFloat(alpha))
        case .hsl:
            return CSSValue.hsl(hue: hue(values[0]), saturation: clamp(values[1], 0, 100) / 100,
                                lightness: clamp(values[2], 0, 100) / 100, alpha: CGFloat(alpha))
        case .oklab:
            var lch = Oklab(l: clamp(values[0], 0, 1), a: values[1].isNaN ? 0 : values[1],
                            b: values[2].isNaN ? 0 : values[2]).lch
            lch.c = min(lch.c, 0.5)                 // all far outside sRGB, and finite
            return lch.rgba(alpha: alpha)
        case .oklch:
            return OKLCH(l: clamp(values[0], 0, 1), c: clamp(values[1], 0, 0.5), h: hue(values[2]))
                .rgba(alpha: alpha)
        }
    }
}

extension RelativeColor {
    /// HSL's hue in degrees, and its saturation and lightness from 0 to 100.
    static func hsl(of color: RGBA) -> (h: Double, s: Double, l: Double) {
        let (r, g, b) = (Double(color.r), Double(color.g), Double(color.b))
        let high = max(r, g, b), low = min(r, g, b)
        let l = (high + low) / 2
        let d = high - low
        guard d > 0 else { return (0, 0, l * 100) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        switch high {
        case r: h = (g - b) / d
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s * 100, l * 100)
    }
}

// MARK: - color-mix()

/// `color-mix(in <space>, <colour> [<p>%], <colour> [<p>%])`, mixed as CSS mixes: with alpha
/// premultiplied, so mixing with `transparent` fades a colour rather than darkening it, and in
/// OKLCH along the shorter way round the hue circle, a grey taking the other colour's hue.
public struct ColorMix: Sendable, Hashable {
    public enum Space: String, Sendable, Hashable {
        case oklab, oklch, srgb
        case srgbLinear = "srgb-linear"
    }

    public var space: Space
    public var first: Color
    public var second: Color
    /// The second colour's share, 0…1, once the percentages are normalised.
    public var weight: Double
    /// Below 1 when the percentages add up to less than 100%.
    public var alpha: Double

    public func evaluate(_ x: RGBA, _ y: RGBA) -> RGBA {
        let (w1, w2) = (1 - weight, weight)
        let (a1, a2) = (Double(x.a) * w1, Double(y.a) * w2)
        let total = a1 + a2
        guard total > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        func mix(_ p: Double, _ q: Double) -> Double { (p * a1 + q * a2) / total }
        let alpha = total * self.alpha

        switch space {
        case .srgb:
            return RGBA(r: CGFloat(mix(Double(x.r), Double(y.r))), g: CGFloat(mix(Double(x.g), Double(y.g))),
                        b: CGFloat(mix(Double(x.b), Double(y.b))), a: CGFloat(alpha))
        case .srgbLinear:
            func channel(_ p: CGFloat, _ q: CGFloat) -> CGFloat {
                CGFloat(SRGB.encoded(mix(SRGB.linear(Double(p)), SRGB.linear(Double(q)))))
            }
            return RGBA(r: channel(x.r, y.r), g: channel(x.g, y.g), b: channel(x.b, y.b), a: CGFloat(alpha))
        case .oklab:
            let (p, q) = (Oklab(x), Oklab(y))
            return Oklab(l: mix(p.l, q.l), a: mix(p.a, q.a), b: mix(p.b, q.b)).rgba(alpha: alpha)
        case .oklch:
            let (p, q) = (OKLCH(x), OKLCH(y))
            // A grey has no hue of its own to pull towards.
            var (h1, h2) = (p.h, q.h)
            if p.c < OKLCH.achromatic { h1 = h2 }
            if q.c < OKLCH.achromatic { h2 = h1 }
            var delta = h2 - h1
            if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
            var h = h1 + delta * w2
            if h < 0 { h += 360 } else if h >= 360 { h -= 360 }
            return OKLCH(l: mix(p.l, q.l), c: mix(p.c, q.c), h: h).rgba(alpha: alpha)
        }
    }
}

// MARK: - Parsing

extension CSSValue {
    static func colorFunction(_ name: String, _ args: [[CSSComponent]],
                              at position: CSSPosition) throws -> Color {
        switch name {
        case "rgb", "rgba": return try channels(.rgb, name, args, at: position)
        case "hsl", "hsla": return try channels(.hsl, name, args, at: position)
        case "oklab": return try channels(.oklab, name, args, at: position)
        case "oklch": return try channels(.oklch, name, args, at: position)
        case "color-mix": return try colorMix(args, at: position)
        case "contrast-color":
            guard args.count == 1, args[0].count == 1 else {
                throw CSSError("contrast-color() takes one colour, as in contrast-color(accent)", at: position)
            }
            let input = try color(args[0][0], at: position)
            if let known = input.constant { return .rgba(WCAG.contrastColor(known)) }
            return .contrast(input)
        case "on":
            guard (1...2).contains(args.count), args[0].count == 1 else {
                throw CSSError("on() takes a colour and an optional contrast ratio, as in on(accent) "
                               + "or on(accent, 7)", at: position)
            }
            let input = try color(args[0][0], at: position)
            var ratio = 4.5
            if args.count == 2 {
                guard args[1].count == 1, case .number(let value, let unit) = args[1][0], unit == nil,
                      (1...21).contains(value) else {
                    throw CSSError("on()'s second argument is a contrast ratio from 1 to 21, as in "
                                   + "on(accent, 7); found '\(args[1].text)'", at: position)
                }
                ratio = value
            }
            if let known = input.constant { return .rgba(OKLCH.on(known, ratio: ratio)) }
            return .on(input, ratio: ratio)
        case "system":
            guard args.count == 1, let colorName = args[0].first?.identValue, args[0].count == 1 else {
                throw CSSError("system() takes an NSColor name, e.g. system(labelColor)", at: position)
            }
            return .system(colorName)
        case "":
            throw CSSError("'\(CSSComponent.function(name, args).text)' is not a colour", at: position)
        default:
            throw CSSError("'\(name)()' is not a colour function; the ones that exist are rgb(), rgba(), "
                           + "hsl(), hsla(), oklab(), oklch(), color-mix(), contrast-color(), on() "
                           + "and system()", at: position)
        }
    }

    /// `oklch(0.7 0.15 250)`, `oklch(0.7 0.15 250 / 50%)`, `oklch(from accent l c h)`, and for
    /// rgb() and hsl() the legacy `rgb(255, 128, 0)` as well.
    private static func channels(_ space: RelativeColor.Space, _ name: String, _ args: [[CSSComponent]],
                                 at position: CSSPosition) throws -> Color {
        let usage: String
        switch space {
        case .rgb:
            usage = "\(name)() takes red, green, blue and an optional alpha: \(name)(255 128 0), "
                + "\(name)(255 128 0 / 50%), \(name)(255, 128, 0) or \(name)(from accent r g b / 0.5)"
        case .hsl:
            usage = "\(name)() takes a hue, a saturation, a lightness and an optional alpha: "
                + "\(name)(30 100% 50%), \(name)(30, 100%, 50%) or \(name)(from accent h s calc(l + 10))"
        case .oklab:
            usage = "oklab() takes a lightness, a, b and an optional alpha: oklab(0.7 0.1 -0.05) "
                + "or oklab(from accent l a b / 0.5)"
        case .oklch:
            usage = "oklch() takes a lightness, a chroma, a hue and an optional alpha: "
                + "oklch(0.7 0.15 250) or oklch(from accent l c calc(h + 180))"
        }

        var origin: Color?
        var written: [CSSComponent]
        var alpha: CSSComponent?
        if args.count == 1 {
            var rest = args[0][...]
            if rest.first?.identValue == "from" {
                guard let first = rest.dropFirst().first else {
                    throw CSSError("\(name)(from …) needs a colour after from", at: position)
                }
                origin = try color(first, at: position)
                rest = rest.dropFirst(2)
            }
            let parts = rest.split(separator: .slash, omittingEmptySubsequences: false)
            guard parts.count <= 2, parts[0].count == 3, parts.count == 1 || parts[1].count == 1 else {
                throw CSSError(usage, at: position)
            }
            written = Array(parts[0])
            alpha = parts.count == 2 ? parts[1].first : nil
        } else if space == .rgb || space == .hsl, args.count == 3 || args.count == 4,
                  args.allSatisfy({ $0.count == 1 }) {
            written = args.prefix(3).map { $0[0] }
            alpha = args.count == 4 ? args[3][0] : nil
        } else {
            throw CSSError(usage, at: position)
        }

        let specs = space.channels
        let keywords = origin == nil ? [] : specs.map(\.keyword)
        var channels = try zip(written, specs).map { component, spec in
            try channel(component, spec, keywords: keywords, function: name, at: position)
        }
        // The relative syntax keeps the origin's alpha unless it says otherwise.
        channels.append(try alpha.map { try channel($0, specs[3], keywords: keywords, function: name, at: position) }
                        ?? (origin == nil ? .number(1) : .channel("alpha")))

        let relative = RelativeColor(space: space, origin: origin ?? .none, channels: channels)
        guard let origin else { return .rgba(relative.evaluate(RGBA(r: 0, g: 0, b: 0))) }
        if let known = origin.constant { return .rgba(relative.evaluate(known)) }
        return .relative(relative)
    }

    /// One channel: a number, a percentage, an angle for a hue, `none`, a channel keyword in the
    /// relative syntax, or `calc()`, `min()`, `max()` or `clamp()` of those, as in
    /// `oklch(from <colour> l min(c, 0.1) h)`.
    private static func channel(_ component: CSSComponent, _ spec: RelativeColor.Space.Channel,
                                keywords: [String], function: String,
                                at position: CSSPosition) throws -> ColorCalc {
        switch component {
        case .number(let value, let unit):
            return .number(try channelValue(value, unit: unit, spec, written: component.text,
                                            function: function, at: position))
        case .ident("none"):
            return .number(0)
        case .ident(let word):
            guard !keywords.isEmpty else {
                throw CSSError("'\(word)' names a channel of another colour, which only the relative syntax "
                               + "has: \(function)(from <colour> …)", at: position)
            }
            guard keywords.contains(word) else {
                throw CSSError("'\(word)' is not a channel of \(function)(); they are "
                               + keywords.dropLast().joined(separator: ", ") + " and alpha", at: position)
            }
            return .channel(word)
        case .function("calc", let args), .function("", let args):
            guard args.count == 1, !args[0].isEmpty else {
                throw CSSError("'\(component.text)' takes one expression, with no commas", at: position)
            }
            var parser = CalcParser(tokens: args[0], position: position) { leaf in
                try channel(leaf, spec, keywords: keywords, function: function, at: position)
            }
            return try parser.parse()
        case .function(let name, let args) where name == "min" || name == "max" || name == "clamp":
            guard args.allSatisfy({ !$0.isEmpty }), name == "clamp" ? args.count == 3 : !args.isEmpty else {
                throw CSSError(name == "clamp"
                               ? "clamp() takes a least, a value and a most, as in clamp(0.02, c, 0.1)"
                               : "\(name)() takes one or more values separated by commas, as in \(name)(c, 0.1)",
                               at: position)
            }
            let terms = try args.map { arg in
                var parser = CalcParser(tokens: arg, position: position) { leaf in
                    try channel(leaf, spec, keywords: keywords, function: function, at: position)
                }
                return try parser.parse()
            }
            switch name {
            case "min": return .minimum(terms)
            case "max": return .maximum(terms)
            // As in CSS: the least wins over the most when they cross.
            default: return .maximum([terms[0], .minimum([terms[1], terms[2]])])
            }
        default:
            throw CSSError("'\(component.text)' is not a \(spec.label) for \(function)()", at: position)
        }
    }

    private static func channelValue(_ value: Double, unit: String?, _ spec: RelativeColor.Space.Channel,
                                     written: String, function: String,
                                     at position: CSSPosition) throws -> Double {
        switch unit {
        case nil: return value
        case "%" where !spec.isHue: return value / 100 * spec.percent
        case "deg" where spec.isHue: return value
        case "grad" where spec.isHue: return value * 0.9
        case "rad" where spec.isHue: return value * 180 / .pi
        case "turn" where spec.isHue: return value * 360
        default:
            let takes = spec.isHue ? "a hue is a number of degrees or an angle in deg, grad, rad or turn"
                : "a \(spec.label) is a number or a percentage"
            throw CSSError("'\(written)' does not belong in \(function)(): \(takes)", at: position)
        }
    }

    /// `color-mix(in oklch, accent 30%, white)`. Percentages work as in CSS: one missing is
    /// the rest of 100%, both missing are half each, and two that add up to less than 100%
    /// make the result that much more transparent.
    private static func colorMix(_ args: [[CSSComponent]], at position: CSSPosition) throws -> Color {
        let usage = "color-mix() takes a space and two colours, each with an optional percentage, "
            + "as in color-mix(in oklch, accent 30%, white)"
        guard args.count == 3 else { throw CSSError(usage, at: position) }
        guard args[0].count == 2, args[0][0].identValue == "in", let name = args[0][1].identValue else {
            throw CSSError(usage, at: position)
        }
        guard let space = ColorMix.Space(rawValue: name) else {
            throw CSSError("color-mix() mixes in oklab, oklch, srgb or srgb-linear, not '\(name)'", at: position)
        }
        func part(_ arg: [CSSComponent]) throws -> (color: Color, share: Double?) {
            var color: Color?
            var share: Double?
            for component in arg {
                if case .number(let value, let unit) = component, unit == "%" {
                    guard share == nil, (0...100).contains(value) else {
                        throw CSSError("a colour in color-mix() takes one percentage from 0% to 100%", at: position)
                    }
                    share = value / 100
                } else {
                    guard color == nil else { throw CSSError(usage, at: position) }
                    color = try self.color(component, at: position)
                }
            }
            guard let color else { throw CSSError(usage, at: position) }
            return (color, share)
        }
        let (a, b) = (try part(args[1]), try part(args[2]))
        let p1 = a.share ?? b.share.map { 1 - $0 } ?? 0.5
        let p2 = b.share ?? 1 - p1
        guard p1 + p2 > 0 else {
            throw CSSError("color-mix() needs one of its percentages to be more than 0%", at: position)
        }
        let mix = ColorMix(space: space, first: a.color, second: b.color, weight: p2 / (p1 + p2),
                           alpha: min(1, p1 + p2))
        if let x = a.color.constant, let y = b.color.constant { return .rgba(mix.evaluate(x, y)) }
        return .mixed(mix)
    }
}

/// `calc()` inside a colour channel: `+` and `-` below `*` and `/`, left to right, with
/// parentheses or a nested `calc()` to group.
private struct CalcParser {
    var tokens: [CSSComponent]
    var position: CSSPosition
    let leaf: (CSSComponent) throws -> ColorCalc
    var index = 0

    init(tokens: [CSSComponent], position: CSSPosition, leaf: @escaping (CSSComponent) throws -> ColorCalc) {
        self.tokens = tokens
        self.position = position
        self.leaf = leaf
    }

    mutating func parse() throws -> ColorCalc {
        let value = try sum()
        guard index == tokens.count else {
            throw CSSError("calc(\(tokens.text)) needs an operator before '\(tokens[index].text)'; "
                           + "+ and - need a space on each side", at: position)
        }
        return value
    }

    private mutating func sum() throws -> ColorCalc {
        var value = try product()
        while index < tokens.count, case .delim(let op) = tokens[index], op == "+" || op == "-" {
            index += 1
            value = .operation(op, value, try product())
        }
        return value
    }

    private mutating func product() throws -> ColorCalc {
        var value = try operand()
        while index < tokens.count {
            let op: Character
            switch tokens[index] {
            case .delim("*"): op = "*"
            case .slash: op = "/"
            default: return value
            }
            index += 1
            value = .operation(op, value, try operand())
        }
        return value
    }

    private mutating func operand() throws -> ColorCalc {
        guard index < tokens.count else {
            throw CSSError("calc(\(tokens.text)) ends with an operator", at: position)
        }
        let token = tokens[index]
        switch token {
        case .delim, .slash:
            throw CSSError("calc(\(tokens.text)) has '\(token.text)' where a value belongs", at: position)
        default:
            index += 1
            return try leaf(token)
        }
    }
}
