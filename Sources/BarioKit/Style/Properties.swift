import Foundation

// The typed value vocabulary, and the parsers that turn components into it. One parser per
// property, so `padding: 2pt 9pt` becomes edge insets and `background: backdrop blur(20pt)`
// becomes an enum case. DESIGN.md §7.

// MARK: - Colour

/// Colours stay symbolic until paint: `currentColor` inside a renderer's display list has to
/// resolve against the style it is drawn with, and a pure cascade is a testable cascade.
public indirect enum Color: Sendable, Hashable {
    case rgba(RGBA)
    /// Two colours mid-transition. Both are resolved at paint time and then blended, so a
    /// `system()` colour animates as correctly as a literal one.
    case mix(Color, Color, Double)
    /// Any `NSColor` class property, e.g. `system(labelColor)`.
    case system(String)
    /// The user's accent colour.
    case accent
    case current
    case none

    public static let clear = Color.rgba(RGBA(r: 0, g: 0, b: 0, a: 0))
}

// MARK: - Text

public enum FontFamily: Sendable, Hashable {
    case system
    case systemUI
    case monospace
    case named(String)
}

public struct FontSpec: Sendable, Hashable {
    public var family: FontFamily = .system
    /// The AppKit scale: 100 thin … 400 regular … 700 bold … 900 black.
    public var weight: Double = 400
    public var size: Double = 12

    public init(family: FontFamily = .system, weight: Double = 400, size: Double = 12) {
        self.family = family
        self.weight = weight
        self.size = size
    }
}

public enum TextTransform: String, Sendable, Hashable, CaseIterable {
    case none, uppercase, lowercase, capitalize
}

/// DESIGN.md §13: an invisible bar with bare text needs contrast handling. `auto` asks the
/// painter to sample the backdrop under the item and pick light or dark.
public enum Contrast: String, Sendable, Hashable, CaseIterable {
    case none, auto, light, dark
}

// MARK: - Box

public struct Corners: Sendable, Hashable {
    public var topLeft: Double
    public var topRight: Double
    public var bottomRight: Double
    public var bottomLeft: Double

    public static let zero = Corners(0)

    public init(topLeft: Double, topRight: Double, bottomRight: Double, bottomLeft: Double) {
        self.topLeft = topLeft; self.topRight = topRight
        self.bottomRight = bottomRight; self.bottomLeft = bottomLeft
    }

    public init(_ all: Double) { self.init(topLeft: all, topRight: all, bottomRight: all, bottomLeft: all) }

    public init?(values: [Double]) {
        switch values.count {
        case 1: self.init(values[0])
        case 2: self.init(topLeft: values[0], topRight: values[1], bottomRight: values[0], bottomLeft: values[1])
        case 3: self.init(topLeft: values[0], topRight: values[1], bottomRight: values[2], bottomLeft: values[1])
        case 4: self.init(topLeft: values[0], topRight: values[1], bottomRight: values[2], bottomLeft: values[3])
        default: return nil
        }
    }

    public var isZero: Bool { topLeft == 0 && topRight == 0 && bottomRight == 0 && bottomLeft == 0 }
}

// MARK: - Background

public struct Backdrop: Sendable, Hashable {
    public var blur: Double?
    public var saturate: Double?
}

public struct GradientStop: Sendable, Hashable {
    public var color: Color
    /// 0…1, or nil for "spread evenly".
    public var location: Double?
}

public struct Gradient: Sendable, Hashable {
    /// Degrees, CSS convention: 0 points up, 90 points right.
    public var angle: Double = 180
    public var stops: [GradientStop] = []
}

public enum Background: Sendable, Hashable {
    case none
    case color(Color)
    case gradient(Gradient)
    /// The probe's photograph. DESIGN.md §7.
    case backdrop(Backdrop)
}

// MARK: - Effects

public struct Shadow: Sendable, Hashable {
    public var dx: Double = 0
    public var dy: Double = 0
    public var blur: Double = 0
    public var color: Color = .rgba(RGBA(r: 0, g: 0, b: 0, a: 0.5))
}

public enum Easing: Sendable, Hashable {
    case linear
    case cubicBezier(Double, Double, Double, Double)

