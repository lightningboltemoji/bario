import CoreGraphics

/// One bar laid out: every item and node with its resolved style and its rectangle. What the
/// layout stage produces and the animator eases between. DESIGN.md §10.
public struct Scene: Sendable {
    public var display: DisplayInfo
    /// The cover's bounds, origin at the bottom left, as the painter draws in.
    public var bounds: CGRect
    /// The bar's own box: the top of the cover, as tall as the bar. Its background fills it
    /// and its items are laid out inside it. Below it, on a display whose menu bar is taller,
    /// the rest of the menu bar is covered by the desktop and nothing else. DESIGN.md §6.
    public var bar: CGRect
    public var style: Style
    public var rows: [SceneRow]
    /// Dropped for lack of room. Still rendered into the store, so a catch-all item can list
    /// them later.
    public var hidden: [SceneItem]
    /// Items taller than the bar has room for, which it squeezed to fit, with the bar height
    /// that would have held each one.
    public var squeezed: [(item: String, needs: Double)] = []
    public var notch: CGRect?
    public var hole: HoleConfig

    public init(display: DisplayInfo, bounds: CGRect, bar: CGRect? = nil, style: Style,
                rows: [SceneRow] = [], hidden: [SceneItem] = [], notch: CGRect? = nil,
                hole: HoleConfig = HoleConfig()) {
        self.display = display
        self.bounds = bounds
        self.bar = bar ?? bounds
        self.style = style
        self.rows = rows
        self.hidden = hidden
        self.notch = notch
        self.hole = hole
    }

    /// The part of the cover over the real menu bar, which is all the photograph of the
    /// desktop stands in for. A bar taller than the menu bar hangs below it, over the live
    /// screen.
    public var menuBar: CGRect {
        let height = min(bounds.height, display.menuBarHeight)
        return CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
    }

    public var items: [SceneItem] { rows.flatMap(\.items) }

    /// Depth-first over every item and every item inside a group.
    public var allItems: [SceneItem] { items.flatMap(\.selfAndDescendants) }

    /// The item under a point, innermost first. A spacer is the space between items, not one,
    /// and an item on its way out is not there to be pointed at.
    public func item(at point: CGPoint) -> SceneItem? {
        for item in allItems.reversed()
        where item.kind != .spacer && !item.states.contains(.leaving) && item.frame.contains(point) {
            return item
        }
        return nil
    }
}

public struct SceneRow: Sendable {
    /// The area this row was laid out in, already inset by the bar's padding.
    public var frame: CGRect
    public var items: [SceneItem]

    public init(frame: CGRect, items: [SceneItem] = []) {
        self.frame = frame
        self.items = items
    }
}

public struct SceneItem: Sendable {
    public enum Kind: Sendable, Hashable {
        case item
        case group
        case spacer
    }

    public var name: String
    public var kind: Kind
    public var style: Style
    public var frame: CGRect
    public var content: SceneNode?
    public var children: [SceneItem]
    public var states: Set<StyleState>
    public var classes: Set<String>
    public var tooltip: String?
    public var priority: Int
    /// The item's config, so interaction can find `on-click` without another lookup.
    public var actions: Actions
    /// What it transitions from when it appears (`@starting-style`), and to when it leaves
    /// (`:leaving`); nil when the stylesheet says nothing, and it snaps.
    public var starting: Style?
    public var leaving: Style?

    public init(name: String, kind: Kind, style: Style, frame: CGRect = .zero,
                content: SceneNode? = nil, children: [SceneItem] = [],
                states: Set<StyleState> = [], classes: Set<String> = [],
                tooltip: String? = nil, priority: Int = 0, actions: Actions = Actions()) {
        self.name = name
        self.kind = kind
        self.style = style
        self.frame = frame
        self.content = content
        self.children = children
        self.states = states
        self.classes = classes
        self.tooltip = tooltip
        self.priority = priority
        self.actions = actions
    }

    public var selfAndDescendants: [SceneItem] {
        [self] + children.flatMap(\.selfAndDescendants)
    }

    /// The style type name a selector matches: `item`, `group`, or `spacer`.
    public var typeName: String {
        switch kind {
        case .item: return "item"
        case .group: return "group"
        case .spacer: return "spacer"
        }
    }
}

public struct SceneNode: @unchecked Sendable {
    public var kind: NodeKind
    public var style: Style
    public var frame: CGRect
    public var children: [SceneNode]
    public var id: String?
    public var classes: [String]
    /// A `canvas` node's ops, parsed when the scene is built, because commits happen far more
    /// often than content changes. A renderer's drawing is kept by the compositor instead, and
    /// set here only on the node it commits.
    public var displayList: DisplayList?
    /// A `raster` node's decoded pixels, likewise; or, at commit, what a renderer's `draw`
    /// returned instead of ops.
    public var raster: CGImage?

    public init(kind: NodeKind, style: Style, frame: CGRect = .zero,
                children: [SceneNode] = [], id: String? = nil, classes: [String] = [],
                displayList: DisplayList? = nil, raster: CGImage? = nil) {
        self.kind = kind
        self.style = style
        self.frame = frame
        self.children = children
        self.id = id
        self.classes = classes
        self.displayList = displayList
        self.raster = raster
    }

    public var selfAndDescendants: [SceneNode] {
        [self] + children.flatMap(\.selfAndDescendants)
    }
}
