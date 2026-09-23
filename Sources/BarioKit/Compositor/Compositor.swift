import AppKit

/// What a commit did, for the frame's trace and for tests.
public struct CommitReport: Sendable, Equatable, CustomStringConvertible {
    public var sceneChanged = false
    public var layersMade = 0
    public var layersRemoved = 0
    /// Images drawn.
    public var rasters = 0
    /// Renderer `draw` calls.
    public var draws = 0
    /// Seconds.
    public var duration: Double = 0
    /// A renderer asked, while drawing, to be drawn again in the next frame.
    public var wantsFrame = false

    public init() {}

    public var description: String {
        String(format: "%@+%d −%d layers, %d rasters, %d draws, %.2fms",
               sceneChanged ? "scene " : "hole ", layersMade, layersRemoved, rasters, draws,
               duration * 1000)
    }
}

/// One bar's layer tree, and commit: the last stage of a frame, which brings the tree up to
/// date with a presentation. DESIGN.md §10, PLAN.md.
///
/// ```
/// host layer (the surface's)
/// └─ root              bounds = scene.bounds; opacity = 1 − reveal; mask = the hole
///    ├─ bar chrome     the bar's background, while there is a backdrop
///    └─ item           bounds = item.frame; opacity, as a group
///       ├─ chrome      shadow, fill, border, in the margin box
///       ├─ content     clipped to the bubble's rounded box
///       │  └─ node     bounds = node.frame; opacity; its own background
///       │     ├─ leaf  a raster; a tint masked by coverage; pixels; a meter's track and fill
///       │     └─ node  a row's or column's children
///       └─ item        a group's children
/// ```
@MainActor
public final class Compositor {
    public let root: CALayer

    public struct Inputs {
        public var backdrop: BackdropImage
        /// The shadows the windows behind the bar cast into it, which fall on the backdrop
        /// before anything of the bar's own sits on top. DESIGN.md §7.
        public var shadows: ShadowField
        /// Colours for the current appearance and accent.
        public var resolver: ColorResolver
        /// The display's.
        public var scale: CGFloat
        /// When an animation this commit adds begins, in media time. Nil on screen, where it
        /// begins when the commit gets there; a fixed time offscreen, so a shot is repeatable.
        public var animationTime: CFTimeInterval?
        /// Node types registered by renderer modules, which draw here (DESIGN.md §9.2).
        public var renderers: RendererHost?
        /// Where a renderer's raster descriptor becomes pixels.
        public var rasters: RasterCache
        /// Surfaces native processes handed over, for `{"surface": …}` sources.
        public var surfaces: SharedSurfaces?

        public init(backdrop: BackdropImage, shadows: ShadowField = .empty,
                    resolver: ColorResolver, scale: CGFloat,
                    animationTime: CFTimeInterval? = nil, renderers: RendererHost? = nil,
                    rasters: RasterCache = RasterCache(), surfaces: SharedSurfaces? = nil) {
            self.backdrop = backdrop
            self.shadows = shadows
            self.resolver = resolver
            self.scale = scale
            self.animationTime = animationTime
            self.renderers = renderers
            self.rasters = rasters
            self.surfaces = surfaces
        }
    }

    private var factory = LayerFactory()
    private let bar = Chrome()
    let hole: HoleMask
    private var items: [LayerID: ItemRecord] = [:]
    private var nodes: [LayerID: NodeRecord] = [:]
    private var drawings: [LayerID: Drawing] = [:]
    private var hasScene = false

    /// What a renderer drew for one custom node, kept while its inputs stay the same.
    final class Drawing {
        struct Key: Hashable {
            var type: String
            var payload: JSONValue
            var style: RasterStyle
            var size: CGSize
            var scale: CGFloat
            var dark: Bool
        }

        var key: Key?
        var list: DisplayList?
        var image: CGImage?
        /// The renderer asked, while drawing this, to be drawn again in the next frame.
        var wantsFrame = false
    }

