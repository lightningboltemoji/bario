import Foundation

/// Every node in the scene resolves to exactly one of these. Colours and fonts stay
/// symbolic; the painter resolves them against the current appearance.
public struct Style: Sendable, Hashable {
    // box
    public var padding: Insets = .zero
    public var margin: Insets = .zero
    public var borderWidth: Double = 0
    public var borderColor: Color = .none
    public var borderRadius: Corners = .zero
    public var cornerShape: CornerShapes = .round
    public var minWidth: Double?
    public var maxWidth: Double?
    public var width: Double?
    public var opacity: Double = 1
    public var gap: Double = 0

    // background
    public var background: Background = .none

    // text (inherited)
    public var font = FontSpec()
    public var color: Color = .system("labelColor")
    public var letterSpacing: Double = 0
    public var textTransform: TextTransform = .none
    public var contrast: Contrast = .none

    // icons (inherited)
    public var iconSize: Double?
    public var iconColor: Color?
    public var iconWeight: Double?
    public var iconRendering: IconRendering = .monochrome

    // meters and graphs (inherited)
    public var fill: Color = .current
    public var track: Color = .rgba(RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.35))
    public var strokeWidth: Double = 2
    public var lineCap: LineCap = .round

    // effects
    public var shadow: Shadow?
    public var transform = Transform.identity
    public var transitions: [Transition] = []
    public var animations: [Animation] = []

    /// `--name` declarations, kept as components so renderers can read whatever they want.
    public var custom: [String: [CSSComponent]] = [:]

    public init() {}

    public static let initial = Style()

    /// The starting point for a child: inherited properties come down, the rest reset.
    public func inherited() -> Style {
        var style = Style()
        style.font = font
        style.color = color
        style.letterSpacing = letterSpacing
        style.textTransform = textTransform
        style.contrast = contrast
        style.iconSize = iconSize
        style.iconColor = iconColor
        style.iconWeight = iconWeight
        style.iconRendering = iconRendering
        style.fill = fill
        style.track = track
        style.strokeWidth = strokeWidth
        style.lineCap = lineCap
        style.custom = custom
        return style
    }

    /// The resolved icon size and colour, which fall back to the text's.
    public var effectiveIconSize: Double { iconSize ?? font.size }
    public var effectiveIconColor: Color { iconColor ?? color }
    public var effectiveIconWeight: Double { iconWeight ?? font.weight }

    public func transition(for property: String) -> Transition? {
        transitions.last { $0.applies(to: property) }
    }

    // MARK: - Applying a declaration

    public mutating func apply(_ property: StyleProperty, _ value: [CSSComponent],
                               at position: CSSPosition) throws {
        switch property {
        case .padding: padding = try CSSValue.insets(value, at: position)
        case .margin: margin = try CSSValue.insets(value, at: position)
        case .border:
            // `border: 1pt rgba(…)`, either part optional.
            var width: Double?
            var color: Color?
            for component in value {
                if case .number = component { width = try CSSValue.length([component], at: position) }
                else { color = try CSSValue.color(component, at: position) }
            }
            guard width != nil || color != nil else {
                throw CSSError("border takes a width and a colour", at: position)
            }
            if let width { borderWidth = width }
            if let color { borderColor = color }
        case .borderWidth: borderWidth = try CSSValue.length(value, at: position)
        case .borderColor: borderColor = try CSSValue.color(value, at: position)
        case .borderRadius: borderRadius = try CSSValue.corners(value, at: position)
        case .cornerShape: cornerShape = try CSSValue.cornerShapes(value, at: position)
        case .minWidth: minWidth = try CSSValue.length(value, at: position)
        case .maxWidth: maxWidth = try CSSValue.length(value, at: position)
        case .width: width = try CSSValue.length(value, at: position)
        case .opacity: opacity = min(1, max(0, try CSSValue.number(value, at: position)))
        case .gap: gap = try CSSValue.length(value, at: position)
        case .background: background = try CSSValue.background(value, at: position)
        case .font: font = try CSSValue.font(value, base: font, at: position)
        case .fontFamily: font.family = try CSSValue.fontFamily(value, at: position)
        case .fontSize: font.size = try CSSValue.length(value, at: position)
        case .fontWeight: font.weight = try CSSValue.fontWeight(value, at: position)
        case .color: color = try CSSValue.color(value, at: position)
        case .letterSpacing: letterSpacing = try CSSValue.length(value, at: position)
        case .textTransform: textTransform = try CSSValue.keyword(value, TextTransform.self, at: position)
        case .contrast: contrast = try CSSValue.keyword(value, Contrast.self, at: position)
        case .iconSize: iconSize = try CSSValue.length(value, at: position)
        case .iconColor: iconColor = try CSSValue.color(value, at: position)
        case .iconWeight: iconWeight = try CSSValue.fontWeight(value, at: position)
        case .iconRendering: iconRendering = try CSSValue.keyword(value, IconRendering.self, at: position)
        case .fill: fill = try CSSValue.color(value, at: position)
        case .track: track = try CSSValue.color(value, at: position)
        case .strokeWidth: strokeWidth = try CSSValue.length(value, at: position)
        case .lineCap: lineCap = try CSSValue.keyword(value, LineCap.self, at: position)
        case .shadow: shadow = try CSSValue.shadow(value, at: position)
        case .transform: transform = try CSSValue.transform(value, at: position)
        case .transition: transitions = try CSSValue.transitions(value, at: position)
        case .animation: animations = try CSSValue.animations(value, at: position)
        }
    }
}

