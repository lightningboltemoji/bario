import AppKit

/// One cover window, pinned over one display's menu bar: the surface a bar's frames land on.
/// Identical in every window-server respect to the probe's, because that part is already right.
@MainActor
public final class BarCover: BarSurface {
    public let displayID: CGDirectDisplayID
    public let name: String
    public let window: NSWindow
    public let view: BarView
    public var lastSource: String?
    /// Asked to hold still while Spaces slide, `position "fixed"`. A cover is fixed or not from
    /// the start, and one that should change is replaced.
    public let fixed: Bool
    private let panel: CoverPanel
    private var shown = false

    public init(info: DisplayInfo, screen: NSScreen, debugTint: Bool, fixed: Bool = false) {
        displayID = info.displayID
        name = info.name
        self.fixed = fixed

        let frame = CGRect(x: info.frame.minX,
                           y: info.frame.maxY - info.stripHeight,
                           width: info.frame.width,
                           height: info.stripHeight)

        view = BarView(frame: CGRect(origin: .zero, size: frame.size))
        view.debugTint = debugTint

        // A panel that never activates bario: Option-clicking an item must not take focus from
        // the app you are in, or swap the real menu bar for bario's own.
        panel = CoverPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false, screen: screen)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        window = panel
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = true
        window.isMovable = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        // Above the menu bar (24) and above status items (25), below open menus (101).
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.placed = true
    }

    public var frame: CGRect { window.frame }

    public var hostLayer: CALayer { view.layer! }

    public func presented(_ presentation: Presentation) {
        view.presented(presentation)
    }

    public func setTakesPointer(_ takes: Bool) {
        window.ignoresMouseEvents = !takes
    }

    /// The window only comes and goes. How the bar does is its layers', which the frame loop
    /// eases from its `@starting-style` once the window is up, and to its `:leaving` style
    /// before it goes down. DESIGN.md §7.
    public func setVisible(_ visible: Bool) {
        guard visible != shown else { return }
        shown = visible
        guard visible else {
            window.orderOut(nil)
            return
        }
        // The layers were just committed at the bar's first frame on screen, but a commit made
        // inside the run loop's own transaction lands at the end of the turn, and the window
        // would show the last frame it had until then.
        CATransaction.flush()
        window.orderFrontRegardless()
        if fixed { SkyLight.fix(window) }
    }

    /// Follow the strip: where the screen now is, and how far down from its top the menu bar
    /// and the bar reach. Returns false if nothing moved. While the menu bar is hidden there is
    /// nothing to follow.
    @discardableResult
    public func fit(to screen: NSScreen, strip info: DisplayInfo) -> Bool {
        guard screen.menuBarInset > 1 else { return false }
        let target = CGRect(x: screen.frame.minX, y: screen.frame.maxY - info.stripHeight,
                            width: screen.frame.width, height: info.stripHeight)
        guard window.frame != target else { return false }
        panel.place(target)
        view.frame = CGRect(origin: .zero, size: target.size)
        return true
    }

    public func close() {
        window.orderOut(nil)
        window.close()
    }
}

/// The cover's window, which only `fit` moves. A fixed cover is in no Space AppKit knows of, so
/// when a display changes, AppKit "adjusts" it back onto the screen, halfway down; and no cover
/// needs AppKit's help to find its display, since `fit` follows the strip.
private final class CoverPanel: NSPanel {
    /// Set once the cover is made, after which only `place` moves it.
    var placed = false
    private var placing = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard !placed || placing else { return }
        super.setFrame(frameRect, display: flag)
    }

    func place(_ frame: CGRect) {
        placing = true
        defer { placing = false }
        setFrame(frame, display: false)
    }
}