    public static let ease = Easing.cubicBezier(0.25, 0.1, 0.25, 1)
    public static let easeIn = Easing.cubicBezier(0.42, 0, 1, 1)
    public static let easeOut = Easing.cubicBezier(0, 0, 0.58, 1)
    public static let easeInOut = Easing.cubicBezier(0.42, 0, 0.58, 1)

    public func evaluate(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        switch self {
        case .linear:
            return t
        case .cubicBezier(let x1, let y1, let x2, let y2):
            // Solve x(u) = t for u by bisection — 24 steps is well under a float's worth and
            // costs nothing at the rate styles animate.
            func bezier(_ a: Double, _ b: Double, _ u: Double) -> Double {
                let v = 1 - u
                return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
            }
            var low = 0.0, high = 1.0, u = t
            for _ in 0..<24 {
                let x = bezier(x1, x2, u)
                if abs(x - t) < 1e-5 { break }
                if x < t { low = u } else { high = u }
                u = (low + high) / 2
            }
            return bezier(y1, y2, u)
        }
    }
}

/// `transform: translate(4pt, -2pt) rotate(45deg) scale(1.2)`. Kept as its parts rather than a
/// matrix, because the parts are what eases: a matrix halfway through a full turn is no turn at
/// all. The parts apply in one order whatever order they are written in: scale, then rotate,
/// then translate, all about the centre of the box. DESIGN.md §7, §9.
public struct Transform: Sendable, Hashable {
    /// Points; y runs down, as in CSS.
    public var translateX: Double = 0
    public var translateY: Double = 0
    /// Degrees, clockwise, as in CSS.
    public var rotate: Double = 0
    public var scaleX: Double = 1
    public var scaleY: Double = 1

    public init(translateX: Double = 0, translateY: Double = 0, rotate: Double = 0,
                scaleX: Double = 1, scaleY: Double = 1) {
        self.translateX = translateX
        self.translateY = translateY
        self.rotate = rotate
        self.scaleX = scaleX
        self.scaleY = scaleY
    }

    public static let identity = Transform()
}

/// One stop of a `@keyframes` rule, resolved for one node: what it says about the two
/// properties an animation may move.
public struct Keyframe: Sendable, Hashable {
    /// 0…1.
    public var offset: Double
    public var transform: Transform?
    public var opacity: Double?

    public init(offset: Double, transform: Transform? = nil, opacity: Double? = nil) {
        self.offset = offset
        self.transform = transform
        self.opacity = opacity
    }
}

/// `animation: spin 1s linear infinite`: motion that loops, over `transform` and `opacity`
/// only, so the compositor can run it with no frames from bario. DESIGN.md §7, §9.
public struct Animation: Sendable, Hashable {
    public var name: String
    public var duration: Double
    public var easing: Easing = .ease
    public var delay: Double = 0
    /// How many times it runs; `.infinity` for `infinite`.
    public var iterations: Double = 1
    /// Every other iteration runs backwards.
    public var alternate = false
    /// The `@keyframes` it names, resolved by the cascade against the node it styles.
    public var keyframes: [Keyframe] = []

    public init(name: String, duration: Double, easing: Easing = .ease, delay: Double = 0,
                iterations: Double = 1, alternate: Bool = false, keyframes: [Keyframe] = []) {
        self.name = name
        self.duration = duration
        self.easing = easing
        self.delay = delay
        self.iterations = iterations
        self.alternate = alternate
        self.keyframes = keyframes
    }
}

public struct Transition: Sendable, Hashable {
    /// A property name, `all`, or the reserved `layout`.
    public var property: String
    public var duration: Double
    public var delay: Double = 0
    public var easing: Easing = .ease

    public func applies(to property: String) -> Bool {
        self.property == "all" || self.property == property
    }
}

// MARK: - Small enums

public enum IconRendering: String, Sendable, Hashable, CaseIterable {
    case monochrome, hierarchical, palette, multicolor
}

public enum LineCap: String, Sendable, Hashable, CaseIterable {
    case butt, round, square
}

// MARK: - The property list