// MARK: - Interpolation

extension StyleProperty {
    /// What `transition` can move. Everything else snaps.
    public static let animatable: [StyleProperty] = [
        .padding, .margin, .borderWidth, .borderColor, .borderRadius, .cornerShape, .opacity, .gap, .background,
        .color, .letterSpacing, .fill, .track, .strokeWidth, .fontSize, .fontWeight,
        .iconSize, .iconColor, .shadow, .transform,
    ]
}

extension Style {
    /// Blend one property from `a` toward the value this style already holds. The animator
    /// works one property at a time, because each has its own transition and start time.
    public mutating func blend(_ property: StyleProperty, from a: Style, t: Double) {
        guard t < 1 else { return }
        guard t > 0 else { take(property, from: a); return }
        switch property {
        case .padding: padding = lerp(a.padding, padding, t)
        case .margin: margin = lerp(a.margin, margin, t)
        case .borderWidth: borderWidth = lerp(a.borderWidth, borderWidth, t)
        case .borderColor: borderColor = Color.blend(a.borderColor, borderColor, t)
        case .borderRadius: borderRadius = lerp(a.borderRadius, borderRadius, t)
        case .cornerShape: cornerShape = lerp(a.cornerShape, cornerShape, t)
        case .opacity: opacity = lerp(a.opacity, opacity, t)
        case .gap: gap = lerp(a.gap, gap, t)
        case .background: background = Background.blend(a.background, background, t)
        case .color: color = Color.blend(a.color, color, t)
        case .letterSpacing: letterSpacing = lerp(a.letterSpacing, letterSpacing, t)
        case .fill: fill = Color.blend(a.fill, fill, t)
        case .track: track = Color.blend(a.track, track, t)
        case .strokeWidth: strokeWidth = lerp(a.strokeWidth, strokeWidth, t)
        case .fontSize: font.size = lerp(a.font.size, font.size, t)
        case .fontWeight: font.weight = lerp(a.font.weight, font.weight, t)
        case .iconSize:
            // An unset icon size is the font size, so easing to or from one has a start.
            if let to = iconSize { iconSize = lerp(a.effectiveIconSize, to, t) }
        case .iconColor:
            if let from = a.iconColor, let to = iconColor { iconColor = Color.blend(from, to, t) }
        case .shadow:
            if let from = a.shadow, let to = shadow {
                shadow = Shadow(dx: lerp(from.dx, to.dx, t), dy: lerp(from.dy, to.dy, t),
                                blur: lerp(from.blur, to.blur, t),
                                color: Color.blend(from.color, to.color, t))
            }
        case .transform:
            // `none` is no distance to ease from, so a perspective on one side holds for the
            // whole way; with no rotation left at the end, it shows nothing.
            let (from, to) = (a.transform.perspective, transform.perspective)
            transform = Transform(translateX: lerp(a.transform.translateX, transform.translateX, t),
                                  translateY: lerp(a.transform.translateY, transform.translateY, t),
                                  rotate: lerp(a.transform.rotate, transform.rotate, t),
                                  rotateX: lerp(a.transform.rotateX, transform.rotateX, t),
                                  rotateY: lerp(a.transform.rotateY, transform.rotateY, t),
                                  scaleX: lerp(a.transform.scaleX, transform.scaleX, t),
                                  scaleY: lerp(a.transform.scaleY, transform.scaleY, t),
                                  perspective: from > 0 && to > 0 ? lerp(from, to, t) : max(from, to))
        default:
            break
        }
    }

