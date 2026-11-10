import QuartzCore

/// Where an open menu's frames end up: a window of its own, or a recording in a test.
@MainActor
public protocol MenuSurface: BarSurface {
    /// Move and size the window, in screen coordinates. Only a frame calls this.
    func place(_ frame: CGRect)
    /// The menu has gone: the window can go too.
    func close()
}

/// One open menu's part of the pipeline: whose it is, what it hangs from, what each stage last
/// made of it, and the pointer over it. A submenu is one too, hanging from a row of the menu
/// before it in the chain.
@MainActor
public final class Menu {
    /// Whose menu it is: the item, or source, whose state fills it. A submenu's is its root's.
    public let item: String
    /// The item it hangs from, on the bar it hangs from. A submenu's is its root's.
    public let anchor: ItemRef
    /// For a submenu, the row it hangs from in its parent's tree, by index path; nil for the root.
    public let row: [Int]?
    /// That row as it was when the submenu opened, less its submenu: a new render that puts a
    /// different row at the same path closes the submenu rather than showing the other's.
    var rowNode: Node?
    /// 0 for the root, 1 for a submenu of it, and so on.
    public let depth: Int
    public let surface: any MenuSurface
    let compositor: Compositor
    /// No photograph: what is behind a menu is the live screen, which `glass` is made from.
    let backdrop = BackdropImage()

    /// The style stage's last output, and the layout made from it.
    var styled: StyledMenu?
    public internal(set) var layout: MenuScene?
    /// Where the anchor was when the menu was laid out, in screen coordinates.
    var anchorFrame: CGRect?
    var animator = Animator()
    public internal(set) var presentation: Presentation?
    var moving = false
    /// Laid out since the last commit.
    var sceneChanged = false
    /// Closed and gone: its window is closed and nothing more is presented.
    var finished = false
    /// Restyle at the next frame: a new render, the pointer, a drag.
    var dirty = true

    /// The control under the pointer, and the one being pressed, by index path in the tree.
    public internal(set) var hovered: [Int]?
    public internal(set) var pressed: [Int]?
    /// The arrow keys put the hover where it is, and it stays there until the pointer moves.
    var hoverFromKeys = false
    /// A slider being dragged, and the value it was dragged to: shown in place of the rendered
    /// one until a render after the release has had its say.
    var dragged: (path: [Int], value: Double, released: Bool)?
    /// How far its rows are scrolled up, when it is taller than its room,
    /// and a control to scroll into view at its next layout.
    public internal(set) var scroll: CGFloat = 0
    var reveal: [Int]?

    public internal(set) var isVisible = false
    /// On its way out, easing to its `:leaving` style. It takes no pointer, and goes once it gets
    /// there.
    public internal(set) var isClosing = false
    /// When it closed, so a menu with nothing to ease goes at once.
    var closedAt: CFTimeInterval?

    init(item: String, anchor: ItemRef, surface: any MenuSurface, row: [Int]? = nil, depth: Int = 0) {
        self.item = item
        self.anchor = anchor
        self.surface = surface
        self.row = row
        self.depth = depth
        compositor = Compositor(host: surface.hostLayer)
    }

    /// The panel's box on screen, if it has been laid out.
    public var panelFrame: CGRect? {
        guard let layout else { return nil }
        return layout.panel.offsetBy(dx: surface.frame.minX, dy: surface.frame.minY)
    }

    /// What a point on screen is over: the control there, if any, and whether it is on the panel
    /// at all. Hit testing reads what is presented.
    public func target(at point: CGPoint) -> MenuTarget {
        guard !isClosing, isVisible, surface.frame.containsPointer(point),
              let presentation, let layout else { return .outside }
        let local = CGPoint(x: point.x - surface.frame.minX, y: point.y - surface.frame.minY)
        guard layout.panel.containsPointer(local) else { return .outside }
        guard let content = presentation.scene.items.first?.content,
              let (path, node) = content.control(at: local) else { return .panel }
        return .control(path: path, node: node)
    }

    /// Where along the slider at `path` a point on screen is, from 0 to 1, wherever the pointer
    /// has got to: a drag carries on past the slider's ends.
    public func value(of path: [Int], at point: CGPoint) -> Double? {
        guard let node = presentation?.scene.items.first?.content?.node(at: path) else { return nil }
        return node.fraction(at: CGPoint(x: point.x - surface.frame.minX, y: point.y - surface.frame.minY))
    }

    /// The tree as it stands, with a dragged slider at its dragged value.
    func content(_ rendered: Node) -> Node {
        guard let dragged else { return rendered }
        return rendered.replacing(at: dragged.path) { node in
            guard case .slider(var meter) = node.kind else { return node }
            meter.value = dragged.value
            var node = node
            node.kind = .slider(meter)
            return node
        }
    }
}

/// What the pointer is over in a menu's window.
public enum MenuTarget {
    /// A control, by its index path in the menu's tree.
    case control(path: [Int], node: SceneNode)
    /// The panel, between controls.
    case panel
    /// Not the panel: the window's margin, or somewhere else altogether.
    case outside
}

extension SceneNode {
    /// The innermost control under a point, with its index path from this node.
    func control(at point: CGPoint, path: [Int] = []) -> ([Int], SceneNode)? {
        guard frame.containsPointer(point) else { return nil }
        for (index, child) in children.enumerated().reversed() {
            if let hit = child.control(at: point, path: path + [index]) { return hit }
        }
        return actions.isControl ? (path, self) : nil
    }

    /// The node at an index path from this one.
    func node(at path: [Int]) -> SceneNode? {
        guard let first = path.first else { return self }
        guard children.indices.contains(first) else { return nil }
        return children[first].node(at: Array(path.dropFirst()))
    }

    /// Whether this node, or one on the way to it from here, says a click leaves the menu open.
    func keepsOpen(at path: [Int]) -> Bool {
        if actions.keepOpen { return true }
        guard let first = path.first, children.indices.contains(first) else { return false }
        return children[first].keepsOpen(at: Array(path.dropFirst()))
    }

    /// Where along a slider a point is, from 0 at its left to 1 at its right.
    func fraction(at point: CGPoint) -> Double {
        guard frame.width > 0 else { return 0 }
        return min(1, max(0, Double((point.x - frame.minX) / frame.width)))
    }
}

extension Node {
    /// The tree with the node at `path` replaced by what `change` makes of it.
    func replacing(at path: [Int], _ change: (Node) -> Node) -> Node {
        guard let first = path.first else { return change(self) }
        var node = self
        switch kind {
        case .row(var container), .column(var container):
            guard container.children.indices.contains(first) else { return self }
            container.children[first] = container.children[first].replacing(at: Array(path.dropFirst()), change)
            if case .row = kind { node.kind = .row(container) } else { node.kind = .column(container) }
        default:
            return self
        }
        return node
    }
}
