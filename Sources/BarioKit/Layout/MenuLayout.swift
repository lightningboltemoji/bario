import CoreGraphics

/// A menu laid out: a scene whose bounds are its window, holding one item, the
/// panel, whose content is the menu's tree; and where on screen the window goes.
public struct MenuScene: Sendable {
    public var scene: Scene
    /// The window, in screen coordinates.
    public var frame: CGRect
    /// The panel's box in the scene, inside its margin: what a click outside of closes the menu.
    public var panel: CGRect
    /// How far its rows are scrolled up, kept in range: a menu taller than the room it has is cut
    /// to fit, and its rows scroll inside it. 0 for one that fits.
    public var scroll: CGFloat = 0

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
    ///
    /// `scroll` is how far its rows were scrolled, and `reveal` a node to scroll into view.
    public func layout(menu styled: StyledMenu, anchor: CGRect, top: CGFloat, align: Align = .start,
                       on display: DisplayInfo, scroll: CGFloat = 0, reveal: [Int]? = nil) -> MenuScene {
        let style = styled.style
        let node = measureNode(styled.content)
        let size = panelSize(of: node, style: style, on: display,
                             room: top - display.frame.minY - BarLayout.menuEdge - style.margin.vertical)
        let outer = CGSize(width: size.width + style.margin.horizontal, height: size.height + style.margin.vertical)

        // On screen: under the item, and on the display.
        var x: CGFloat
        switch align {
        case .center: x = anchor.midX - outer.width / 2
        case .end: x = anchor.maxX - outer.width
        default: x = anchor.minX
        }
        let edge = BarLayout.menuEdge
        x = min(max(x, display.frame.minX + edge), display.frame.maxX - edge - outer.width)
        let item = CGRect(x: x, y: top - outer.height, width: outer.width, height: outer.height)
        return finish(styled, node: node, item: item, display: display, scroll: scroll, reveal: reveal)
    }

    /// Lay a submenu out beside the row it hangs from. `parent` is the
    /// parent's panel and `row` the row, in screen coordinates; `top` is the bottom of the bar,
    /// which no menu goes above. Its first row is level with `row`; it sits right of the parent,
    /// or left when the display has no room there; the gap is its `margin-left`.
    public func layout(submenu styled: StyledMenu, beside parent: CGRect, row: CGRect, top: CGFloat,
                       on display: DisplayInfo, scroll: CGFloat = 0, reveal: [Int]? = nil) -> MenuScene {
        let style = styled.style
        let edge = BarLayout.menuEdge
        let node = measureNode(styled.content)
        let size = panelSize(of: node, style: style, on: display,
                             room: top - display.frame.minY - 2 * edge)
        // Right if it fits, left if it fits there, and otherwise on whichever side has more room,
        // overlapping its parent as little as the display allows.
        let gap = style.margin.left
        let (minX, maxX) = (display.frame.minX + edge, display.frame.maxX - edge)
        var x = parent.maxX + gap
        if x + size.width > maxX {
            let left = parent.minX - gap - size.width
            if left >= minX {
                x = left
            } else {
                x = maxX - parent.maxX >= parent.minX - minX ? maxX - size.width : minX
            }
        }
        x = max(minX, min(x, maxX - size.width))
        // The first row's top where its row's is: the panel starts its border and padding above.
        var boxTop = row.maxY + style.borderWidth.top + style.padding.top + node.style.margin.top
        boxTop = min(boxTop, top)
        boxTop = max(boxTop, display.frame.minY + edge + size.height)
        let box = CGRect(x: x, y: boxTop - size.height, width: size.width, height: size.height)
        let item = CGRect(x: box.minX - style.margin.left, y: box.minY - style.margin.bottom,
                          width: box.width + style.margin.horizontal, height: box.height + style.margin.vertical)
        return finish(styled, node: node, item: item, display: display, scroll: scroll, reveal: reveal)
    }

    /// How close a menu comes to the sides of its display.
    static let menuEdge: CGFloat = 6

    /// The panel is its content and its padding and border, clamped as an item is, and no taller
    /// than `room`.
    private func panelSize(of node: SceneNode, style: Style, on display: DisplayInfo, room: CGFloat) -> CGSize {
        var width = node.frame.width + style.padding.horizontal + style.borderWidth.horizontal
        let height = node.frame.height + style.padding.vertical + style.borderWidth.vertical
        if let fixed = style.width { width = fixed }
        if let min = style.minWidth { width = max(width, min) }
        if let max = style.maxWidth { width = min(width, max) }
        width = min(width, max(0, display.frame.width - 2 * BarLayout.menuEdge - style.margin.horizontal))
        return CGSize(width: width, height: min(height, max(0, room)))
    }

    /// The window around the panel, `item` being the panel with its margin in screen coordinates;
    /// and the content placed in it, scrolled.
    private func finish(_ styled: StyledMenu, node measured: SceneNode, item screenItem: CGRect,
                        display: DisplayInfo, scroll: CGFloat, reveal: [Int]?) -> MenuScene {
        let style = styled.style
        let reach = BarLayout.reach(of: styled)
        let frame = screenItem.insetBy(dx: -reach, dy: -reach)

        // In the window, which has room around the panel for its shadow and its coming and going.
        let bounds = CGRect(origin: .zero, size: frame.size)
        let item = CGRect(x: reach, y: reach, width: screenItem.width, height: screenItem.height)
        let box = style.margin.inset(item)
        let inner = style.padding.inset(style.borderWidth.inset(box))
        // Its natural height, which a menu cut to fit is taller than: it scrolls up through the
        // panel, which clips it.
        let natural = measured.frame.height
        let most = max(0, natural - inner.height)
        func placed(_ scroll: CGFloat) -> SceneNode {
            var node = measured
            node.frame = node.style.margin.inset(CGRect(x: inner.minX, y: inner.maxY - natural + scroll,
                                                        width: inner.width, height: natural))
            // A menu is a list: a column that says nothing stretches its rows to its width.
            placeNode(&node, in: node.frame, align: .stretch)
            return node
        }
        var scroll = min(max(0, scroll), most)
        var node = placed(scroll)
        if most > 0, let reveal, let target = node.node(at: reveal)?.frame {
            if target.maxY > inner.maxY { scroll -= target.maxY - inner.maxY }
            if target.minY < inner.minY { scroll += inner.minY - target.minY }
            scroll = min(max(0, scroll), most)
            node = placed(scroll)
        }

        var panel = style
        panel.opacity = 1
        panel.transform = .identity
        let sceneItem = SceneItem(name: BarLayout.menuItem, kind: .item, style: panel, frame: item,
                                  content: node)
        var scene = Scene(display: display, bounds: bounds, bar: bounds, style: BarLayout.surface(of: style),
                          rows: [SceneRow(frame: bounds, items: [sceneItem])])
        scene.starting = styled.starting.map(BarLayout.surface)
        scene.leaving = styled.leaving.map(BarLayout.surface)
        return MenuScene(scene: scene, frame: frame, panel: box, scroll: scroll)
    }

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
