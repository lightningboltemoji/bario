import CoreGraphics

/// The layout stage (DESIGN.md §6, §10): measure a styled bar, split it at the notch, drop
/// what does not fit, then one flex pass per row. Renderers measure here; they draw at commit,
/// where a drawing is kept per node and asked for again only when its inputs change.
public struct BarLayout: Sendable {
    public var metrics: any Metrics
    /// Node types registered by renderer modules (DESIGN.md §9.2), which measure here.
    public var renderers: RendererHost?
    /// `raster` nodes' pixels, read when a bar is laid out.
    public var rasters: RasterCache
    /// Renderers get colours already resolved, so they need no colour engine of their own.
    public var resolver: ColorResolver

    public init(metrics: any Metrics = CoreTextMetrics(), renderers: RendererHost? = nil,
                rasters: RasterCache = RasterCache(), resolver: ColorResolver = ColorResolver()) {
        self.metrics = metrics
        self.renderers = renderers
        self.rasters = rasters
        self.resolver = resolver
    }

    public func layout(_ bar: StyledBar, on display: DisplayInfo) -> Scene {
        let config = bar.config
        let height = config.height ?? Double(display.stripHeight)
        let bounds = CGRect(x: 0, y: 0, width: display.frame.width, height: height)
        var scene = Scene(display: display, bounds: bounds, style: bar.style,
                          notch: config.notch == .avoid ? display.notchInStrip : nil,
                          hole: config.hole)

        let content = bar.style.padding.inset(bounds)
        let gap = bar.style.gap
        // Measure everything first: the split, the drops and the flex pass all need naturals.
        let measured = bar.items.map(measure)

        var rows: [(rect: CGRect, items: [Measured])] = []
        if let notch = scene.notch, notch.width > 1 {
            let left = CGRect(x: content.minX, y: content.minY,
                              width: max(0, notch.minX - content.minX), height: content.height)
            let right = CGRect(x: notch.maxX, y: content.minY,
                               width: max(0, content.maxX - notch.maxX), height: content.height)
            let split = splitPoint(measured, markerAt: bar.notchMarker, notch: notch,
                                   in: content, gap: gap)
            var rightItems = Array(measured[split.index...])
            // A spacer that straddles the whole notch becomes a spacer on each side, which is
            // what keeps `[a spacer b]` pinned to both edges.
            if let spacer = split.straddlingSpacer { rightItems.insert(spacer, at: 0) }
            rows = [(left, Array(measured[..<split.index])), (right, rightItems)]
        } else {
            rows = [(content, measured)]
        }

        for (rect, items) in rows {
            let (kept, dropped) = fit(items, in: rect.width, gap: gap)
            scene.hidden.append(contentsOf: dropped.map { overflowed($0, styler: bar.styler) })
            scene.rows.append(SceneRow(frame: rect,
                                       items: place(kept, in: rect, gap: gap, align: config.align)))
        }
        return scene
    }

    // MARK: - Measuring

    struct Measured {
        var item: StyledItem
        var node: SceneNode?
        var children: [Measured]
        var natural: CGSize

        var isSpacer: Bool { item.isSpacer }
        var style: Style { item.style }
        var config: ItemConfig { item.config }
    }

    /// An item's natural size is its content plus padding plus border, clamped by `width`,
    /// `min-width` and `max-width`. A spacer has no content and no box, only the clamps.
    private func measure(_ item: StyledItem) -> Measured {
        var measured = Measured(item: item, node: nil, children: [], natural: .zero)
        let style = item.style
        switch item.config.kind {
        case .spacer, .notch:
            break
        case .group:
            let inner = item.children.map(measure)
            let gap = item.style.gap
            measured.children = inner
            measured.natural = CGSize(
                width: inner.reduce(0) { $0 + $1.natural.width } + gap * Double(max(0, inner.count - 1)),
                height: inner.map(\.natural.height).max() ?? 0)
        case .module:
            if let content = item.content {
                let node = measureNode(content)
                measured.node = node
                // At least a line tall, as a CSS line box is, so an icon-only item stands as
                // tall as its text neighbours. The content keeps its own size, centred.
                measured.natural = CGSize(width: node.frame.width,
                                          height: max(node.frame.height, metrics.lineHeight(style)))
            }
        }

        if !item.isSpacer {
            measured.natural.width += style.padding.horizontal + style.borderWidth * 2
            measured.natural.height += style.padding.vertical + style.borderWidth * 2
        }
        if let width = style.width { measured.natural.width = width }
        if let min = style.minWidth { measured.natural.width = max(measured.natural.width, min) }
        if let max = style.maxWidth { measured.natural.width = min(measured.natural.width, max) }
        return measured
    }

