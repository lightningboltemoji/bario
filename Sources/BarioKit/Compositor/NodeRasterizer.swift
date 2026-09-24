import AppKit
import CoreText

/// Draws one leaf into an image with CoreGraphics, CoreText and SF Symbols. It draws in bar
/// coordinates, into an image that covers only the rectangle asked for, at the display's
/// scale. Backgrounds and meters are layers, and never come here. DESIGN.md §10.
@MainActor
struct NodeRasterizer {
    /// `currentColor` at the top of the tree is the bar's own colour.
    var resolver: ColorResolver
    var scale: CGFloat

    /// An image of `rect`, a bar-coordinate rectangle, drawn by `draw` in bar coordinates. Its
    /// pixel size is the rectangle's rounded up, so the layer showing it is `rect` with its
    /// size rounded up the same way.
    func image(covering rect: CGRect, _ draw: (CGContext) -> Void) -> CGImage? {
        let size = NodeRasterizer.pixelSize(of: rect.size, scale: scale)
        guard let ctx = CGContext(data: nil, width: size.width, height: size.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.interpolationQuality = .high

        // AppKit's drawing appearance has to be current for `system()` colours and for symbol
        // images to come out right, and a current graphics context for symbols to be chosen
        // at this scale.
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        if let appearance = NSAppearance(named: resolver.dark ? .darkAqua : .aqua) {
            appearance.performAsCurrentDrawingAppearance { draw(ctx) }
        } else {
            draw(ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func pixelSize(of size: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (max(1, Int((size.width * scale - 0.001).rounded(.up))),
         max(1, Int((size.height * scale - 0.001).rounded(.up))))
    }

    /// The size of the layer that shows an image of a rectangle this size.
    static func layerSize(of size: CGSize, scale: CGFloat) -> CGSize {
        let pixels = pixelSize(of: size, scale: scale)
        return CGSize(width: CGFloat(pixels.width) / scale, height: CGFloat(pixels.height) / scale)
    }

    /// `contrast` resolved on the item wins for everything inside it.
    static func contrasted(_ style: Style, inheriting parent: Style) -> Style {
        var style = style
        if parent.contrast != .none { style.color = parent.color }
        return style
    }

    // MARK: - Leaves

    /// Text or a monochrome symbol as coverage alone (PLAN.md D6): what a tint shows through.
    /// Text is drawn in the ink its colour calls for, because font smoothing draws light ink
    /// heavier than dark.
    func drawCoverage(_ node: SceneNode, style: Style, in ctx: CGContext) {
        let colors = resolver.with(current: resolver.resolve(style.color))
        switch node.kind {
        case .text(let text):
            drawText(text, in: node.frame, style: style, color: Ink(colors.resolve(style.color)).color,
                     ctx: ctx)
        case .icon(let icon):
            drawIcon(icon, in: node.frame, style: style, tint: RGBA(r: 1, g: 1, b: 1), ctx: ctx)
        default:
            break
        }
    }

    /// A leaf with its colours.
    func drawLeaf(_ node: SceneNode, style: Style, in ctx: CGContext) {
        let colors = resolver.with(current: resolver.resolve(style.color))
        switch node.kind {
        case .text(let text):
            drawText(text, in: node.frame, style: style, color: colors.resolve(style.color), ctx: ctx)
        case .icon(let icon):
            drawIcon(icon, in: node.frame, style: style, tint: colors.resolve(style.effectiveIconColor),
                     ctx: ctx)
        case .graph(let graph):
            drawGraph(graph, in: node.frame, style: style, colors: colors, ctx: ctx)
        case .canvas, .custom:
            if let list = node.displayList {
                CanvasPainter(style: style, resolver: resolver).paint(list, in: node.frame, ctx: ctx)
            }
        case .row, .column, .spacer, .meter, .raster:
            break
        }
    }

    func drawText(_ text: String, in frame: CGRect, style: Style, color: RGBA, ctx: CGContext) {
        let transformed = style.textTransform.apply(to: text)
        guard !transformed.isEmpty else { return }
        let font = CoreTextMetrics.font(for: style.font)
        let line = CoreTextMetrics.line(transformed, font: font, letterSpacing: style.letterSpacing,
                                        color: color.nsColor)
        // Centre the ascender/descender box on the frame, which is what looks level next to
        // an icon of the same point size.
        let baseline = frame.midY - (font.ascender + font.descender) / 2
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: frame.minX, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    func drawIcon(_ icon: IconSpec, in frame: CGRect, style: Style, tint: RGBA, ctx: CGContext) {
        guard var image = CoreTextMetrics.image(for: icon, style: style) else { return }
        if style.iconRendering != .monochrome, case .symbol = icon {
            let color = tint.nsColor
            let configuration: NSImage.SymbolConfiguration
            switch style.iconRendering {
            case .hierarchical: configuration = .init(hierarchicalColor: color)
            case .palette: configuration = .init(paletteColors: [color, color.withAlphaComponent(0.5)])
            case .multicolor: configuration = .preferringMulticolor()
            case .monochrome: configuration = .preferringMonochrome()
            }
            image = image.withSymbolConfiguration(configuration) ?? image
        }
        let rect: CGRect
        if case .symbol = icon {
            rect = CoreTextMetrics.symbolRect(image, in: frame, style: style)
        } else {
            rect = frame
        }
        var box = rect
        guard let cgImage = image.cgImage(forProposedRect: &box, context: NSGraphicsContext.current,
                                          hints: nil) else { return }
        if style.iconRendering == .monochrome {
            // Tint by clipping to the symbol's own alpha: exact, and it works for file icons
            // that happen to be masks too.
            ctx.saveGState()
            ctx.clip(to: rect, mask: cgImage)
            ctx.setFillColor(tint.cgColor)
            ctx.fill(rect)
            ctx.restoreGState()
        } else {
            ctx.draw(cgImage, in: rect)
        }
    }

    /// Oldest value at the left, one step apart, scaled so the top of the frame is the graph's
    /// ceiling. A gap (nil) breaks a line or an area and leaves a bar out. A smooth graph's step
    /// leaves its newest value one step past the right edge of `frame`, where the compositor's
    /// strip keeps it until the slide brings it in.
    func drawGraph(_ graph: Graph, in frame: CGRect, style: Style, colors: ColorResolver,
                   ctx: CGContext) {
        let values = graph.values
        let ceiling = graph.ceiling
        let step = NodeRasterizer.graphStep(graph, width: frame.width)
        guard ceiling > 0, step > 0 else { return }
        func height(_ value: Double) -> CGFloat { frame.height * CGFloat(min(max(value / ceiling, 0), 1)) }
        let color = colors.resolve(style.fill).cgColor

        if graph.kind == .bars {
            // A hairline between bars once there is room for one.
            let gap: CGFloat = step >= 3 ? 1 : 0
            ctx.setFillColor(color)
            for (index, value) in values.enumerated() {
                guard let value, height(value) > 0 else { continue }
                ctx.fill(CGRect(x: frame.minX + CGFloat(index) * step + gap / 2, y: frame.minY,
                                width: step - gap, height: height(value)))
            }
            return
        }

        // Runs of consecutive values, each a line or an area of its own.
        var runs: [[CGPoint]] = [[]]
        for (index, value) in values.enumerated() {
            guard let value else {
                if !runs[runs.count - 1].isEmpty { runs.append([]) }
                continue
            }
            runs[runs.count - 1].append(CGPoint(x: frame.minX + CGFloat(index) * step,
                                                y: frame.minY + height(value)))
        }
        let path = CGMutablePath()
        for run in runs where run.count > 1 {
            if graph.kind == .area {
                // Not `addLines(between:)`, which would start a subpath of its own.
                path.move(to: CGPoint(x: run[0].x, y: frame.minY))
                for point in run { path.addLine(to: point) }
                path.addLine(to: CGPoint(x: run[run.count - 1].x, y: frame.minY))
                path.closeSubpath()
            } else {
                path.addLines(between: run)
            }
        }
        ctx.addPath(path)
        if graph.kind == .area {
            ctx.setFillColor(color)
            ctx.fillPath()
            return
        }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(style.strokeWidth)
        ctx.setLineJoin(.round)
        switch style.lineCap {
        case .butt: ctx.setLineCap(.butt)
        case .round: ctx.setLineCap(.round)
        case .square: ctx.setLineCap(.square)
        }
        ctx.strokePath()
    }

    /// The distance between two values. A line or an area puts its first and last value on the
    /// edges; bars are a step wide each; and a smooth graph shows one fewer, since its newest
    /// sits past the edge.
    static func graphStep(_ graph: Graph, width: CGFloat) -> CGFloat {
        var spans = graph.kind == .bars ? graph.values.count : graph.values.count - 1
        if graph.scroll == .smooth { spans -= 1 }
        return spans > 0 ? width / CGFloat(spans) : 0
    }
}