    /// Whether two styles disagree about one property.
    public func differs(in property: StyleProperty, from other: Style) -> Bool {
        switch property {
        case .padding: return padding != other.padding
        case .margin: return margin != other.margin
        case .borderWidth: return borderWidth != other.borderWidth
        case .borderColor: return borderColor != other.borderColor
        case .borderRadius: return borderRadius != other.borderRadius
        case .cornerShape: return cornerShape != other.cornerShape
        case .opacity: return opacity != other.opacity
        case .gap: return gap != other.gap
        case .background: return background != other.background
        case .color: return color != other.color
        case .letterSpacing: return letterSpacing != other.letterSpacing
        case .fill: return fill != other.fill
        case .track: return track != other.track
        case .strokeWidth: return strokeWidth != other.strokeWidth
        case .fontSize: return font.size != other.font.size
        case .fontWeight: return font.weight != other.font.weight
        case .iconSize: return iconSize != other.iconSize
        case .iconColor: return iconColor != other.iconColor
        case .shadow: return shadow != other.shadow
        case .transform: return transform != other.transform
        default: return false
        }
    }

    /// Copy one property's value from another style.
    public mutating func take(_ property: StyleProperty, from other: Style) {
        switch property {
        case .padding: padding = other.padding
        case .margin: margin = other.margin
        case .borderWidth: borderWidth = other.borderWidth
        case .borderColor: borderColor = other.borderColor
        case .borderRadius: borderRadius = other.borderRadius
        case .cornerShape: cornerShape = other.cornerShape
        case .opacity: opacity = other.opacity
        case .gap: gap = other.gap
        case .background: background = other.background
        case .color: color = other.color
        case .letterSpacing: letterSpacing = other.letterSpacing
        case .fill: fill = other.fill
        case .track: track = other.track
        case .strokeWidth: strokeWidth = other.strokeWidth
        case .fontSize: font.size = other.font.size
        case .fontWeight: font.weight = other.font.weight
        case .iconSize: iconSize = other.iconSize
        case .iconColor: iconColor = other.iconColor
        case .shadow: shadow = other.shadow
        case .transform: transform = other.transform
        default: break
        }
    }

    /// Blend two resolved styles. `progress` is asked per property name, because transitions
    /// are per property with their own durations and easings.
    public static func interpolated(from a: Style, to b: Style,
                                    progress: (StyleProperty) -> Double) -> Style {
        var out = b
        for property in StyleProperty.animatable {
            out.blend(property, from: a, t: min(1, max(0, progress(property))))
        }
        return out
    }