    private func measureNode(_ styled: SceneNode) -> SceneNode {
        var node = styled
        let style = node.style
        var size: CGSize

        switch node.kind {
        case .text(let text):
            size = metrics.textSize(text, style: style)
        case .icon(let icon):
            size = metrics.iconSize(icon, style: style)
        case .meter(let meter):
            size = CGSize(width: meter.width ?? 24, height: max(3, style.strokeWidth * 2))
        case .graph(let graph):
            size = CGSize(width: graph.width ?? 40, height: metrics.lineHeight(style))
        case .spacer:
            size = .zero
        case .canvas(let canvas):
            size = CGSize(width: canvas.width ?? 0, height: canvas.height ?? metrics.lineHeight(style))
            let list = DisplayList.parse(canvas.ops)
            for problem in list.problems { warn("canvas \(node.id ?? node.kind.typeName): \(problem)") }
            node.displayList = list
        case .raster(let raster):
            size = CGSize(width: raster.width, height: raster.height ?? metrics.lineHeight(style))
            node.raster = rasters.image(for: raster.source, width: size.width, height: size.height)
        case .custom(let type, let payload):
            // A renderer's `draw` is also how it measures: with `measure: true` here for the
            // natural width, and for the drawing at commit.
            if let renderers, renderers.has(type) {
                size = renderers.measure(type, payload: payload, style: style, resolver: resolver,
                                         height: metrics.lineHeight(style))
                    ?? CGSize(width: 0, height: metrics.lineHeight(style))
            } else {
                // An unregistered node type takes no room rather than breaking the bar.
                size = .zero
            }
        case .row(let container), .column(let container):
            node.children = node.children.map(measureNode)
            let gap = container.gap ?? style.gap
            let spacing = gap * Double(max(0, node.children.count - 1))
            if case .row = node.kind {
                size = CGSize(width: node.children.reduce(0) { $0 + $1.frame.width } + spacing,
                              height: node.children.map(\.frame.height).max() ?? 0)
            } else {
                size = CGSize(width: node.children.map(\.frame.width).max() ?? 0,
                              height: node.children.reduce(0) { $0 + $1.frame.height } + spacing)
            }
        }

        size.width += style.padding.horizontal
        size.height += style.padding.vertical
        node.frame = CGRect(origin: .zero, size: size)
        return node
    }

    // MARK: - The notch split

    /// Where the bar breaks in two. The split is decided from where items *would* land in a
    /// single flex pass over the whole width, not from their natural widths: on a menu bar
    /// the naturals all fit to the left of the notch, and it is the spacers that put anything
    /// near it.
    private func splitPoint(_ items: [Measured], markerAt marker: Int?, notch: CGRect,
                            in content: CGRect, gap: Double) -> (index: Int, straddlingSpacer: Measured?) {
        // An explicit marker is the predictable option, and the docs recommend it.
        if let marker { return (min(marker, items.count), nil) }

        let widths = Flex.solve(items.map(flexItem), available: content.width, gap: gap)
        var frames: [ClosedRange<Double>] = []
        var x = content.minX
        for width in widths {
            frames.append(x...(x + width))
            x += width + gap
        }

        // The first item that is not wholly left of the notch starts the right sub-row.
        // Spacers do not count: they are the space, not the thing being placed.
        guard let index = items.indices.first(where: { !items[$0].isSpacer && frames[$0].upperBound > notch.minX })
        else {
            return (items.count, nil)
        }

        var straddling: Measured?
        if index > 0, items[index - 1].isSpacer,
           frames[index - 1].lowerBound < notch.minX, frames[index - 1].upperBound > notch.maxX {
            straddling = items[index - 1]
        }
        return (index, straddling)
    }

    private func flexItem(_ measured: Measured) -> Flex.Item {
        Flex.Item(natural: measured.natural.width,
                  min: measured.style.minWidth ?? measured.natural.width,
                  max: measured.style.maxWidth ?? .infinity,
                  grow: measured.config.sizing.grow,
                  shrink: measured.config.sizing.shrink)
    }

    // MARK: - Overflow

    /// Drop the lowest priority until the naturals fit. Ties break right-to-left, so the
    /// rightmost of equal priority goes first.
    private func fit(_ items: [Measured], in available: Double, gap: Double) -> (kept: [Measured], dropped: [Measured]) {
        var kept = items
        var dropped: [Measured] = []

        func total(_ list: [Measured]) -> Double {
            list.reduce(0) { $0 + $1.natural.width } + gap * Double(max(0, list.count - 1))
        }

        while total(kept) > available + 0.01 {
            let candidates = kept.indices.filter { !kept[$0].isSpacer }
            guard let victim = candidates.min(by: { a, b in
                let pa = kept[a].config.priority, pb = kept[b].config.priority
                return pa != pb ? pa < pb : a > b
            }) else { break }
            dropped.append(kept.remove(at: victim))
        }
        return (kept, dropped)
    }