public enum StyleProperty: String, Sendable, CaseIterable {
    case padding, margin
    case border
    case borderWidth = "border-width"
    case borderColor = "border-color"
    case borderRadius = "border-radius"
    case minWidth = "min-width"
    case maxWidth = "max-width"
    case width
    case opacity
    case gap
    case background
    case font
    case fontFamily = "font-family"
    case fontSize = "font-size"
    case fontWeight = "font-weight"
    case color
    case letterSpacing = "letter-spacing"
    case textTransform = "text-transform"
    case contrast
    case iconSize = "icon-size"
    case iconColor = "icon-color"
    case iconWeight = "icon-weight"
    case iconRendering = "icon-rendering"
    case fill, track
    case strokeWidth = "stroke-width"
    case lineCap = "line-cap"
    case shadow
    case transform
    case transition
    case animation

    /// Properties that pass down to children, as in CSS.
    public var isInherited: Bool {
        switch self {
        case .color, .font, .fontFamily, .fontSize, .fontWeight, .letterSpacing, .textTransform,
             .contrast, .iconSize, .iconColor, .iconWeight, .iconRendering,
             .fill, .track, .strokeWidth, .lineCap:
            return true
        default:
            return false
        }
    }

    public static func isCustom(_ name: String) -> Bool { name.hasPrefix("--") }

    /// Parse a declaration for its side effect of reporting errors where they are written.
    @discardableResult
    static func validate(_ declaration: Declaration) throws -> StyleProperty? {
        if isCustom(declaration.property) { return nil }
        guard let property = StyleProperty(rawValue: declaration.property) else {
            throw CSSError("unknown property '\(declaration.property)'\(suggestion(for: declaration.property))",
                           at: declaration.position)
        }
        var style = Style.initial
        try style.apply(property, declaration.value, at: declaration.position)
        return property
    }

    private static func suggestion(for name: String) -> String {
        let best = allCases
            .map { ($0.rawValue, editDistance(name, $0.rawValue)) }
            .min { $0.1 < $1.1 }
        guard let best, best.1 <= max(2, name.count / 3) else { return "" }
        return "; did you mean '\(best.0)'?"
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let insert = row[j] + 1
                let delete = row[j - 1] + 1
                let replace = previous + (a[i - 1] == b[j - 1] ? 0 : 1)
                previous = row[j]
                row[j] = min(insert, delete, replace)
            }
        }
        return row[b.count]
    }
}

// MARK: - Value parsers

enum CSSValue {
    static func fail(_ what: String, _ components: [CSSComponent], at position: CSSPosition) -> CSSError {
        CSSError("'\(components.text)' is not \(what)", at: position)
    }

    static func length(_ components: [CSSComponent], at position: CSSPosition) throws -> Double {
        guard components.count == 1, case .number(let value, let unit) = components[0] else {
            throw fail("a length", components, at: position)
        }
        switch unit {
        case nil, "pt", "px": return value            // there is no CSS pixel here; px means pt
        default: throw CSSError("'\(components.text)': lengths are in pt", at: position)
        }
    }

    static func lengths(_ components: [CSSComponent], at position: CSSPosition) throws -> [Double] {
        try components.map { try length([$0], at: position) }
    }

    static func number(_ components: [CSSComponent], at position: CSSPosition) throws -> Double {
        guard components.count == 1, case .number(let value, let unit) = components[0] else {
            throw fail("a number", components, at: position)
        }
        return unit == "%" ? value / 100 : value
    }

    static func duration(_ component: CSSComponent, at position: CSSPosition) throws -> Double {
        guard case .number(let value, let unit) = component else {
            throw fail("a duration", [component], at: position)
        }
        switch unit {
        case "ms": return value / 1000
        case "s": return value
        default: throw CSSError("'\(component.text)': durations are in ms or s", at: position)
        }
    }

    static func keyword<T: RawRepresentable & CaseIterable>(
        _ components: [CSSComponent], _ type: T.Type, at position: CSSPosition
    ) throws -> T where T.RawValue == String {
        guard components.count == 1, let name = components[0].identValue, let value = T(rawValue: name) else {
            let names = T.allCases.map(\.rawValue).joined(separator: ", ")
            throw CSSError("'\(components.text)' is not one of \(names)", at: position)
        }
        return value
    }