    /// The uniform case, for tests and for one-property animations.
    public static func interpolated(from a: Style, to b: Style, t: Double) -> Style {
        interpolated(from: a, to: b, progress: { _ in t })
    }

    /// Properties whose values differ, so an animator knows what to start.
    public func changedProperties(against other: Style) -> Set<StyleProperty> {
        Set(StyleProperty.animatable.filter { differs(in: $0, from: other) })
    }
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

func lerp(_ a: Insets, _ b: Insets, _ t: Double) -> Insets {
    Insets(top: lerp(a.top, b.top, t), right: lerp(a.right, b.right, t),
           bottom: lerp(a.bottom, b.bottom, t), left: lerp(a.left, b.left, t))
}

func lerp(_ a: Corners, _ b: Corners, _ t: Double) -> Corners {
    Corners(topLeft: lerp(a.topLeft, b.topLeft, t), topRight: lerp(a.topRight, b.topRight, t),
            bottomRight: lerp(a.bottomRight, b.bottomRight, t),
            bottomLeft: lerp(a.bottomLeft, b.bottomLeft, t))
}

/// Corner shapes move through convexity, K / (1 + |K|), which is finite at square and notch
/// and puts round, squircle and bevel at even-feeling steps.
func lerp(_ a: CornerShapes, _ b: CornerShapes, _ t: Double) -> CornerShapes {
    func convexity(_ k: Double) -> Double { k.isInfinite ? (k > 0 ? 1 : -1) : k / (1 + abs(k)) }
    func shape(_ c: Double) -> Double { abs(c) >= 1 ? (c > 0 ? .infinity : -.infinity) : c / (1 - abs(c)) }
    func mix(_ a: Double, _ b: Double) -> Double { shape(lerp(convexity(a), convexity(b), t)) }
    return CornerShapes(topLeft: mix(a.topLeft, b.topLeft), topRight: mix(a.topRight, b.topRight),
                        bottomRight: mix(a.bottomRight, b.bottomRight),
                        bottomLeft: mix(a.bottomLeft, b.bottomLeft))
}

extension Color {
    /// Symbolic colours cannot be blended here, so the blend itself is symbolic too and the
    /// painter resolves both ends before mixing.
    public static func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        if t <= 0 { return a }
        if t >= 1 || a == b { return b }
        if case .rgba(let x) = a, case .rgba(let y) = b {
            return .rgba(RGBA(r: lerp(x.r, y.r, t), g: lerp(x.g, y.g, t),
                              b: lerp(x.b, y.b, t), a: lerp(x.a, y.a, t)))
        }
        return .mix(a, b, t)
    }
}

extension Background {
    static func blend(_ a: Background, _ b: Background, _ t: Double) -> Background {
        if t <= 0 { return a }
        if t >= 1 || a == b { return b }
        switch (a, b) {
        case (.color(let x), .color(let y)):
            return .color(Color.blend(x, y, t))
        case (.none, .color(let y)):
            return .color(Color.blend(.clear, y, t))
        case (.color(let x), .none):
            return .color(Color.blend(x, .clear, t))
        case (.backdrop, .backdrop):
            // Every distinct blur and saturation is a Core Image pass and a cached image, so an
            // eased one would fill the cache a frame at a time. They snap at the midpoint
            // (PLAN.md D10), as backgrounds of different kinds do.
            return t < 0.5 ? a : b
        case (.gradient(let x), .gradient(let y)) where x.stops.count == y.stops.count:
            var out = y
            out.angle = lerp(x.angle, y.angle, t)
            out.stops = zip(x.stops, y.stops).map { from, to in
                GradientStop(color: Color.blend(from.color, to.color, t),
                             location: blendOptional(from.location, to.location, t))
            }
            return .gradient(out)
        default:
            return t < 0.5 ? a : b
        }
    }

    private static func blendOptional(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        guard let a, let b else { return t < 0.5 ? a : b }
        return lerp(a, b, t)
    }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