    public init(host: CALayer) {
        root = factory.make()
        hole = HoleMask(factory: &factory)
        host.addSublayer(root)
    }

    /// Bring the tree up to `presentation`. `sceneChanged` says whether the scene may differ
    /// from the last one committed (PLAN.md D3); when it does not, only the hole and the reveal
    /// are set, and no raster key is computed.
    @discardableResult
    public func commit(_ presentation: Presentation, inputs: Inputs, sceneChanged: Bool) -> CommitReport {
        let started = CACurrentMediaTime()
        let madeBefore = factory.made
        var report = CommitReport()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if sceneChanged || !hasScene {
            report.sceneChanged = true
            apply(presentation.scene, isMoving: presentation.isMoving, inputs: inputs, report: &report)
            hasScene = true
        }
        root.updateOpacity(1 - presentation.reveal)
        if presentation.hole.isVisible {
            hole.update(presentation.hole, in: root.bounds, scale: inputs.scale)
            if root.mask !== hole.layer { root.mask = hole.layer }
        } else if root.mask != nil {
            root.mask = nil
        }

        CATransaction.commit()
        report.layersMade = factory.made - madeBefore
        report.duration = CACurrentMediaTime() - started
        return report
    }

    /// The layer for an identity, if the last scene committed had one.
    public func layer(for id: LayerID) -> CALayer? {
        items[id]?.layer ?? nodes[id]?.layer
    }

    func item(_ id: LayerID) -> ItemRecord? { items[id] }
    func node(_ id: LayerID) -> NodeRecord? { nodes[id] }
    func drawing(_ id: LayerID) -> Drawing? { drawings[id] }

    // MARK: - The scene

    private func apply(_ scene: Scene, isMoving: Bool, inputs: Inputs, report: inout CommitReport) {
        root.place(scene.bounds)
        let resolver = inputs.resolver.with(current: inputs.resolver.resolve(scene.style.color))
        let context = Chrome.Context(resolver: resolver, backdrop: inputs.backdrop,
                                     shadows: inputs.shadows, barSize: scene.bounds.size)

        // No backdrop yet (or ever): stay out of the way rather than showing a black bar.
        var barStyle = Style()
        barStyle.color = scene.style.color
        barStyle.background = inputs.backdrop.image == nil ? .none : scene.style.background
        bar.apply(barStyle, in: scene.bounds, shadows: false, borders: false, context: context,
                  factory: &factory)

        var walk = Walk(inputs: inputs, context: context, scene: scene, isMoving: isMoving)
        let layers = scene.items.map { apply($0, walk: &walk, report: &report) }
        root.updateSublayers(bar.layers + layers)

        for (id, record) in items where !walk.seen.contains(id) {
            record.layer.removeFromSuperlayer()
            report.layersRemoved += record.layerCount
            items[id] = nil
        }
        for (id, record) in nodes where !walk.seen.contains(id) {
            record.layer.removeFromSuperlayer()
            report.layersRemoved += record.layerCount
            nodes[id] = nil
        }
        for id in drawings.keys where !walk.seen.contains(id) {
            drawings[id] = nil
        }
    }

    /// What a walk over one scene carries along.
    private struct Walk {
        var inputs: Inputs
        var context: Chrome.Context
        var scene: Scene
        var isMoving: Bool
        var seen: Set<LayerID> = []
        var occurrences: [String: Int] = [:]
        var ids: Set<LayerID> = []

        /// Names are unique among the items a config names; spacers are named by position, so
        /// the same name can come round again, and is told apart by occurrence.
        mutating func identity(of item: SceneItem) -> String {
            let count = occurrences[item.name, default: 0]
            occurrences[item.name] = count + 1
            return count == 0 ? item.name : "\(item.name)#\(count)"
        }

        /// A node's `id`, the first time it is seen in its item, and otherwise its index path.
        mutating func identity(of node: SceneNode, in item: String, path: [Int]) -> LayerID {
            if let id = node.id {
                let identity = LayerID.node(item: item, key: .id(id))
                if ids.insert(identity).inserted { return identity }
            }
            return .node(item: item, key: .path(path))
        }
    }