    static func insets(_ components: [CSSComponent], at position: CSSPosition) throws -> Insets {
        guard let insets = Insets(values: try lengths(components, at: position)) else {
            throw CSSError("'\(components.text)' needs 1 to 4 lengths", at: position)
        }
        return insets
    }

    static func corners(_ components: [CSSComponent], at position: CSSPosition) throws -> Corners {
        guard let corners = Corners(values: try lengths(components, at: position)) else {
            throw CSSError("'\(components.text)' needs 1 to 4 lengths", at: position)
        }
        return corners
    }

    // MARK: Colour

    static let namedColors: [String: RGBA] = [
        "black": RGBA(r: 0, g: 0, b: 0),
        "white": RGBA(r: 1, g: 1, b: 1),
        "red": RGBA(r: 1, g: 0, b: 0),
        "green": RGBA(r: 0, g: 0.5, b: 0),
        "blue": RGBA(r: 0, g: 0, b: 1),
        "yellow": RGBA(r: 1, g: 1, b: 0),
        "orange": RGBA(r: 1, g: 0.65, b: 0),
        "purple": RGBA(r: 0.5, g: 0, b: 0.5),
        "gray": RGBA(r: 0.5, g: 0.5, b: 0.5),
        "grey": RGBA(r: 0.5, g: 0.5, b: 0.5),
    ]

    static func color(_ components: [CSSComponent], at position: CSSPosition) throws -> Color {
        guard components.count == 1 else { throw fail("a colour", components, at: position) }
        return try color(components[0], at: position)
    }

    static func color(_ component: CSSComponent, at position: CSSPosition) throws -> Color {
        switch component {
        case .hash(let hex):
            return .rgba(try hexColor(hex, at: position))
        case .ident(let name):
            switch name {
            case "none", "transparent": return .none
            case "accent": return .accent
            case "currentColor", "currentcolor": return .current
            default:
                guard let rgba = namedColors[name.lowercased()] else {
                    throw CSSError("'\(name)' is not a colour; use a hex value, rgba(), hsl(), "
                                   + "system(labelColor) or accent", at: position)
                }
                return .rgba(rgba)
            }
        case .function(let name, let args):
            return try colorFunction(name, args, at: position)
        default:
            throw fail("a colour", [component], at: position)
        }
    }

    private static func hexColor(_ hex: String, at position: CSSPosition) throws -> RGBA {
        let digits = Array(hex)
        func channel(_ index: Int) -> CGFloat {
            if digits.count <= 4 {
                let v = CGFloat(Int(String(digits[index]), radix: 16) ?? 0)
                return v * 17 / 255
            }
            let pair = String(digits[index * 2...index * 2 + 1])
            return CGFloat(Int(pair, radix: 16) ?? 0) / 255
        }
        switch digits.count {
        case 3: return RGBA(r: channel(0), g: channel(1), b: channel(2))
        case 4: return RGBA(r: channel(0), g: channel(1), b: channel(2), a: channel(3))
        case 6: return RGBA(r: channel(0), g: channel(1), b: channel(2))
        case 8: return RGBA(r: channel(0), g: channel(1), b: channel(2), a: channel(3))
        default:
            throw CSSError("'#\(hex)' is not a colour; write #rgb, #rgba, #rrggbb or #rrggbbaa", at: position)
        }
    }

