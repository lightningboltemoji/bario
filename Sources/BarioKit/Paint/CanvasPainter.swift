import AppKit
import CoreText

/// Paints a display list into the node's frame. Theming reaches it: every colour is a CSS
/// colour string resolved against that node's own style, so `currentColor` and `var(--x)`
/// mean what they say inside a drawing bario never wrote. DESIGN.md §9.
public struct CanvasPainter {
    public var style: Style
    public var resolver: ColorResolver

    public init(style: Style, resolver: ColorResolver) {
        self.style = style
        self.resolver = resolver.with(current: resolver.resolve(style.color))
    }

    public func paint(_ list: DisplayList, in frame: CGRect, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // The display list's origin is the node's top left with y running down; the painter
        // draws with y running up. Flip once here, and counter-flip the text matrix below.
        ctx.translateBy(x: frame.minX, y: frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: CGRect(origin: .zero, size: frame.size))
        draw(list, ctx: ctx)
    }

    private func draw(_ list: DisplayList, ctx: CGContext) {
        for op in list.ops {
            switch op {
            case .fill(let paint, let path):
                ctx.addPath(path.cgPath())
                ctx.setFillColor(color(paint.color))
                ctx.fillPath()

            case .stroke(let paint, let path):
                ctx.addPath(path.cgPath())
                ctx.setStrokeColor(color(paint.color))
                ctx.setLineWidth(paint.width ?? style.strokeWidth)
                switch paint.cap ?? style.lineCap {
                case .butt: ctx.setLineCap(.butt)
                case .round: ctx.setLineCap(.round)
                case .square: ctx.setLineCap(.square)
                }
                switch paint.join {
                case "bevel": ctx.setLineJoin(.bevel)
                case "miter": ctx.setLineJoin(.miter)
                default: ctx.setLineJoin(.round)
                }
                if let dash = paint.dash, !dash.isEmpty {
                    ctx.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) })
                } else {
                    ctx.setLineDash(phase: 0, lengths: [])
                }
                ctx.strokePath()

            case .text(let op):
                draw(op, ctx: ctx)

            case .image(let op):
                draw(op, ctx: ctx)

            case .clip(let path):
                ctx.addPath(path.cgPath())
                ctx.clip()

            case .transform(let transform):
                ctx.concatenate(transform)

            case .opacity(let alpha):
                ctx.setAlpha(min(1, max(0, alpha)))

            case .group(let nested):
                ctx.saveGState()
                draw(nested, ctx: ctx)
                ctx.restoreGState()
            }
        }
    }

    private func draw(_ op: CanvasText, ctx: CGContext) {
        let spec = op.font.flatMap { font(from: $0) } ?? style.font
        let font = CoreTextMetrics.font(for: spec)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color(op.color ?? "currentColor")) ?? .labelColor,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: op.text, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        var x = op.at.x
        switch op.align {
        case .center: x -= width / 2
        case .end: x -= width
        default: break
        }
        var y = op.at.y
        switch op.valign {
        case "top": y += ascent
        case "bottom": y -= descent
        case "baseline": break
        default: y += (ascent - descent) / 2      // middle
        }

        ctx.saveGState()
        // The CTM is flipped, so the glyphs need flipping back or they draw mirrored.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func draw(_ op: CanvasImage, ctx: CGContext) {
        guard let image = CoreTextMetrics.image(for: op.icon, style: style) else { return }
        var box = op.rect
        guard let cgImage = image.cgImage(forProposedRect: &box, context: nil, hints: nil) else { return }
        ctx.saveGState()
        // Undo the flip for this one draw so the image is not upside down.
        ctx.translateBy(x: 0, y: op.rect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -op.rect.midY)
        if style.iconRendering == .monochrome, case .symbol = op.icon {
            ctx.clip(to: op.rect, mask: cgImage)
            ctx.setFillColor(resolver.resolve(style.effectiveIconColor).cgColor)
            ctx.fill(op.rect)
        } else {
            ctx.draw(cgImage, in: op.rect)
        }
        ctx.restoreGState()
    }

    // MARK: - Theming

    /// A CSS colour string, resolved against this node's style: `currentColor`, `var(--x)`,
    /// `accent`, `system(labelColor)`, or any literal.
    public func color(_ text: String) -> CGColor {
        guard let parsed = CanvasPainter.parseColor(text, custom: style.custom) else {
            // A colour we cannot read is a visible mistake, not an invisible one.
            return CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        }
        return resolver.cgColor(parsed)
    }

    public static func parseColor(_ text: String, custom: [String: [CSSComponent]]) -> Color? {
        guard let components = (try? Stylesheet.parseDeclarations("color: \(text)"))?.first?.value
        else { return nil }
        let resolved = (try? Cascade(stylesheet: Stylesheet())
            .resolve(components, in: custom, at: .start)) ?? components
        return try? CSSValue.color(resolved, at: .start)
    }

    /// The CSS `font` shorthand, over this node's font as a base.
    public func font(from text: String) -> FontSpec? {
        guard let components = (try? Stylesheet.parseDeclarations("font: \(text)"))?.first?.value
        else { return nil }
        let resolved = (try? Cascade(stylesheet: Stylesheet())
            .resolve(components, in: style.custom, at: .start)) ?? components
        return try? CSSValue.font(resolved, base: style.font, at: .start)
    }
}