    private func apply(_ item: SceneItem, walk: inout Walk, report: inout CommitReport) -> CALayer {
        let name = walk.identity(of: item)
        let id = LayerID.item(name)
        walk.seen.insert(id)
        let record = items[id] ?? {
            let layer = factory.make()
            layer.allowsGroupOpacity = true
            let record = ItemRecord(layer: layer)
            items[id] = record
            return record
        }()

        record.layer.place(item.frame)
        record.layer.updateOpacity(item.style.opacity, animated: !item.style.animations.isEmpty)
        record.motion.apply(item.style, to: record.layer, animationTime: walk.inputs.animationTime)
        let box = item.style.margin.inset(item.frame)
        record.chrome.apply(item.style, in: box, shadows: true, borders: true,
                            context: walk.context, factory: &factory)

        var sublayers = record.chrome.layers
        if let content = item.content, box.width > 0, box.height > 0 {
            // Content never spills out of its bubble. It matters most while a bubble grows:
            // its content already has the size it was measured at, and would otherwise show
            // across the neighbours the bubble has not reached.
            let clip = record.clip ?? factory.make()
            record.clip = clip
            clip.place(box)
            assign(clip, \.masksToBounds, true)
            Outline(item.style.borderRadius, item.style.cornerShape, in: box)
                .apply(to: clip, in: box, mask: &record.clipMask, factory: &factory)
            let style = contrasted(item.style, in: item.frame, walk: walk)
            clip.updateSublayers([apply(content, path: [], inheriting: style, item: name,
                                        walk: &walk, report: &report)])
            sublayers.append(clip)
        } else {
            record.clip = nil
            record.clipMask = nil
        }
        for child in item.children {
            sublayers.append(apply(child, walk: &walk, report: &report))
        }
        record.layer.updateSublayers(sublayers)
        return record.layer
    }

    // MARK: - Nodes

    private func apply(_ node: SceneNode, path: [Int], inheriting parent: Style, item: String,
                       walk: inout Walk, report: inout CommitReport) -> CALayer {
        var node = node
        let style = NodeRasterizer.contrasted(node.style, inheriting: parent)
        let id = walk.identity(of: node, in: item, path: path)
        walk.seen.insert(id)
        if case .custom(let type, let payload) = node.kind {
            draw(&node, type: type, payload: payload, style: style, id: id, walk: walk, report: &report)
        }
        let role = LeafRole(node, style: style)
        var record: NodeRecord
        if let existing = nodes[id], existing.role == role {
            record = existing
        } else {
            if let existing = nodes[id] {
                existing.layer.removeFromSuperlayer()
                report.layersRemoved += existing.layerCount
            }
            let layer = factory.make()
            layer.allowsGroupOpacity = true
            record = NodeRecord(layer: layer, role: role)
            nodes[id] = record
        }

        record.layer.place(node.frame)
        record.layer.updateOpacity(style.opacity, animated: !style.animations.isEmpty)
        record.motion.apply(style, to: record.layer, animationTime: walk.inputs.animationTime)
        // A node's own background, without the shadow or border an item's box has.
        record.chrome.apply(style, in: node.frame, shadows: false, borders: false,
                            context: walk.context, factory: &factory)
        var sublayers = record.chrome.layers
        if let leaf = applyLeaf(node, style: style, record: record, walk: walk, report: &report) {
            sublayers.append(leaf)
        }
        for (index, child) in node.children.enumerated() {
            sublayers.append(apply(child, path: path + [index], inheriting: style, item: item,
                                   walk: &walk, report: &report))
        }
        record.layer.updateSublayers(sublayers)
        return record.layer
    }