    private static func colorFunction(_ name: String, _ args: [[CSSComponent]],
                                      at position: CSSPosition) throws -> Color {
        func scalar(_ index: Int, max: Double) throws -> CGFloat {
            guard index < args.count, args[index].count == 1,
                  case .number(let value, let unit) = args[index][0] else {
                throw CSSError("\(name)() is missing an argument", at: position)
            }
            return CGFloat(unit == "%" ? value / 100 : value / max)
        }
        switch name {
        case "rgb", "rgba":
            guard args.count == 3 || args.count == 4 else {
                throw CSSError("rgba() takes 3 or 4 arguments", at: position)
            }
            let alpha = args.count == 4 ? try scalar(3, max: 1) : 1
            return .rgba(RGBA(r: try scalar(0, max: 255), g: try scalar(1, max: 255),
                              b: try scalar(2, max: 255), a: alpha))
        case "hsl", "hsla":
            guard args.count == 3 || args.count == 4 else {
                throw CSSError("hsl() takes 3 or 4 arguments", at: position)
            }
            let hue = try scalar(0, max: 1) / 360 * 360        // degrees, kept as written
            let saturation = try scalar(1, max: 100)
            let lightness = try scalar(2, max: 100)
            let alpha = args.count == 4 ? try scalar(3, max: 1) : 1
            return .rgba(hsl(hue: Double(hue), saturation: Double(saturation),
                             lightness: Double(lightness), alpha: alpha))
        case "system":
            guard args.count == 1, let colorName = args[0].first?.identValue, args[0].count == 1 else {
                throw CSSError("system() takes an NSColor name, e.g. system(labelColor)", at: position)
            }
            return .system(colorName)
        default:
            throw CSSError("'\(name)()' is not a colour function; the ones that exist are "
                           + "rgb(), rgba(), hsl(), hsla() and system()", at: position)
        }
    }

    static func hsl(hue: Double, saturation: Double, lightness: Double, alpha: CGFloat) -> RGBA {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGBA(r: CGFloat(r + m), g: CGFloat(g + m), b: CGFloat(b + m), a: alpha)
    }

    // MARK: Font

    static let weights: [String: Double] = [
        "ultralight": 100, "thin": 200, "light": 300, "regular": 400, "normal": 400,
        "medium": 500, "semibold": 600, "bold": 700, "heavy": 800, "black": 900,
    ]

    static func fontWeight(_ components: [CSSComponent], at position: CSSPosition) throws -> Double {
        guard components.count == 1 else { throw fail("a font weight", components, at: position) }
        if let name = components[0].identValue, let weight = weights[name] { return weight }
        if let value = components[0].numberValue, components[0].unit == nil { return value }
        throw CSSError("'\(components.text)' is not a font weight; use 100…900 or one of "
                       + weights.keys.sorted().joined(separator: ", "), at: position)
    }

    static func fontFamily(_ components: [CSSComponent], at position: CSSPosition) throws -> FontFamily {
        guard let first = components.first else { throw fail("a font family", components, at: position) }
        switch first {
        case .string(let name): return .named(name)
        case .ident("system-ui"): return .systemUI
        case .ident("monospace"), .ident("ui-monospace"): return .monospace
        case .ident("system"): return .system
        case .ident(let name): return .named(name)
        default: throw fail("a font family", components, at: position)
        }
    }

    /// `font: 12pt "SF Pro Text" medium` — order does not matter, each piece is recognised.
    static func font(_ components: [CSSComponent], base: FontSpec, at position: CSSPosition) throws -> FontSpec {
        var font = base
        for component in components {
            switch component {
            case .number(let value, let unit):
                // Order-agnostic, so a bare 100…900 in hundreds is a weight and anything
                // else is a size.
                if unit == "pt" || unit == "px" {
                    font.size = value
                } else if unit == nil, (100...900).contains(value),
                          value.truncatingRemainder(dividingBy: 100) == 0 {
                    font.weight = value
                } else if unit == nil {
                    font.size = value
                } else {
                    throw CSSError("'\(component.text)': lengths in a font shorthand are in pt", at: position)
                }
            case .ident(let name) where weights[name] != nil:
                font.weight = weights[name]!
            case .string, .ident:
                font.family = try fontFamily([component], at: position)
            default:
                throw CSSError("'\(component.text)' does not belong in a font shorthand", at: position)
            }
        }
        return font
    }

    // MARK: Background

    static func background(_ components: [CSSComponent], at position: CSSPosition) throws -> Background {
        if components.count == 1, components[0].identValue == "none" { return .none }
        if components.first?.identValue == "backdrop" {
            var backdrop = Backdrop()
            for component in components.dropFirst() {
                guard case .function(let name, let args) = component else {
                    throw CSSError("'\(component.text)' does not belong after backdrop; expected "
                                   + "blur() or saturate()", at: position)
                }
                switch name {
                case "blur": backdrop.blur = try length(args.first ?? [], at: position)
                case "saturate": backdrop.saturate = try number(args.first ?? [], at: position)
                default:
                    throw CSSError("backdrop takes blur() and saturate(), not \(name)()", at: position)
                }
            }
            return .backdrop(backdrop)
        }
        if case .function("linear-gradient", let args)? = components.first, components.count == 1 {
            return .gradient(try gradient(args, at: position))
        }
        return .color(try color(components, at: position))
    }

