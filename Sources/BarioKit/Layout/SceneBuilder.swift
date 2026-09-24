import CoreGraphics

/// Style and layout in one call, for everything that wants one scene rather than a stream of
/// frames: `--shot`, `--diagnose`, and tests. The running bar calls the two stages
/// separately, so that a layout invalidation does not re-cascade.
public struct SceneBuilder: Sendable {
    public var styler: Styler
    public var layout: BarLayout

    public typealias Interaction = Styler.Interaction

    public init(cascade: Cascade, metrics: any Metrics = CoreTextMetrics(),
                renderers: RendererHost? = nil, rasters: RasterCache = RasterCache(),
                resolver: ColorResolver = ColorResolver()) {
        styler = Styler(cascade: cascade)
        layout = BarLayout(metrics: metrics, renderers: renderers, rasters: rasters, resolver: resolver)
    }

    public func build(bar: BarConfig,
                      display: DisplayInfo,
                      items: [ItemConfig],
                      states: [String: ModuleHost.ItemState],
                      interaction: Interaction = Interaction(),
                      modes: Set<String> = []) -> Scene {
        layout.layout(styler.style(bar: bar, items: items, states: states, interaction: interaction,
                                   modes: modes),
                      on: display)
    }
}