    /// A renderer draws a node when what it draws from changed, or when it asked to be drawn
    /// again (DESIGN.md §9), and its drawing is the node's for as long as neither happens.
    private func draw(_ node: inout SceneNode, type: String, payload: JSONValue, style: Style,
                      id: LayerID, walk: Walk, report: inout CommitReport) {
        guard let renderers = walk.inputs.renderers, renderers.has(type) else {
            drawings[id] = nil
            return
        }
        let resolver = walk.context.resolver
        let colors = resolver.with(current: resolver.resolve(style.color))
        let key = Drawing.Key(type: type, payload: payload, style: RasterStyle(node, style: style, colors: colors),
                              size: node.frame.size, scale: walk.inputs.scale, dark: resolver.dark)
        let drawing = drawings[id] ?? Drawing()
        drawings[id] = drawing
        if drawing.key != key || drawing.wantsFrame {
            let (result, wantsFrame) = renderers.draw(type, payload: payload, style: style,
                                                      resolver: resolver, size: node.frame.size)
            report.draws += 1
            drawing.key = key
            drawing.wantsFrame = wantsFrame
            drawing.list = nil
            drawing.image = nil
            switch result {
            case .ops(let list):
                drawing.list = list
            case .raster(let descriptor, let instance):
                drawing.image = walk.inputs.rasters.image(
                    for: descriptor["source"] ?? descriptor,
                    width: descriptor["width"]?.doubleValue ?? node.frame.width,
                    height: descriptor["height"]?.doubleValue ?? node.frame.height,
                    instance: instance)
            case nil:
                break
            }
        }
        if drawing.wantsFrame { report.wantsFrame = true }
        node.displayList = drawing.list
        node.raster = drawing.image
    }

    private func applyLeaf(_ node: SceneNode, style: Style, record: NodeRecord, walk: Walk,
                           report: inout CommitReport) -> CALayer? {
        let colors = walk.context.resolver.with(current: walk.context.resolver.resolve(style.color))
        switch record.role {
        case .container, .nothing:
            return nil

        case .pixels:
            let layer = record.leaf ?? factory.make()
            record.leaf = layer
            layer.place(node.frame)
            if case .raster(let raster) = node.kind, let name = raster.source["surface"]?.stringValue {
                // The surface the producer drew last is the layer's contents: nothing drawn,
                // nothing copied (DESIGN.md §9.3).
                layer.updateContents(walk.inputs.surfaces?.surface(named: name))
            } else {
                layer.updateContents(node.raster)
            }
            return layer

        case .meter:
            guard case .meter(let meter) = node.kind else { return nil }
            return applyMeter(meter, in: node.frame, style: style, colors: colors, record: record)

        case .scroller:
            guard case .graph(let graph) = node.kind else { return nil }
            return applyScroller(node, graph: graph, style: style, colors: colors, record: record,
                                 walk: walk, report: &report)

        case .coverage:
            // The tint is a colour; the raster under it is only where the ink is.
            let tint = record.leaf ?? factory.make()
            let coverage = record.inner ?? factory.make()
            record.leaf = tint
            record.inner = coverage
            let ink: RGBA
            if case .text = node.kind {
                ink = colors.resolve(style.color)
            } else {
                ink = colors.resolve(style.effectiveIconColor)
            }
            tint.updateColor(ink.cgColor)
            raster(node, style: style, colors: colors, into: coverage, record: record, walk: walk,
                   report: &report) { rasterizer, ctx in
                rasterizer.drawCoverage(node, style: style, in: ctx)
            }
            tint.place(coverage.frame)
            if tint.mask !== coverage { tint.mask = coverage }
            // The mask is in the tint's own space, which is the same bar coordinates.
            return tint

        case .image:
            let layer = record.leaf ?? factory.make()
            record.leaf = layer
            raster(node, style: style, colors: colors, into: layer, record: record, walk: walk,
                   report: &report) { rasterizer, ctx in
                rasterizer.drawLeaf(node, style: style, in: ctx)
            }
            return layer
        }
    }