    private static func gradient(_ args: [[CSSComponent]], at position: CSSPosition) throws -> Gradient {
        var gradient = Gradient()
        var rest = args[...]
        if let first = args.first, first.count == 1, case .number(let angle, let unit) = first[0] {
            guard unit == "deg" else { throw CSSError("a gradient angle is in deg", at: position) }
            gradient.angle = angle
            rest = args.dropFirst()
        }
        gradient.stops = try rest.map { piece in
            guard let colorComponent = piece.first else {
                throw CSSError("a gradient stop needs a colour", at: position)
            }
            var stop = GradientStop(color: try color(colorComponent, at: position), location: nil)
            if piece.count > 1 {
                guard case .number(let value, let unit) = piece[1], unit == "%" else {
                    throw CSSError("a gradient stop's position is a percentage", at: position)
                }
                stop.location = value / 100
            }
            return stop
        }
        guard gradient.stops.count >= 2 else {
            throw CSSError("linear-gradient() needs at least two colours", at: position)
        }
        return gradient
    }

    // MARK: Effects

    static func shadow(_ components: [CSSComponent], at position: CSSPosition) throws -> Shadow? {
        if components.count == 1, components[0].identValue == "none" { return nil }
        var shadow = Shadow()
        var numbers: [Double] = []
        var sawColor = false
        for component in components {
            if case .number = component {
                numbers.append(try length([component], at: position))
            } else {
                shadow.color = try color(component, at: position)
                sawColor = true
            }
        }
        guard numbers.count >= 2, numbers.count <= 3 else {
            throw CSSError("shadow takes an x offset, a y offset, an optional blur and a colour",
                           at: position)
        }
        shadow.dx = numbers[0]
        shadow.dy = numbers[1]
        if numbers.count > 2 { shadow.blur = numbers[2] }
        if !sawColor { shadow.color = .rgba(RGBA(r: 0, g: 0, b: 0, a: 0.5)) }
        return shadow
    }

    static func transform(_ components: [CSSComponent], at position: CSSPosition) throws -> Transform {
        if components.count == 1, components[0].identValue == "none" { return .identity }
        var transform = Transform()
        var seen: Set<String> = []
        for component in components {
            guard case .function(let name, let args) = component else {
                throw CSSError("'\(component.text)' is not a transform; use translate(), rotate() or scale()",
                               at: position)
            }
            guard seen.insert(name).inserted else {
                throw CSSError("transform takes \(name)() once; the parts apply as scale, rotate, "
                               + "then translate, whatever order they are written in", at: position)
            }
            switch name {
            case "translate":
                guard (1...2).contains(args.count) else {
                    throw CSSError("translate() takes an x and an optional y", at: position)
                }
                transform.translateX = try length(args[0], at: position)
                if args.count > 1 { transform.translateY = try length(args[1], at: position) }
            case "rotate":
                guard args.count == 1 else { throw CSSError("rotate() takes one angle", at: position) }
                transform.rotate = try angle(args[0], at: position)
            case "scale":
                guard (1...2).contains(args.count) else {
                    throw CSSError("scale() takes one factor, or an x and a y", at: position)
                }
                transform.scaleX = try number(args[0], at: position)
                transform.scaleY = args.count > 1 ? try number(args[1], at: position) : transform.scaleX
            default:
                throw CSSError("'\(name)()' is not a transform; the ones that exist are translate(), "
                               + "rotate() and scale()", at: position)
            }
        }
        return transform
    }

    /// Degrees, from `deg` or `turn`.
    static func angle(_ components: [CSSComponent], at position: CSSPosition) throws -> Double {
        guard components.count == 1, case .number(let value, let unit) = components[0] else {
            throw fail("an angle", components, at: position)
        }
        switch unit {
        case "deg": return value
        case "turn": return value * 360
        case nil where value == 0: return 0
        default: throw CSSError("'\(components.text)': angles are in deg or turn", at: position)
        }
    }

