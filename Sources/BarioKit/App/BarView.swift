import AppKit

/// The view that hosts one bar's layer tree. It never draws: the bar's compositor keeps the
/// tree up to date, and the window server composites it. It keeps the last presentation a
/// frame committed, which is what the pointer is over. DESIGN.md §10.
@MainActor
public final class BarView: NSView {
    public private(set) var presentation: Presentation?
    private var tint: CALayer?

    /// Where pointer events go. Set by the controller.
    public var onEvent: (@MainActor (BarEvent) -> Void)?
    /// The item a press went down on, and nil when it comes up: `:active`.
    public var onPress: (@MainActor (String?) -> Void)?
    /// The pointer moved over the bar while the window was taking events. The global
    /// monitor sees none of those moves, so they come from here.
    public var onPointer: (@MainActor () -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting: the layer is set before `wantsLayer`, so AppKit leaves its contents
        // and sublayers alone and never asks the view to draw.
        let host = CALayer()
        host.delegate = InertLayerDelegate.shared
        host.anchorPoint = .zero
        host.frame = CGRect(origin: .zero, size: frame.size)
        layer = host
        wantsLayer = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("BarView is made in code") }

    public override var isOpaque: Bool { false }

    /// `--debug-tint`: a translucent red over the whole cover, above the bar.
    public var debugTint = false {
        didSet {
            guard debugTint != oldValue, let host = layer else { return }
            if debugTint {
                let tint = CALayer()
                tint.delegate = InertLayerDelegate.shared
                tint.backgroundColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
                tint.zPosition = 1
                tint.frame = host.bounds
                host.addSublayer(tint)
                self.tint = tint
            } else {
                tint?.removeFromSuperlayer()
                tint = nil
            }
        }
    }

    public func presented(_ presentation: Presentation) {
        self.presentation = presentation
    }

    /// Follow the view's size. A hosted layer's geometry is the host's to keep.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.frame = CGRect(origin: .zero, size: newSize)
        tint?.frame = CGRect(origin: .zero, size: newSize)
        CATransaction.commit()
    }

    // MARK: - Pointer

    public override var acceptsFirstResponder: Bool { true }

    /// bario never becomes the active app, so moves only arrive through an always-active
    /// tracking area.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    public override func mouseMoved(with event: NSEvent) { onPointer?() }
    public override func mouseEntered(with event: NSEvent) { onPointer?() }
    public override func mouseExited(with event: NSEvent) { onPointer?() }
    public override func mouseDragged(with event: NSEvent) { onPointer?() }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The item on screen under a point in the view.
    public func item(at point: CGPoint) -> SceneItem? {
        presentation?.scene.item(at: point)
    }

    private func event(_ kind: BarEvent.Kind, _ nsEvent: NSEvent, delta: CGPoint = .zero) -> BarEvent {
        let point = convert(nsEvent.locationInWindow, from: nil)
        let item = item(at: point)
        let local = item.map { CGPoint(x: point.x - $0.frame.minX, y: point.y - $0.frame.minY) } ?? point
        return BarEvent(kind: kind, item: item?.name, point: point, local: local, delta: delta,
                        modifiers: UInt(nsEvent.modifierFlags.rawValue))
    }

    public override func mouseDown(with nsEvent: NSEvent) {
        let event = event(.click, nsEvent)
        onPress?(event.item)
        onEvent?(event)
    }

    public override func mouseUp(with nsEvent: NSEvent) {
        onPress?(nil)
    }

    public override func rightMouseDown(with nsEvent: NSEvent) {
        onEvent?(event(.rightClick, nsEvent))
    }

    public override func scrollWheel(with nsEvent: NSEvent) {
        onEvent?(event(.scroll, nsEvent,
                       delta: CGPoint(x: nsEvent.scrollingDeltaX, y: nsEvent.scrollingDeltaY)))
    }
}
