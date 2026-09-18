import QuartzCore

/// A layer's identity from one scene to the next (PLAN.md D4). The same identity in the next
/// scene is the same layer, updated in place, so neither a re-render nor a transition throws
/// pixels away.
public enum LayerID: Hashable, Sendable, CustomStringConvertible {
    /// An item, by its name. Names are unique among the items a config names; spacers, which
    /// are named by position, are told apart by occurrence.
    case item(String)
    /// A content node: its `id` if it has one, otherwise its index path within the item's
    /// content.
    case node(item: String, key: NodeKey)

    public enum NodeKey: Hashable, Sendable, CustomStringConvertible {
        case id(String)
        case path([Int])

        public var description: String {
            switch self {
            case .id(let id): return "#\(id)"
            case .path(let path): return "/" + path.map(String.init).joined(separator: "/")
            }
        }
    }

    public var description: String {
        switch self {
        case .item(let name): return name
        case .node(let item, let key): return "\(item)\(key)"
        }
    }
}

/// The layers kept for one item.
@MainActor
final class ItemRecord {
    let layer: CALayer
    let chrome = Chrome()
    let motion = Motion()
    var clip: CALayer?
    var clipMask: CAShapeLayer?

    init(layer: CALayer) { self.layer = layer }

    var layerCount: Int { 1 + chrome.layerCount + (clip == nil ? 0 : 1) }
}

/// The layers kept for one content node, and what its leaf was last drawn from.
@MainActor
final class NodeRecord {
    let layer: CALayer
    let role: LeafRole
    let chrome = Chrome()
    let motion = Motion()
    /// A raster, a tint, pixels, or a meter's track.
    var leaf: CALayer?
    /// A tint's coverage, or a meter's fill.
    var inner: CALayer?
    var key: RasterKey?
    /// How far the raster sat past the pixel grid when it was drawn, and the size of the
    /// layer that shows it.
    var drawnPhase = CGSize.zero
    var drawnSize = CGSize.zero

    init(layer: CALayer, role: LeafRole) {
        self.layer = layer
        self.role = role
    }

    var layerCount: Int { 1 + chrome.layerCount + (leaf == nil ? 0 : 1) + (inner == nil ? 0 : 1) }
}

/// Makes layers that never animate by themselves, and counts them for the commit report.
@MainActor
struct LayerFactory {
    private(set) var made = 0

    mutating func make<Layer: CALayer>(_ type: Layer.Type = CALayer.self) -> Layer {
        made += 1
        let layer = Layer()
        layer.delegate = InertLayerDelegate.shared
        return layer
    }
}

/// Every compositor layer's delegate: no implicit animations, ever. A commit's transaction
/// disables them too, but a layer that slides where it should snap is a bug nothing else
/// notices, so both.
final class InertLayerDelegate: NSObject, CALayerDelegate {
    nonisolated(unsafe) static let shared = InertLayerDelegate()

    func action(for layer: CALayer, forKey event: String) -> (any CAAction)? { NSNull() }
}

/// Set only what changed, so a commit in which one thing moved sends one thing.
@MainActor
func assign<Object: AnyObject, Value: Equatable>(_ object: Object,
                                                 _ keyPath: ReferenceWritableKeyPath<Object, Value>,
                                                 _ value: Value) {
    if object[keyPath: keyPath] != value { object[keyPath: keyPath] = value }
}

extension CALayer {
    /// Bar coordinates all the way down (PLAN.md D2): `bounds` is the scene rectangle with its
    /// origin, `position` its centre, so a sublayer takes a scene frame as it is.
    func place(_ rect: CGRect) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if bounds != rect { bounds = rect }
        if position != center { position = center }
    }

    /// A layer too faint to see is hidden, so it costs nothing to composite, unless an
    /// animation may make it visible.
    func updateOpacity(_ value: Double, animated: Bool = false) {
        let opacity = Float(value)
        if self.opacity != opacity { self.opacity = opacity }
        let hidden = value <= 0.002 && !animated
        if isHidden != hidden { isHidden = hidden }
    }

    func updateColor(_ color: CGColor?) {
        if backgroundColor != color { backgroundColor = color }
    }

    /// An image or a surface, compared by identity.
    func updateContents(_ value: AnyObject?) {
        let current = contents.map { $0 as AnyObject }
        if current !== value { contents = value }
    }

    /// Sublayers in exactly this order, touched only if they are not already.
    func updateSublayers(_ layers: [CALayer]) {
        let current = sublayers ?? []
        guard !current.elementsEqual(layers, by: ===) else { return }
        sublayers = layers.isEmpty ? nil : layers
    }
}