    /// Draws a leaf into `layer` when its key changed, or when it came to rest off the pixel
    /// grid, and places the layer over the node.
    /// `reach` is how far past the node's right edge the drawing goes, for a smooth graph.
    private func raster(_ node: SceneNode, style: Style, colors: ColorResolver, into layer: CALayer,
                        record: NodeRecord, walk: Walk, report: inout CommitReport,
                        reach: CGFloat = 0, draw: (NodeRasterizer, CGContext) -> Void) {
        let inputs = walk.inputs
        let key = RasterKey(kind: node.kind, size: node.frame.size,
                            style: RasterStyle(node, style: style, colors: colors),
                            drawing: node.displayList?.source, scale: inputs.scale,
                            dark: inputs.resolver.dark)
        let overhang = NodeRasterizer.overhang(of: node)
        var extent = node.frame.insetBy(dx: -overhang, dy: -overhang)
        extent.size.width += reach
        assign(layer, \.contentsScale, inputs.scale)

        // A raster is drawn with its pixels on the display's, as the painter drew, or glyphs
        // blur. Moving content keeps the pixels it has, off the grid for as long as it moves,
        // and a scene at rest draws it again if it came to rest somewhere else on the grid.
        let phase = NodeRasterizer.phase(of: extent.origin, scale: inputs.scale)
        let offGrid = abs(phase.width - record.drawnPhase.width) > 0.001
            || abs(phase.height - record.drawnPhase.height) > 0.001
        if key != record.key || (offGrid && !walk.isMoving) {
            let rasterizer = NodeRasterizer(resolver: walk.context.resolver, scale: inputs.scale)
            let rect = CGRect(x: extent.minX - phase.width, y: extent.minY - phase.height,
                              width: extent.width + phase.width, height: extent.height + phase.height)
            layer.updateContents(rasterizer.image(covering: rect) { ctx in draw(rasterizer, ctx) })
            record.key = key
            record.drawnPhase = phase
            record.drawnSize = NodeRasterizer.layerSize(of: rect.size, scale: inputs.scale)
            report.rasters += 1
        }
        layer.place(CGRect(x: extent.minX - record.drawnPhase.width,
                           y: extent.minY - record.drawnPhase.height,
                           width: record.drawnSize.width, height: record.drawnSize.height))
    }

    /// A smooth graph ([20-stats-widgets.md]): a strip one step wider than the node, with the
    /// newest value just past the right edge, inside a layer that clips to the node. When the
    /// values change the strip is drawn again and slid one step left over as long as the last
    /// change took, so the next sample lands exactly where the slide ends. The window server
    /// runs the slide; bario draws once per sample, as it would for a graph that steps.
    private func applyScroller(_ node: SceneNode, graph: Graph, style: Style, colors: ColorResolver,
                               record: NodeRecord, walk: Walk, report: inout CommitReport) -> CALayer {
        let clip = record.leaf ?? factory.make()
        let strip = record.inner ?? factory.make()
        record.leaf = clip
        record.inner = strip
        assign(clip, \.masksToBounds, true)
        // Clipped at the sides only, so a stroke at the top or the bottom keeps its overhang.
        let overhang = NodeRasterizer.overhang(of: node)
        clip.place(node.frame.insetBy(dx: 0, dy: -overhang))

        let step = NodeRasterizer.graphStep(graph, width: node.frame.width)
        let drawnValues = record.key.flatMap { key -> [Double?]? in
            if case .graph(let drawn) = key.kind { return drawn.values } else { return nil }
        }
        raster(node, style: style, colors: colors, into: strip, record: record, walk: walk,
               report: &report, reach: step) { rasterizer, ctx in
            rasterizer.drawLeaf(node, style: style, in: ctx)
        }
        if drawnValues != graph.values {
            let now = walk.inputs.animationTime ?? CACurrentMediaTime()
            if let last = record.slidAt, drawnValues != nil, step > 0 {
                let slide = CABasicAnimation(keyPath: "transform.translation.x")
                slide.fromValue = 0
                slide.toValue = -step
                // A sample that never came would hold the slide still for ever; a gap that long
                // is a pause, and the next one starts over.
                slide.duration = min(max(now - last, 0.05), 30)
                if let time = walk.inputs.animationTime { slide.beginTime = time }
                slide.fillMode = .forwards
                slide.isRemovedOnCompletion = false
                strip.add(slide, forKey: "bario.scroll")
            }
            record.slidAt = now
        }
        clip.updateSublayers([strip])
        return clip
    }

