import AppKit

/// How a rounded rectangle becomes layer properties (PLAN.md D7). Core Animation takes one
/// corner radius per layer and a set of corners to apply it to, which covers every radius
/// but differing non-zero ones; those need a shape.
enum Outline: Equatable {
    case square
    /// One radius, on the corners named.
    case rounded(CGFloat, CACornerMask)
    /// Radii that differ: a path, already clamped to the rectangle.
    case path(Corners)

    init(_ corners: Corners, in rect: CGRect) {
        let limit = max(0, min(rect.width, rect.height) / 2)
        func clamp(_ value: Double) -> Double { min(max(0, value), limit) }
        let clamped = Corners(topLeft: clamp(corners.topLeft), topRight: clamp(corners.topRight),
                              bottomRight: clamp(corners.bottomRight), bottomLeft: clamp(corners.bottomLeft))
        let radii = [clamped.topLeft, clamped.topRight, clamped.bottomRight, clamped.bottomLeft]
        let nonZero = Set(radii.filter { $0 > 0 })
        guard let radius = nonZero.first else {
            self = .square
            return
        }
        guard nonZero.count == 1 else {
            self = .path(clamped)
            return
        }
        // y runs up, so CSS's top is the layer's max y.
        var mask: CACornerMask = []
        if clamped.topLeft > 0 { mask.insert(.layerMinXMaxYCorner) }
        if clamped.topRight > 0 { mask.insert(.layerMaxXMaxYCorner) }
        if clamped.bottomRight > 0 { mask.insert(.layerMaxXMinYCorner) }
        if clamped.bottomLeft > 0 { mask.insert(.layerMinXMinYCorner) }
        self = .rounded(radius, mask)
    }

    /// Round `layer`, whose bounds are `rect`, to this outline: its own corner radius, or a
    /// shape mask kept in `mask`.
    @MainActor
    func apply(to layer: CALayer, in rect: CGRect, mask: inout CAShapeLayer?,
               factory: inout LayerFactory) {
        switch self {
        case .square:
            assign(layer, \.cornerRadius, 0)
            mask = nil
        case .rounded(let radius, let corners):
            assign(layer, \.cornerRadius, radius)
            assign(layer, \.maskedCorners, corners)
            mask = nil
        case .path(let corners):
            assign(layer, \.cornerRadius, 0)
            let shape = mask ?? factory.make(CAShapeLayer.self)
            shape.place(rect)
            let path = RoundedRect.path(in: rect, corners: corners)
            if shape.path != path { shape.path = path }
            mask = shape
        }
        if layer.mask !== mask { layer.mask = mask }
    }
}

/// A `Style`'s box as layers (PLAN.md D7), each made only when the style needs it:
///
/// - **shadow**: `shadowPath` and the shadow properties, no contents, masked to outside the
///   shape so a translucent bubble does not show its own shadow through itself, as CSS draws
///   an outer shadow;
/// - **fill**: a colour, a `CAGradientLayer`, or the backdrop through `contentsRect`;
/// - **border**: the fill's own border when one radius covers the corners, otherwise a
///   stroked shape.
@MainActor
final class Chrome {
    private(set) var shadow: CALayer?
    private var shadowMask: CAShapeLayer?
    private(set) var fill: CALayer?
    private var fillMask: CAShapeLayer?
    private(set) var border: CAShapeLayer?
    /// The desktop's own window shadows, when this chrome is showing the desktop.
    private var plane: ShadowPlane?

    /// Bottom first; the owner puts them under whatever the chrome is for.
    var layers: [CALayer] { [shadow, fill, border].compactMap { $0 } }

    /// Including the plane's, which are sublayers of the fill rather than siblings.
    var layerCount: Int { layers.count + (plane?.layers.count ?? 0) }

    struct Context {
        /// With `currentColor` already the bar's colour.
        var resolver: ColorResolver
        var backdrop: BackdropImage
        /// The shadows the windows behind the bar cast onto that photograph.
        var shadows: ShadowField = .empty
        /// The backdrop is one image of the whole bar, and a fill shows its own slice of it.
        var barSize: CGSize
    }

