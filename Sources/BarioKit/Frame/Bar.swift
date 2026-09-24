import AppKit

/// Where a bar's frames end up: a window on a display, or a recording in a test. A surface only
/// hosts the bar's layer tree; the bar's compositor owns it (PLAN.md D1).
@MainActor
public protocol BarSurface: AnyObject {
    /// The bar's rectangle in screen coordinates, which the pointer and the hole are measured
    /// against.
    var frame: CGRect { get }
    /// The layer the compositor hangs the bar's tree from.
    var hostLayer: CALayer { get }
    /// What was committed last, which is what hit testing reads.
    func presented(_ presentation: Presentation)
    /// Put the bar on screen or take it off. Only a frame calls this.
    func setVisible(_ visible: Bool)
    /// Whether pointer events land on the bar or fall through to the real menu bar.
    func setTakesPointer(_ takes: Bool)
}

/// One bar's part of the pipeline: what it is laid out on, what each stage last produced for
/// it, and whether it has earned a place on screen. DESIGN.md §10.
@MainActor
public final class Bar {
    public let id: CGDirectDisplayID
    public let surface: any BarSurface
    /// The bar's layer tree, and the commit stage that keeps it up to date.
    public let compositor: Compositor
    /// The photograph behind the bar. A new one invalidates commit.
    public let backdrop = BackdropImage()
    /// The window shadows falling into the bar, which the photograph can never hold: they are
    /// cast onto it instead. A field that moved invalidates commit.
    public internal(set) var shadows = ShadowField.empty

    public internal(set) var display: DisplayInfo
    /// Whether the system's menu bar is showing on this display. A full screen app or an
    /// auto-hidden menu bar takes the bar off screen with it.
    public internal(set) var menuBarShown: Bool
    /// The config's bar for this display, if any matches.
    public internal(set) var config: BarConfig?

    /// The style stage's last output.
    var styled: StyledBar?
    /// The layout stage's last output, and the transitions easing toward it.
    var animator = Animator()
    var lens = Lens()
    /// What was committed last.
    public internal(set) var presentation: Presentation?
    /// What the last commit did.
    public internal(set) var lastCommit: CommitReport?
    /// Whether anything was still moving at the last frame, so the next one has to commit the
    /// scene again.
    var moving = false
    /// What has been said about items too tall for the bar, so each is said once.
    var squeezeWarnings: Set<String> = []

    /// Set once the bar has had a frame worth showing, or waited long enough.
    public internal(set) var isReady = false
    public internal(set) var isVisible = false
    /// Option is held with the pointer over this bar: it takes clicks, its items hover, and
    /// its hole is closed. The rest of the time it ignores the pointer, but for the hole.
    public internal(set) var isInteractive = false
    var deadlinePassed = false

    init(display: DisplayInfo, surface: any BarSurface, menuBarShown: Bool, config: BarConfig?) {
        id = display.displayID
        self.display = display
        self.surface = surface
        compositor = Compositor(host: surface.hostLayer)
        self.menuBarShown = menuBarShown
        self.config = config
    }

    /// The part of the bar over the real menu bar, in screen coordinates. A bar taller than the
    /// menu bar hangs past it, over whatever is below.
    public var menuBarFrame: CGRect {
        let frame = surface.frame
        let height = min(frame.height, display.menuBarHeight)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    /// Every item on this bar that a module renders: what its first frame waits for.
    var moduleItems: [String] {
        (config?.items ?? []).flatMap(\.flattened).compactMap { $0.moduleName == nil ? nil : $0.name }
    }

    func contains(_ item: String) -> Bool {
        (config?.items ?? []).contains { $0.flattened.contains { $0.name == item } }
    }

    /// Forget every stage's output, for a bar that no longer has a config to show.
    func reset() {
        styled = nil
        animator = Animator()
        presentation = nil
        moving = false
    }
}

/// An item on one particular bar. Two displays can show items of the same name, and hovering
/// one must not light up the other.
public struct ItemRef: Hashable, Sendable {
    public var bar: CGDirectDisplayID
    public var item: String

    public init(bar: CGDirectDisplayID, item: String) {
        self.bar = bar
        self.item = item
    }
}