    /// A rounded track with the fill inside it, as wide as the value, and never narrower than
    /// it is tall so its ends stay round.
    private func applyMeter(_ meter: Meter, in frame: CGRect, style: Style, colors: ColorResolver,
                            record: NodeRecord) -> CALayer {
        let track = record.leaf ?? factory.make()
        let fill = record.inner ?? factory.make()
        record.leaf = track
        record.inner = fill
        let radius = max(0, min(frame.height, frame.width) / 2)
        track.place(frame)
        assign(track, \.cornerRadius, radius)
        assign(track, \.masksToBounds, true)
        let trackColor = colors.resolve(style.track)
        track.updateColor(trackColor.a > 0.001 ? trackColor.cgColor : nil)

        let fraction = min(max(meter.value, 0), 1)
        fill.place(CGRect(x: frame.minX, y: frame.minY,
                          width: max(frame.height, frame.width * fraction), height: frame.height))
        assign(fill, \.cornerRadius, radius)
        fill.updateColor(colors.resolve(style.fill).cgColor)
        let empty = fraction <= 0
        if fill.isHidden != empty { fill.isHidden = empty }
        track.updateSublayers([fill])
        return track
    }

    /// `contrast: auto` samples the backdrop under the item and picks light or dark text.
    /// DESIGN.md §13: an invisible bar with bare text needs this to be readable.
    private func contrasted(_ style: Style, in frame: CGRect, walk: Walk) -> Style {
        var style = style
        switch style.contrast {
        case .none:
            break
        case .light:
            style.color = .rgba(RGBA(r: 1, g: 1, b: 1))
        case .dark:
            style.color = .rgba(RGBA(r: 0, g: 0, b: 0))
        case .auto:
            guard let luminance = walk.inputs.backdrop.meanLuminance(in: frame,
                                                                     barSize: walk.scene.bounds.size)
            else { break }
            // A window shadow falls on the desktop before the item sits on it, so the ink is
            // chosen against the shaded backdrop rather than the bare photograph: an item over
            // the dark band under a window needs the light ink the photograph would not ask for.
            let shaded = luminance * (1 - walk.inputs.shadows.meanAlpha(in: frame))
            style.color = shaded > 0.55
                ? .rgba(RGBA(r: 0.08, g: 0.08, b: 0.08))
                : .rgba(RGBA(r: 0.97, g: 0.97, b: 0.97))
        }
        return style
    }
}

extension NodeRasterizer {
    /// How far past its frame a leaf's drawing can reach (PLAN.md D5): glyphs, strokes and
    /// symbols overhang, and canvases and rasters are clipped to their frames already.
    static func overhang(of node: SceneNode) -> CGFloat {
        switch node.kind {
        case .text: return max(2, (node.style.font.size / 4).rounded(.up))
        // A symbol draws at its own height, centred on a frame a line tall
        // (`CoreTextMetrics.symbolRect`): the tallest reach about a third of their point size
        // past it.
        case .icon: return max(2, (node.style.effectiveIconSize * 0.35).rounded(.up))
        case .graph: return node.style.strokeWidth / 2 + 1
        default: return 0
        }
    }

    /// How far past the display's pixel grid a point is, in points.
    static func phase(of point: CGPoint, scale: CGFloat) -> CGSize {
        func past(_ value: CGFloat) -> CGFloat {
            let pixels = value * scale
            let fraction = pixels - (pixels + 0.001).rounded(.down)
            return max(0, fraction) / scale
        }
        return CGSize(width: past(point.x), height: past(point.y))
    }
}
