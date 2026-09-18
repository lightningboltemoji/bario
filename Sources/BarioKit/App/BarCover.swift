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
    private var shown = false

    public init(info: DisplayInfo, screen: NSScreen, debugTint: Bool) {
        displayID = info.displayID
        name = info.name

        let frame = CGRect(x: info.frame.minX,
                           y: info.frame.maxY - info.stripHeight,
                           width: info.frame.width,
                           height: info.stripHeight)

        view = BarView(frame: CGRect(origin: .zero, size: frame.size))
        view.debugTint = debugTint

        // A panel that never activates bario: Option-clicking an item must not take focus from
        // the app you are in, or swap the real menu bar for bario's own.
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
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
    }

    public var frame: CGRect { window.frame }

    public var hostLayer: CALayer { view.layer! }

    public func presented(_ presentation: Presentation) {
        view.presented(presentation)
    }

    public func setTakesPointer(_ takes: Bool) {
        window.ignoresMouseEvents = !takes
    }

    public func setVisible(_ visible: Bool) {
        guard visible != shown else { return }
        shown = visible
        guard visible else {
            window.orderOut(nil)
            return
        }
        // A short cross-fade with the real menu bar underneath, rather than a pop.
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }
    }

    /// Follow the screen's menu bar: its height, and where the screen now is. Returns false if
    /// nothing moved. While the menu bar is hidden there is nothing to follow.
    @discardableResult
    public func fit(to screen: NSScreen) -> Bool {
        let inset = screen.menuBarInset
        guard inset > 1 else { return false }
        let target = CGRect(x: screen.frame.minX, y: screen.frame.maxY - inset,
                            width: screen.frame.width, height: inset)
        guard window.frame != target else { return false }
        window.setFrame(target, display: false)
        view.frame = CGRect(origin: .zero, size: target.size)
        return true
    }

    public func close() {
        window.orderOut(nil)
        window.close()
    }
}
