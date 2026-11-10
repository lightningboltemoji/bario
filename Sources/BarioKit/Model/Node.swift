import Foundation

/// One node in a content tree: exactly one kind, plus the hooks the stylesheet addresses it
/// by. DESIGN.md §2.
public struct Node: Sendable, Hashable {
    public var kind: NodeKind
    public var id: String?
    public var classes: [String]
    /// What the pointer does to it. A node with any is a control: it is hit, it hovers, and its
    /// action runs as its item's would.
    public var actions: NodeActions

    public init(_ kind: NodeKind, id: String? = nil, classes: [String] = [],
                actions: NodeActions = NodeActions()) {
        self.kind = kind
        self.id = id
        self.classes = classes
        self.actions = actions
    }

    public var children: [Node] {
        switch kind {
        case .row(let c), .column(let c): return c.children
        default: return []
        }
    }

    /// The selector type name this node matches (`text`, `icon`, `ring`, …).
    public var typeName: String { kind.typeName }
}

public indirect enum NodeKind: Sendable, Hashable {
    case text(String)
    case icon(IconSpec)
    case meter(Meter)
    /// A meter you can drag, which sends its item `on-change` with the value it was dragged to
    ///.
    case slider(Meter)
    case graph(Graph)
    case row(Container)
    case column(Container)
    case spacer(Spacer)
    case canvas(CanvasNode)
    case raster(RasterNode)
    /// A node type registered by a renderer module (DESIGN.md §9.2). Unknown at decode time
    /// by design: the decoder cannot know the registry, so it keeps the payload as data.
    case custom(String, JSONValue)

    public var typeName: String {
        switch self {
        case .text: return "text"
        case .icon: return "icon"
        case .meter: return "meter"
        case .slider: return "slider"
        case .graph: return "graph"
        case .row: return "row"
        case .column: return "column"
        case .spacer: return "spacer"
        case .canvas: return "canvas"
        case .raster: return "raster"
        case .custom(let name, _): return name
        }
    }
}

// MARK: - Controls

/// A node's own shortcuts, in the action language of an item's (DESIGN.md §8), and whether
/// using one leaves its menu open.
public struct NodeActions: Sendable, Hashable {
    public var click: String?
    public var rightClick: String?
    public var scroll: String?
    /// A slider's: sent with the value it was dragged or scrolled to.
    public var change: String?
    /// Clicking it, or anything inside it, leaves its menu open.
    public var keepOpen: Bool
    /// A menu of its own, opened beside it when it is hovered or clicked in a menu: several
    /// nodes are a column, as in `menu`. Not laid out where it is.
    public var submenu: [Node]?

    public init(click: String? = nil, rightClick: String? = nil, scroll: String? = nil,
                change: String? = nil, keepOpen: Bool = false, submenu: [Node]? = nil) {
        self.click = click
        self.rightClick = rightClick
        self.scroll = scroll
        self.change = change
        self.keepOpen = keepOpen
        self.submenu = submenu
    }

    /// Whether the pointer has anything to do here.
    public var isControl: Bool {
        click != nil || rightClick != nil || scroll != nil || change != nil || submenu != nil
    }

    /// The JSON keys, which sit on the node beside `id` and `class`.
    static let keys = ["on-click", "on-right-click", "on-scroll", "on-change", "keep-open", "submenu"]
}

extension Node {
    /// What a menu is made of, as one tree: one node is itself, and several are a column, since
    /// a menu is a list. nil for none.
    public static func menu(_ nodes: [Node]) -> Node? {
        guard let first = nodes.first else { return nil }
        return nodes.count == 1 ? first : .column(nodes)
    }

    /// The node at an index path from this one.
    public func node(at path: [Int]) -> Node? {
        guard let first = path.first else { return self }
        guard children.indices.contains(first) else { return nil }
        return children[first].node(at: Array(path.dropFirst()))
    }

    /// The node as its row shows it, without what it opens: what says a submenu is still the
    /// one it was after a new render.
    var withoutSubmenu: Node {
        var node = self
        node.actions.submenu = nil
        return node
    }

    /// The first control in the tree, depth first, by its index path.
    public func firstControl(path: [Int] = []) -> [Int]? {
        if actions.isControl { return path }
        for (index, child) in children.enumerated() {
            if let found = child.firstControl(path: path + [index]) { return found }
        }
        return nil
    }
}

// MARK: - Payloads

public enum IconSpec: Sendable, Hashable {
    /// An SF Symbol name. The reason to be on macOS.
    case symbol(String)
    case file(String)

