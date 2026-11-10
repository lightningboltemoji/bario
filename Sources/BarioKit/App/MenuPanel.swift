import AppKit

/// One open menu's window: a panel that never activates bario, at pop-up-menu level
/// over the bars, a little larger than the menu's panel so its shadow is not cut. It hosts the
/// menu's layer tree, and under it, while the panel's background is `glass`, the system's Liquid
/// Glass following the panel's box, radius and opacity.
@MainActor
public final class MenuPanel: MenuSurface {
    public let window: NSPanel
    public let view: MenuView
    private let container: NSView
    private var glass: NSGlassEffectView?
    private var shown = false
    /// A root menu's window is key while it is open; a submenu's never is, so the keys reach one
    /// place and a click in a submenu does not take key status from the root, which would close
    /// it.
    private let takesKeys: Bool

    /// The window stopped being key: another app came forward, or another menu opened.
    public var onResignKey: (@MainActor () -> Void)?
    private var resignObserver: NSObjectProtocol?

    public init(screen: NSScreen?, takesKeys: Bool = true) {
        let frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        container = NSView(frame: frame)
        container.wantsLayer = true
        view = MenuView(frame: frame)
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        self.takesKeys = takesKeys

        // Key while it is open, so Escape and the arrow keys reach it, but never active: the app
        // you were in keeps its menu bar, as it does under the system's own menus.
        let panel: NSPanel = takesKeys
            ? KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false, screen: screen)
            : NeverKeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false, screen: screen)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = container
        window = panel

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResignKey?() }
        }
    }

    public var frame: CGRect { window.frame }

    public var hostLayer: CALayer { view.layer! }

    public func place(_ frame: CGRect) {
        window.setFrame(frame, display: false)
        container.frame = CGRect(origin: .zero, size: frame.size)
    }

    public func presented(_ presentation: Presentation) {
        view.presentation = presentation
        followGlass(presentation)
    }

    public func setVisible(_ visible: Bool) {
        guard visible != shown else { return }
        shown = visible
        guard visible else {
            window.orderOut(nil)
            return
        }
        // The layers were committed at this frame; without a flush the window would come up
        // showing nothing until the end of the turn.
        CATransaction.flush()
        window.orderFrontRegardless()
        guard takesKeys else { return }
        window.makeKey()
        // The view hears the keys, not the window, which would beep at them.
        window.makeFirstResponder(view)
    }

    public func setTakesPointer(_ takes: Bool) {
        window.ignoresMouseEvents = !takes
    }

    public func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        onResignKey = nil
        window.orderOut(nil)
        window.close()
    }

    /// Glass is a view, not a layer, so it follows the panel from the outside: its box, its
    /// top-left radius, its opacity and its slide. The panel's own chrome draws nothing for it,
    /// with no photograph to blur, and its shadow and border sit over it.
    private func followGlass(_ presentation: Presentation) {
        guard let item = presentation.scene.items.first, case .glass(let spec) = item.style.background else {
            glass?.removeFromSuperview()
            glass = nil
            return
        }
        let effect = glass ?? {
            let effect = NSGlassEffectView(frame: .zero)
            container.addSubview(effect, positioned: .below, relativeTo: view)
            glass = effect
            return effect
        }()
        let scene = presentation.scene.style
        let box = item.style.margin.inset(item.frame)
            // CSS's y runs down; the view's runs up.
            .offsetBy(dx: scene.transform.translateX, dy: -scene.transform.translateY)
        if effect.frame != box { effect.frame = box }
        let radius = CGFloat(item.style.borderRadius.topLeft)
        if effect.cornerRadius != radius { effect.cornerRadius = radius }
        let style: NSGlassEffectView.Style = spec.clear ? .clear : .regular
        if effect.style != style { effect.style = style }
        let tint = spec.tint.map { ColorResolver.system(dark: isDark).resolve($0) }
        effect.tintColor = tint.flatMap { $0.a > 0.001 ? NSColor(cgColor: $0.cgColor) : nil }
        let alpha = CGFloat(scene.opacity * item.style.opacity)
        if effect.alphaValue != alpha { effect.alphaValue = alpha }
    }

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// A non-activating panel that can still be key, so a menu hears Escape.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A submenu's: it takes clicks, and leaves the keys with its root's window.
private final class NeverKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The view that hosts one menu's layer tree, and hears the pointer and the keys over it. It
/// never draws; what it hears goes to the controller in screen coordinates, since a menu's
/// window reaches over the bar it hangs from and a click there may be the bar's.
@MainActor
public final class MenuView: NSView {
    public enum Mouse: Equatable {
        case down, drag, up, rightDown
        case scroll(dx: Double, dy: Double)
    }

    public var presentation: Presentation?
    /// A press, drag, release or scroll, at a point on screen.
    public var onMouse: (@MainActor (Mouse, CGPoint) -> Void)?
    /// The pointer moved over the menu.
    public var onPointer: (@MainActor () -> Void)?
    /// A key that means something to a menu: `escape`, `up`, `down`, `left`, `right`, `return`.
    public var onKey: (@MainActor (String) -> Void)?
    /// The modifier keys changed while the menu had the keys.
    public var onModifiers: (@MainActor (NSEvent.ModifierFlags) -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        let host = CALayer()
        host.delegate = InertLayerDelegate.shared
        host.anchorPoint = .zero
        host.frame = CGRect(origin: .zero, size: frame.size)
        layer = host
        wantsLayer = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("MenuView is made in code") }

    public override var isOpaque: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = CGRect(origin: .zero, size: newSize)
        CATransaction.commit()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func screenPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    public override func mouseMoved(with event: NSEvent) { onPointer?() }
    public override func mouseEntered(with event: NSEvent) { onPointer?() }
    public override func mouseExited(with event: NSEvent) { onPointer?() }
    public override func mouseDown(with event: NSEvent) { onMouse?(.down, screenPoint(event)) }
    public override func mouseUp(with event: NSEvent) { onMouse?(.up, screenPoint(event)) }
    public override func rightMouseDown(with event: NSEvent) { onMouse?(.rightDown, screenPoint(event)) }

    public override func mouseDragged(with event: NSEvent) {
        onPointer?()
        onMouse?(.drag, screenPoint(event))
    }

    public override func scrollWheel(with event: NSEvent) {
        onMouse?(.scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY), screenPoint(event))
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onKey?("escape")
        case 126: onKey?("up")
        case 125: onKey?("down")
        case 123: onKey?("left")
        case 124: onKey?("right")
        case 36, 76, 49: onKey?("return")
        default: super.keyDown(with: event)
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        onModifiers?(event.modifierFlags)
        super.flagsChanged(with: event)
    }

    public override func cancelOperation(_ sender: Any?) { onKey?("escape") }
}