    func apply(_ style: Style, in rect: CGRect, shadows: Bool, borders: Bool,
               context: Context, factory: inout LayerFactory) {
        guard rect.width > 0, rect.height > 0 else {
            shadow = nil
            fill = nil
            border = nil
            plane = nil
            return
        }
        let colors = context.resolver.with(current: context.resolver.resolve(style.color))
        let outline = Outline(style.borderRadius, in: rect)
        applyShadow(shadows ? style.shadow : nil, rect: rect, corners: style.borderRadius,
                    colors: colors, factory: &factory)

        var strokeWidth = 0.0
        var strokeColor: CGColor?
        if borders, style.borderWidth > 0, style.borderColor != .none {
            let rgba = colors.resolve(style.borderColor)
            if rgba.a > 0.001 {
                strokeWidth = style.borderWidth
                strokeColor = rgba.cgColor
            }
        }
        let strokedByFill: Bool
        if case .path = outline { strokedByFill = false } else { strokedByFill = true }

        applyFill(style.background, rect: rect, outline: outline, colors: colors,
                  border: strokedByFill ? (strokeWidth, strokeColor) : (0, nil),
                  context: context, factory: &factory)

        if !strokedByFill, let strokeColor, case .path(let corners) = outline {
            let layer = border ?? factory.make(CAShapeLayer.self)
            layer.place(rect)
            let path = RoundedRect.path(in: rect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2),
                                        corners: corners)
            if layer.path != path { layer.path = path }
            if layer.fillColor != nil { layer.fillColor = nil }
            if layer.strokeColor != strokeColor { layer.strokeColor = strokeColor }
            assign(layer, \.lineWidth, strokeWidth)
            border = layer
        } else {
            border = nil
        }
    }

    private func applyShadow(_ spec: Shadow?, rect: CGRect, corners: Corners,
                             colors: ColorResolver, factory: inout LayerFactory) {
        guard let spec else {
            shadow = nil
            shadowMask = nil
            return
        }
        let rgba = colors.resolve(spec.color)
        let layer = shadow ?? factory.make()
        layer.place(rect)
        let shape = RoundedRect.path(in: rect, corners: corners)
        if layer.shadowPath != shape { layer.shadowPath = shape }
        if layer.shadowColor != rgba.cgColor { layer.shadowColor = rgba.cgColor }
        assign(layer, \.shadowOpacity, 1)
        // Fitted against CoreGraphics: a layer's radius is half a CSS blur.
        assign(layer, \.shadowRadius, spec.blur / 2)
        assign(layer, \.shadowOffset, CGSize(width: spec.dx, height: spec.dy))

        // Everything but the shape itself, out as far as the blur can reach.
        let reach = abs(spec.dx) + abs(spec.dy) + spec.blur * 2 + 2
        let mask = shadowMask ?? factory.make(CAShapeLayer.self)
        let outer = rect.insetBy(dx: -reach, dy: -reach)
        mask.place(outer)
        let cutout = CGMutablePath()
        cutout.addRect(outer)
        cutout.addPath(shape)
        if mask.path != cutout { mask.path = cutout }
        if mask.fillRule != .evenOdd { mask.fillRule = .evenOdd }
        if layer.mask !== mask { layer.mask = mask }
        shadow = layer
        shadowMask = mask
    }

    private func applyFill(_ background: Background, rect: CGRect, outline: Outline,
                           colors: ColorResolver, border: (width: Double, color: CGColor?),
                           context: Context, factory: inout LayerFactory) {
        enum Kind { case none, plain, gradient }
        var kind = Kind.none
        var color: CGColor?
        var image: CGImage?
        var gradient: Gradient?
        switch background {
        case .none:
            break
        case .color(let value):
            let rgba = colors.resolve(value)
            if rgba.a > 0.001 {
                kind = .plain
                color = rgba.cgColor
            }
        case .gradient(let value):
            kind = .gradient
            gradient = value
        case .backdrop(let spec):
            image = context.backdrop.image(blur: spec.blur, saturate: spec.saturate)
            if image != nil { kind = .plain }
        }
        if kind == .none, border.color != nil { kind = .plain }

        let layer: CALayer
        switch kind {
        case .none:
            fill = nil
            fillMask = nil
            plane = nil
            return
        case .plain:
            if let fill, type(of: fill) == CALayer.self {
                layer = fill
            } else {
                layer = factory.make()
                fillMask = nil
            }
        case .gradient:
            if let fill = fill as? CAGradientLayer {
                layer = fill
            } else {
                layer = factory.make(CAGradientLayer.self)
                fillMask = nil
            }
        }
        layer.place(rect)
        assign(layer, \.masksToBounds, true)
        outline.apply(to: layer, in: rect, mask: &fillMask, factory: &factory)
        layer.updateColor(color)
        layer.updateContents(image)
        if image != nil, context.barSize.width > 0, context.barSize.height > 0 {
            // `contentsRect` is y-up like the layer, so the slice is the rectangle over the bar.
            assign(layer, \.contentsRect, CGRect(x: rect.minX / context.barSize.width,
                                                 y: rect.minY / context.barSize.height,
                                                 width: rect.width / context.barSize.width,
                                                 height: rect.height / context.barSize.height))
        }
        if let gradient, let gradientLayer = layer as? CAGradientLayer {
            Chrome.apply(gradient, to: gradientLayer, in: rect, colors: colors)
        }
        assign(layer, \.borderWidth, border.width)
        if layer.borderColor != border.color { layer.borderColor = border.color }
        applyPlane(showsDesktop: image != nil, on: layer, context: context, factory: &factory)
        fill = layer
    }

    /// The desktop's window shadows belong to whatever is showing the desktop, so they hang
    /// under the backdrop fill itself: the bar's own and a `background: backdrop` bubble's both
    /// get them with no special case, and the fill already clips to the outline and masks its
    /// bounds, so each one is cut to its own shape for free.
    ///
    /// A fill that is a colour or a gradient is not the desktop and takes no shadow: there is
    /// nothing showing through it for one to fall on, and so no seam to carry across.
    private func applyPlane(showsDesktop: Bool, on layer: CALayer, context: Context,
                            factory: inout LayerFactory) {
        guard showsDesktop, !context.shadows.isEmpty else {
            guard plane != nil else { return }
            plane = nil
            layer.updateSublayers([])
            return
        }
        let plane = self.plane ?? ShadowPlane()
        plane.apply(context.shadows, factory: &factory)
        layer.updateSublayers(plane.layers)
        self.plane = plane
    }

    /// CSS's linear gradient: the angle points from the start (0deg up, 90deg right), and the
    /// gradient line is as long as the rectangle is in that direction, so its first and last
    /// colours land exactly in opposite corners.
    static func apply(_ gradient: Gradient, to layer: CAGradientLayer, in rect: CGRect,
                      colors: ColorResolver) {
        let cgColors = gradient.stops.map { colors.resolve($0.color).cgColor }
        let locations = gradient.stops.enumerated().map { index, stop in
            NSNumber(value: stop.location ?? Double(index) / Double(max(1, gradient.stops.count - 1)))
        }
        let current = (layer.colors as? [CGColor]) ?? []
        if current != cgColors { layer.colors = cgColors }
        if (layer.locations ?? []) != locations { layer.locations = locations }

        let radians = gradient.angle * .pi / 180
        let direction = CGPoint(x: sin(radians), y: cos(radians))
        let length = abs(rect.width * direction.x) + abs(rect.height * direction.y)
        // In the unit square of the layer, where y 0 is the bottom.
        let half = CGPoint(x: rect.width > 0 ? direction.x * length / 2 / rect.width : 0,
                           y: rect.height > 0 ? direction.y * length / 2 / rect.height : 0)
        assign(layer, \.startPoint, CGPoint(x: 0.5 - half.x, y: 0.5 - half.y))
        assign(layer, \.endPoint, CGPoint(x: 0.5 + half.x, y: 0.5 + half.y))
    }
}
