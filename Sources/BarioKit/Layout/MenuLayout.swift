import CoreGraphics

/// A menu laid out (PLAN.md M3, M14): a scene whose bounds are its window, holding one item, the
/// panel, whose content is the menu's tree; and where on screen the window goes.
public struct MenuScene: Sendable {
    public var scene: Scene
    /// The window, in screen coordinates.
    public var frame: CGRect
    /// The panel's box in the scene, inside its margin: what a click outside of closes the menu.
    public var panel: CGRect

    /// The panel, the scene's one item.
    public var item: SceneItem? { scene.rows.first?.items.first }
}

extension BarLayout {
    /// The name of a menu's one item, which is its layers' identity.
    public static let menuItem = "menu"

    /// Lay a menu out under the item it hangs from. `anchor` is that item and `top` the bottom
    /// of its bar, in screen coordinates; `align` is which of the item's edges the panel's lines
    /// up with; the panel is moved in to stay on `display`, and its margin is the gap below the bar.
    ///
    /// The menu's `opacity`, `transform` and `transition` become the scene's style, which is how
    /// a window comes and goes, as a bar's does; the rest of it is the panel's chrome.
    public func layout(menu styled: StyledMenu, anchor: CGRect, top: CGFloat, align: Align = .start,
                       on display: DisplayInfo) -> MenuScene {
        let style = styled.style
        var node = measureNode(styled.content)

        // The panel is its content and its padding and border, clamped as an item is.
        var width = node.frame.width + style.padding.horizontal + style.borderWidth.horizontal
        let height = node.frame.height + style.padding.vertical + style.borderWidth.vertical
        if let fixed = style.width { width = fixed }
        if let min = style.minWidth { width = max(width, min) }
        if let max = style.maxWidth { width = min(width, max) }
        let edge = BarLayout.menuEdge
        width = min(width, max(0, display.frame.width - 2 * edge - style.margin.horizontal))
        let outer = CGSize(width: width + style.margin.horizontal, height: height + style.margin.vertical)

        // On screen: under the item, and on the display.
        var x: CGFloat
        switch align {
        case .center: x = anchor.midX - outer.width / 2
        case .end: x = anchor.maxX - outer.width
        default: x = anchor.minX
        }
        x = min(max(x, display.frame.minX + edge), display.frame.maxX - edge - outer.width)
        let reach = BarLayout.reach(of: styled)
        let frame = CGRect(x: x - reach, y: top - outer.height - reach,
                           width: outer.width + 2 * reach, height: outer.height + 2 * reach)

        // In the window, which has room around the panel for its shadow and its coming and going.
        let bounds = CGRect(origin: .zero, size: frame.size)
        let item = CGRect(x: reach, y: reach, width: outer.width, height: outer.height)
        let box = style.margin.inset(item)
        let inner = style.padding.inset(style.borderWidth.inset(box))
        node.frame = node.style.margin.inset(inner)
        // A menu is a list: a column that says nothing stretches its rows to its width.
        placeNode(&node, in: node.frame, align: .stretch)

        var panel = style
        panel.opacity = 1
        panel.transform = .identity
        let sceneItem = SceneItem(name: BarLayout.menuItem, kind: .item, style: panel, frame: item,
                                  content: node)
        var scene = Scene(display: display, bounds: bounds, bar: bounds, style: BarLayout.surface(of: style),
                          rows: [SceneRow(frame: bounds, items: [sceneItem])])
        scene.starting = styled.starting.map(BarLayout.surface)
        scene.leaving = styled.leaving.map(BarLayout.surface)
        return MenuScene(scene: scene, frame: frame, panel: box)
    }

    /// How close a menu comes to the sides of its display.
    static let menuEdge: CGFloat = 6

    /// The part of a menu's style that is its window's: how it comes and goes.
    static func surface(of style: Style) -> Style {
        var surface = Style()
        surface.opacity = style.opacity
        surface.transform = style.transform
        surface.transitions = style.transitions
        surface.color = style.color
        return surface
    }

    /// How far past the panel a menu draws: its shadow, and wherever it slides in from or out to.
    static func reach(of styled: StyledMenu) -> CGFloat {
        var reach: Double = 2
        if let shadow = styled.style.shadow { reach += shadow.blur + max(abs(shadow.dx), abs(shadow.dy)) }
        let slides = [styled.style, styled.starting, styled.leaving].compactMap { $0?.transform }
            .map { max(abs($0.translateX), abs($0.translateY)) }
        return CGFloat(reach + (slides.max() ?? 0))
    }
}