    private func overflowed(_ measured: Measured, styler: Styler) -> SceneItem {
        sceneItem(Measured(item: styler.restyle(measured.item, adding: .overflow),
                           node: measured.node, children: measured.children,
                           natural: measured.natural))
    }

    // MARK: - Placement

    private func place(_ items: [Measured], in rect: CGRect, gap: Double, align: Align) -> [SceneItem] {
        guard !items.isEmpty else { return [] }
        let widths = Flex.solve(items.map(flexItem), available: rect.width, gap: gap)

        var x = rect.minX
        var out: [SceneItem] = []
        for (index, measured) in items.enumerated() {
            let width = widths[index]
            let height = align == .stretch ? rect.height : min(measured.natural.height, rect.height)
            let y: Double
            switch align {
            case .start: y = rect.maxY - height
            case .end: y = rect.minY
            case .center, .baseline, .stretch: y = rect.minY + (rect.height - height) / 2
            }
            var item = sceneItem(measured)
            item.frame = CGRect(x: x, y: y, width: width, height: height)
            layoutContents(of: &item, measured: measured)
            out.append(item)
            x += width + gap
        }
        return out
    }

    private func sceneItem(_ measured: Measured) -> SceneItem {
        let styled = measured.item
        let kind: SceneItem.Kind
        switch styled.config.kind {
        case .group: kind = .group
        case .spacer, .notch: kind = .spacer
        case .module: kind = .item
        }
        var item = SceneItem(name: styled.config.name, kind: kind, style: styled.style,
                             content: measured.node, states: styled.states, classes: styled.classes,
                             tooltip: styled.tooltip, priority: styled.config.priority,
                             actions: styled.config.actions)
        item.starting = styled.starting
        item.leaving = styled.leaving
        return item
    }

    private func layoutContents(of item: inout SceneItem, measured: Measured) {
        let border = item.style.borderWidth
        let inner = item.style.padding.inset(item.frame.insetBy(dx: border, dy: border))

        if measured.item.isGroup {
            item.children = place(measured.children, in: inner, gap: item.style.gap,
                                  align: measured.config.align ?? .stretch)
            return
        }
        guard var node = item.content else { return }
        let height = min(node.frame.height, inner.height)
        node.frame = CGRect(x: inner.minX, y: inner.minY + (inner.height - height) / 2,
                            width: inner.width, height: height)
        placeNode(&node, in: node.frame, align: .center)
        item.content = node
    }

    private func placeNode(_ node: inout SceneNode, in rect: CGRect, align: Align) {
        let inner = node.style.padding.inset(rect)
        switch node.kind {
        case .row(let container):
            let gap = container.gap ?? node.style.gap
            let align = container.align ?? align
            let widths = Flex.solve(node.children.map { child in
                Flex.Item(natural: child.frame.width, min: child.frame.width,
                          grow: child.isFlexible ? 1 : 0, shrink: 0)
            }, available: inner.width, gap: gap)
            var x = inner.minX
            for index in node.children.indices {
                var child = node.children[index]
                let height = align == .stretch ? inner.height : min(child.frame.height, inner.height)
                let y: Double
                switch align {
                case .start: y = inner.maxY - height
                case .end: y = inner.minY
                default: y = inner.minY + (inner.height - height) / 2
                }
                child.frame = CGRect(x: x, y: y, width: widths[index], height: height)
                placeNode(&child, in: child.frame, align: align)
                node.children[index] = child
                x += widths[index] + gap
            }
        case .column(let container):
            let gap = container.gap ?? node.style.gap
            let align = container.align ?? align
            var y = inner.maxY
            for index in node.children.indices {
                var child = node.children[index]
                let height = child.frame.height
                let width = min(child.frame.width, inner.width)
                let x: Double
                switch align {
                case .start: x = inner.minX
                case .end: x = inner.maxX - width
                default: x = inner.minX + (inner.width - width) / 2
                }
                child.frame = CGRect(x: x, y: y - height, width: width, height: height)
                placeNode(&child, in: child.frame, align: align)
                node.children[index] = child
                y -= height + gap
            }
        default:
            break
        }
    }
}

extension SceneNode {
    /// A spacer inside a content row is the only thing that takes free space.
    var isFlexible: Bool {
        if case .spacer(let spacer) = kind { return (spacer.grow ?? 1) > 0 }
        return false
    }
}
