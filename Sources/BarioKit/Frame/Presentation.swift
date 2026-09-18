import CoreGraphics

/// Where the hole is and how strongly it cuts, in the bar's coordinates. A present-stage value:
/// the lens eases it, and commit makes it the bar's mask. DESIGN.md §8, §10.
public struct Hole: Sendable, Equatable {
    public var center: CGPoint
    public var radius: Double
    public var feather: Double
    public var strength: Double

    public init(center: CGPoint = CGPoint(x: -10_000, y: -10_000), radius: Double = 40,
                feather: Double = 0, strength: Double = 0) {
        self.center = center
        self.radius = radius
        self.feather = feather
        self.strength = strength
    }

    public var isVisible: Bool { strength > 0.002 && radius > 0 }
}

/// One bar as it should look at one instant: the present stage's output, and what commit
/// brings the bar's layer tree up to. DESIGN.md §10.
public struct Presentation: Sendable {
    public var scene: Scene
    public var hole: Hole
    /// The click reveal: 1 uncovers everything so the real menu is usable.
    public var reveal: Double
    /// Whether the scene is mid-transition. Content that is moving keeps the pixels it has; a
    /// scene at rest has its rasters on the display's pixel grid.
    public var isMoving: Bool

    public init(scene: Scene, hole: Hole = Hole(), reveal: Double = 0, isMoving: Bool = false) {
        self.scene = scene
        self.hole = hole
        self.reveal = reveal
        self.isMoving = isMoving
    }

    /// Whether committing `other` would put the same pixels on screen, given that the scene
    /// underneath has not moved. A hole that is not visible is the same wherever it is.
    func looksLike(_ other: Presentation) -> Bool {
        guard reveal == other.reveal else { return false }
        if !hole.isVisible && !other.hole.isVisible { return true }
        return hole == other.hole
    }
}
