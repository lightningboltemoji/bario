import AppKit

/// What a node becomes in the layer tree. A node whose role changes (text that is now a meter,
/// a symbol that stopped being monochrome) gets a new record rather than a reconfigured one
/// (PLAN.md D4).
enum LeafRole: Equatable {
    /// A row or column: its children are layers of their own.
    case container
    /// Text and monochrome symbols: coverage alone, masking a layer whose colour is the tint,
    /// so a colour change draws nothing (PLAN.md D6).
    case coverage
    /// Everything with colours of its own: symbols in other renderings, graphs, canvases,
    /// renderers' drawings.
    case image
    /// Finished pixels, shown as the layer's contents as they are.
    case pixels
    /// Two layers; the value is a width.
    case meter
    /// A smooth graph: a raster one step wider than the node, sliding inside a layer that
    /// clips to it.
    case scroller
    case nothing

    init(_ node: SceneNode, style: Style) {
        switch node.kind {
        case .row, .column: self = .container
        case .text: self = .coverage
        case .icon: self = style.iconRendering == .monochrome ? .coverage : .image
        case .meter: self = .meter
        case .graph(let graph): self = graph.scroll == .smooth ? .scroller : .image
        case .canvas: self = .image
        case .raster: self = .pixels
        case .custom:
            if node.displayList != nil { self = .image }
            else if node.raster != nil { self = .pixels }
            else { self = .nothing }
        case .spacer: self = .nothing
        }
    }
}

/// Which side of mid-luminance text's colour falls. With font smoothing on, CoreText draws
/// light ink heavier than dark, so text coverage is drawn in one or the other: a tint that
/// stays on its side draws nothing, and one that crosses draws once.
enum Ink: Hashable {
    case dark, light

    init(_ color: RGBA) {
        self = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b > 0.5 ? .light : .dark
    }

    var color: RGBA { self == .light ? RGBA(r: 1, g: 1, b: 1) : RGBA(r: 0, g: 0, b: 0) }
}

/// A style's raster rows for one kind of leaf (DESIGN.md §10): everything in it that changes
/// the pixels that leaf draws, resolved, and nothing else. Not opacity, not transitions, not
/// the box, and for coverage no colour at all.
struct RasterStyle: Hashable {
    var font: FontSpec?
    var letterSpacing: Double?
    var textTransform: TextTransform?
    var ink: Ink?
    var iconSize: Double?
    var iconWeight: Double?
    var iconRendering: IconRendering?
    var iconColor: RGBA?
    var color: RGBA?
    var fill: RGBA?
    var accent: RGBA?
    var strokeWidth: Double?
    var lineCap: LineCap?
    /// For `var()` inside a display list.
    var custom: [String: [CSSComponent]]?

    /// `style` with contrast already applied; `colors` with `currentColor` as its colour.
    init(_ node: SceneNode, style: Style, colors: ColorResolver) {
        switch node.kind {
        case .text:
            font = style.font
            letterSpacing = style.letterSpacing
            textTransform = style.textTransform
            ink = Ink(colors.resolve(style.color))
        case .icon:
            iconSize = style.effectiveIconSize
            iconWeight = style.effectiveIconWeight
            iconRendering = style.iconRendering
            if style.iconRendering != .monochrome {
                iconColor = colors.resolve(style.effectiveIconColor)
            }
        case .graph:
            fill = colors.resolve(style.fill)
            strokeWidth = style.strokeWidth
            lineCap = style.lineCap
        case .canvas, .custom:
            // A display list reaches anything a style says, through `currentColor`, `var()`
            // and its own defaults.
            font = style.font
            color = colors.resolve(style.color)
            accent = colors.accent
            iconSize = style.effectiveIconSize
            iconWeight = style.effectiveIconWeight
            iconRendering = style.iconRendering
            iconColor = colors.resolve(style.effectiveIconColor)
            strokeWidth = style.strokeWidth
            lineCap = style.lineCap
            custom = style.custom
        case .row, .column, .meter, .spacer, .raster:
            break
        }
    }
}

/// Everything a leaf's raster depends on (DESIGN.md §10). A raster is a function of its key,
/// and a commit draws one only when its key changed: a stale pixel is an input missing from
/// here.
struct RasterKey: Hashable {
    /// The kind and its payload: text, a symbol's name, a graph's values, a canvas's ops.
    var kind: NodeKind
    var size: CGSize
    var style: RasterStyle
    /// A renderer's drawing.
    var drawing: [JSONValue]?
    var scale: CGFloat
    var dark: Bool
}