    public var name: String {
        switch self {
        case .symbol(let s), .file(let s): return s
        }
    }
}

public struct Meter: Sendable, Hashable {
    public var value: Double
    public var width: Double?

    public init(value: Double, width: Double? = nil) {
        self.value = value
        self.width = width
    }
}

public struct Graph: Sendable, Hashable {
    /// Oldest first. A nil is a gap: a history not yet full is padded with them in front, so
    /// its step stays the same while it fills.
    public var values: [Double?]
    public var width: Double?
    /// The top, fixed. Without it the graph scales to its largest value.
    public var max: Double?
    /// The least an auto-scaled top can stand for, so an idle graph is flat rather than noise
    /// at full height.
    public var floor: Double?
    public var kind: GraphKind
    public var scroll: GraphScroll

    public init(values: [Double?], width: Double? = nil, max: Double? = nil, floor: Double? = nil,
                kind: GraphKind = .line, scroll: GraphScroll = .step) {
        self.values = values
        self.width = width
        self.max = max
        self.floor = floor
        self.kind = kind
        self.scroll = scroll
    }

    /// What the top of the graph stands for.
    public var ceiling: Double {
        if let max { return max }
        return Swift.max(values.compactMap { $0 }.max() ?? 0, floor ?? 0)
    }
}

public enum GraphKind: String, Sendable, Hashable, CaseIterable {
    case line, area, bars
}

/// How a graph shows new values: redrawn in place, or slid in from the right over the time
/// the last sample took.
public enum GraphScroll: String, Sendable, Hashable, CaseIterable {
    case step, smooth
}

public struct Container: Sendable, Hashable {
    public var gap: Double?
    public var align: Align?
    public var children: [Node]

    public init(gap: Double? = nil, align: Align? = nil, children: [Node] = []) {
        self.gap = gap
        self.align = align
        self.children = children
    }
}

public enum Align: String, Sendable, Hashable, Codable, CaseIterable {
    case start, center, end, stretch, baseline
}

public struct Spacer: Sendable, Hashable {
    public var grow: Double?

    public init(grow: Double? = nil) { self.grow = grow }
}

/// A vector display list painted by the host (DESIGN.md §9.1). The ops stay as data until
/// the painter that consumes them exists; they are a published wire format either way.
public struct CanvasNode: Sendable, Hashable {
    public var width: Double?
    public var height: Double?
    public var ops: [JSONValue]

    public init(width: Double? = nil, height: Double? = nil, ops: [JSONValue] = []) {
        self.width = width
        self.height = height
        self.ops = ops
    }
}

/// Finished pixels supplied by a module (DESIGN.md §9.3). `source` is a WASM memory range, a
/// shared-memory path or inline PNG bytes; typed when the raster path lands.
public struct RasterNode: Sendable, Hashable {
    public var width: Double
    public var height: Double?
    public var source: JSONValue

    public init(width: Double, height: Double? = nil, source: JSONValue) {
        self.width = width
        self.height = height
        self.source = source
    }
}

// MARK: - Render result

/// What a module hands back, whatever tier it lives in. DESIGN.md §2.
public struct RenderResult: Sendable, Hashable {
    public var content: Node?
    /// State classes on the item itself, in the waybar sense (`#battery.charging`).
    public var classes: [String]
    public var tooltip: String?
    public var visible: Bool

    public init(content: Node? = nil, classes: [String] = [], tooltip: String? = nil, visible: Bool = true) {
        self.content = content
        self.classes = classes
        self.tooltip = tooltip
        self.visible = visible
    }
}

extension RenderResult: Codable {
    private enum Keys: String, CodingKey { case content, classes, tooltip, visible }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        content = try c.decodeIfPresent(Node.self, forKey: .content)
        classes = try c.decodeIfPresent(StringList.self, forKey: .classes)?.values ?? []
        tooltip = try c.decodeIfPresent(String.self, forKey: .tooltip)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(content, forKey: .content)
        if !classes.isEmpty { try c.encode(classes, forKey: .classes) }
        try c.encodeIfPresent(tooltip, forKey: .tooltip)
        if !visible { try c.encode(false, forKey: .visible) }
    }
}

/// `"a"` or `["a", "b"]`, both meaning a list of class names.
struct StringList: Codable {
    var values: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let one = try? c.decode(String.self) {
            values = one.split(separator: " ").map(String.init)
        } else {
            values = try c.decode([String].self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }
}