    /// `animation: name duration [easing] [delay] [count | infinite] [alternate]`, and a list of
    /// them separated by commas. The names are resolved by the cascade.
    static func animations(_ components: [CSSComponent], at position: CSSPosition) throws -> [Animation] {
        if components.count == 1, components[0].identValue == "none" { return [] }
        return try components.splitOnCommas().map { piece in
            guard let name = piece.first?.identValue else {
                throw CSSError("an animation starts with the name of its @keyframes", at: position)
            }
            var animation = Animation(name: name, duration: 0)
            var durations: [Double] = []
            var counted = false
            for component in piece.dropFirst() {
                switch component {
                case .number(let value, let unit) where unit == nil:
                    guard value >= 0, !counted else {
                        throw CSSError("an animation takes one iteration count", at: position)
                    }
                    animation.iterations = value
                    counted = true
                case .number:
                    durations.append(try duration(component, at: position))
                case .ident("infinite"):
                    guard !counted else {
                        throw CSSError("an animation takes one iteration count", at: position)
                    }
                    animation.iterations = .infinity
                    counted = true
                case .ident("alternate"):
                    animation.alternate = true
                case .ident("normal"):
                    animation.alternate = false
                case .ident(let word):
                    guard let easing = easingNamed(word) else {
                        throw CSSError("'\(word)' does not belong in an animation; it takes a name, a duration, "
                                       + "an easing, a delay, a count or infinite, and alternate", at: position)
                    }
                    animation.easing = easing
                case .function("cubic-bezier", let args):
                    let values = try args.map { try number($0, at: position) }
                    guard values.count == 4 else {
                        throw CSSError("cubic-bezier() takes four numbers", at: position)
                    }
                    animation.easing = .cubicBezier(values[0], values[1], values[2], values[3])
                default:
                    throw CSSError("'\(component.text)' does not belong in an animation", at: position)
                }
            }
            guard let first = durations.first, first > 0 else {
                throw CSSError("animation '\(name)' needs a duration", at: position)
            }
            animation.duration = first
            if durations.count > 1 { animation.delay = durations[1] }
            return animation
        }
    }

    static func transitions(_ components: [CSSComponent], at position: CSSPosition) throws -> [Transition] {
        if components.count == 1, components[0].identValue == "none" { return [] }
        return try components.splitOnCommas().map { piece in
            guard let name = piece.first?.identValue else {
                throw CSSError("a transition starts with a property name, or 'all'", at: position)
            }
            guard name == "all" || name == "layout" || StyleProperty(rawValue: name) != nil
                    || StyleProperty.isCustom(name) else {
                throw CSSError("'\(name)' is not a property, so it cannot transition", at: position)
            }
            var transition = Transition(property: name, duration: 0)
            var durations: [Double] = []
            for component in piece.dropFirst() {
                switch component {
                case .number: durations.append(try duration(component, at: position))
                case .ident(let word):
                    guard let easing = easingNamed(word) else {
                        throw CSSError("'\(word)' is not an easing; use linear, ease, ease-in, "
                                       + "ease-out or ease-in-out", at: position)
                    }
                    transition.easing = easing
                case .function("cubic-bezier", let args):
                    let values = try args.map { try number($0, at: position) }
                    guard values.count == 4 else {
                        throw CSSError("cubic-bezier() takes four numbers", at: position)
                    }
                    transition.easing = .cubicBezier(values[0], values[1], values[2], values[3])
                default:
                    throw CSSError("'\(component.text)' does not belong in a transition", at: position)
                }
            }
            guard let first = durations.first else {
                throw CSSError("transition '\(name)' has no duration", at: position)
            }
            transition.duration = first
            if durations.count > 1 { transition.delay = durations[1] }
            return transition
        }
    }

    static func easingNamed(_ name: String) -> Easing? {
        switch name {
        case "linear": return .linear
        case "ease": return .ease
        case "ease-in": return .easeIn
        case "ease-out": return .easeOut
        case "ease-in-out": return .easeInOut
        default: return nil
        }
    }
}
