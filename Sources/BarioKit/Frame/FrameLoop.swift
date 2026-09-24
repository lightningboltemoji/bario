import AppKit

/// The stages of a frame, in order. An input names the earliest one it affects, and every
/// later one is implied. DESIGN.md §10.
public enum Stage: Sendable {
    case render, style, layout, present, commit
}

/// The rendering pipeline of DESIGN.md §10, and the one rule it is built on: inputs only
/// invalidate, and a frame does all the work.
///
/// Anything that can change what a bar looks like calls `invalidate`, or sets one of the
/// inputs below, which invalidates for it. That records what is dirty and asks for a frame;
/// nothing else builds a scene, starts a transition or touches a layer. A frame renders,
/// styles, lays out, presents and commits, in that order, and asks for another only while
/// something is still moving.
@MainActor
public final class FrameLoop {
    public let host: ModuleHost
    public let renderers: RendererHost
    public let rasters: RasterCache
    /// Pairs of IOSurfaces native processes draw into, for `{"surface": …}` sources.
    public let surfaces: SharedSurfaces
    public let metrics: any Metrics
    private let scheduler: any FrameScheduler
    private let clock: () -> CFTimeInterval

    // MARK: - Style inputs

    public var config = Config() {
        didSet {
            guard config != oldValue else { return }
            for bar in bars { bar.config = config.bar(for: bar.display) }
            modeTracker.configure(config.modes, store: host.store)
            invalidate(.style)
        }
    }

    /// The modes that are on. One turning on or off restyles every bar.
    public var modes: Set<String> { modeTracker.active }
    let modeTracker: ModeTracker

    public var stylesheet = Stylesheet() {
        didSet { invalidate(.style) }
    }

    /// `style` deltas pushed over the socket, layered on top of the stylesheet.
    public var liveStyle = Stylesheet() {
        didSet { invalidate(.style) }
    }

    public var dark = false {
        didSet { if dark != oldValue { invalidate(.style) } }
    }

    /// A config or stylesheet error, shown as a bubble at the start of every bar while the
    /// last good theme runs.
    public var banner: String? {
        didSet { if banner != oldValue { invalidate(.style) } }
    }

    // MARK: - Pointer inputs

    /// Where the pointer is, in screen coordinates.
    public private(set) var pointer: CGPoint?
    /// The item under the pointer, on a bar that is interactive. Otherwise nothing is hovered.
    public private(set) var hovered: ItemRef?

    /// Holding Option over a bar makes it interactive: it closes its hole and takes clicks,
    /// and its items hover. DESIGN.md §8.
    public var optionHeld = false {
        didSet {
            guard optionHeld != oldValue else { return }
            updatePointerTarget()
            // The hole closes or opens, if it is showing anywhere.
            if let pointer, isNear(pointer) { invalidate(.present) }
        }
    }

    /// The item being pressed.
    public var pressed: ItemRef? {
        didSet {
            guard pressed != oldValue else { return }
            for ref in [oldValue, pressed].compactMap({ $0 }) { invalidate(.style, bar: ref.bar) }
        }
    }

    /// The bar a click has uncovered, so the menu under it is usable, until the pointer leaves.
    public var revealed: CGDirectDisplayID? {
        didSet { if revealed != oldValue { invalidate(.present) } }
    }

    /// Every bar put away from the menu bar item, leaving the real menu bar alone. The bars keep
    /// their scenes, so showing them again is one present and no layout.
    public var hidden = false {
        didSet { if hidden != oldValue { invalidate(.present) } }
    }

    // MARK: - State

    public private(set) var bars: [Bar] = []
    /// How long a new bar waits for its first frame before it is shown anyway.
    public var revealDeadline = 1.0
    /// A backdrop for a bar whose capture has not come back by the deadline.
    public var standIn: ((Bar) -> CGImage?)?
    /// How many frames have run, for tests and for the curious.
    public private(set) var frameCount = 0
    /// Told what each frame did, for `--trace-frames`.
    public var trace: ((String) -> Void)?

    private var dirty = Dirty()
    private var framePending = false
    private var inFrame = false
    private var pointerWasNear = false
    private var resolver: ColorResolver

    public init(host: ModuleHost, renderers: RendererHost = RendererHost(),
                rasters: RasterCache = RasterCache(), surfaces: SharedSurfaces = SharedSurfaces(),
                metrics: any Metrics = CoreTextMetrics(),
                scheduler: any FrameScheduler, clock: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        self.host = host
        self.renderers = renderers
        self.rasters = rasters
        self.surfaces = surfaces
        self.metrics = metrics
        self.scheduler = scheduler
        self.clock = clock
        resolver = ColorResolver.system(dark: false)
        modeTracker = ModeTracker(after: { [scheduler] in scheduler.after($0, $1) }, now: clock)
        modeTracker.onChange = { [weak self] in self?.invalidate(.style) }

        scheduler.onFrame = { [weak self] in self?.frame() }
        host.onNeedsRender = { [weak self] in
            self?.dirty.render = true
            self?.requestFrame()
        }
        host.onRendered = { [weak self] item in self?.invalidate(.style, items: [item]) }
        // A producer's `frame` changes a layer's contents and nothing else.
        surfaces.onChange = { [weak self] _ in self?.invalidate(.commit) }
    }

    // MARK: - Invalidation

    /// Everywhere.
    public func invalidate(_ stage: Stage) {
        switch stage {
        case .render: host.markDirty(Set(host.itemNames)); return
        case .style: dirty.style.insertAll()
        case .layout: dirty.layout.insertAll()
        case .present: dirty.present = true
        case .commit: dirty.commit.insertAll()
        }
        requestFrame()
    }

    /// For the bars these items are on, or for the items themselves when rendering.
    public func invalidate(_ stage: Stage, items: Set<String>) {
        guard stage != .render else {
            host.markDirty(items)
            return
        }
        for bar in bars where items.contains(where: bar.contains) {
            invalidate(stage, bar: bar.id)
        }
    }

    /// For one bar.
    public func invalidate(_ stage: Stage, bar id: CGDirectDisplayID) {
        switch stage {
        case .render:
            host.markDirty(Set(bars.first { $0.id == id }?.moduleItems ?? []))
            return
        case .style: dirty.style.insert(id)
        case .layout: dirty.layout.insert(id)
        case .present: dirty.present = true
        case .commit: dirty.commit.insert(id)
        }
        requestFrame()
    }

    /// The first invalidation in a turn schedules a frame for the end of it; the rest find one
    /// already coming. During a frame nothing is scheduled: what a frame invalidates, it
    /// schedules at its end.
    private func requestFrame() {
        guard !inFrame, !framePending else { return }
        framePending = true
        scheduler.scheduleFrame()
    }

    // MARK: - Bars

    /// A bar appears with a display. It stays off screen until its first frame.
    @discardableResult
    public func addBar(display: DisplayInfo, surface: any BarSurface, menuBarShown: Bool = true) -> Bar {
        let bar = Bar(display: display, surface: surface, menuBarShown: menuBarShown,
                      config: config.bar(for: display))
        bars.append(bar)
        scheduler.after(revealDeadline) { [weak self, weak bar] in
            // A bar that made its first frame in time has nothing to wait for.
            guard let self, let bar, !bar.isReady, self.bars.contains(where: { $0 === bar }) else { return }
            bar.deadlinePassed = true
            if bar.backdrop.image == nil, let image = self.standIn?(bar) {
                bar.backdrop.set(image)
            }
            self.invalidate(.commit, bar: bar.id)
        }
        invalidate(.style, bar: bar.id)
        return bar
    }

    public func removeBar(_ id: CGDirectDisplayID) {
        bars.removeAll { $0.id == id }
        if hovered?.bar == id { hovered = nil }
        if pressed?.bar == id { pressed = nil }
    }

    /// A display resized, or its menu bar hid or showed.
    public func updateBar(_ id: CGDirectDisplayID, display: DisplayInfo, menuBarShown: Bool) {
        guard let bar = bars.first(where: { $0.id == id }),
              bar.display != display || bar.menuBarShown != menuBarShown else { return }
        bar.display = display
        bar.menuBarShown = menuBarShown
        let config = config.bar(for: display)
        if config != bar.config {
            bar.config = config
            invalidate(.style, bar: id)
        } else {
            invalidate(.layout, bar: id)
        }
    }

    /// A new photograph of the desktop behind a bar. One identical to the last is not new, and
    /// returns false.
    @discardableResult
    public func setBackdrop(_ image: CGImage?, for id: CGDirectDisplayID) -> Bool {
        guard let bar = bars.first(where: { $0.id == id }), bar.backdrop.set(image) else { return false }
        invalidate(.commit, bar: id)
        return true
    }

    /// The window shadows falling into one bar. A field that has not moved is not new, and
    /// returns false.
    @discardableResult
    public func setShadows(_ field: ShadowField, for id: CGDirectDisplayID) -> Bool {
        guard let bar = bars.first(where: { $0.id == id }), bar.shadows != field else { return false }
        bar.shadows = field
        invalidate(.commit, bar: id)
        return true
    }

    // MARK: - The pointer

    public func pointerMoved(to point: CGPoint) {
        pointer = point
        if let id = revealed, !bars.contains(where: { $0.id == id && isNear(point, bar: $0) }) {
            revealed = nil
        }
        updatePointerTarget()
        // A pointer nowhere near any bar changes nothing on screen, however much it moves.
        let near = isNear(point)
        if near || pointerWasNear { invalidate(.present) }
        pointerWasNear = near
    }

    /// Whether the hole would show on any bar with the pointer here.
    public func isNear(_ point: CGPoint) -> Bool {
        bars.contains { isNear(point, bar: $0) }
    }

    private func isNear(_ point: CGPoint, bar: Bar) -> Bool {
        guard bar.isVisible, let hole = bar.config?.hole else { return false }
        return Lens.proximity(of: point, to: bar.surface.frame, reach: hole.proximity) > Lens.settled
    }

    /// The item on screen at a point, which is what the pointer is over: hit testing reads
    /// what is presented, not what is heading there.
    public func item(at point: CGPoint) -> (bar: Bar, item: SceneItem)? {
        for bar in bars where bar.isVisible && bar.surface.frame.contains(point) {
            let frame = bar.surface.frame
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            guard let item = bar.presentation?.scene.item(at: local) else { continue }
            return (bar, item)
        }
        return nil
    }

    /// Which bar is interactive, and which item on it is hovered. Asked when the pointer moves
    /// or Option changes, and again after each frame, since an item can slide under a pointer
    /// that is standing still.
    private func updatePointerTarget() {
        for bar in bars {
            let interactive = optionHeld && bar.isVisible
                && pointer.map { bar.surface.frame.contains($0) } == true
            guard interactive != bar.isInteractive else { continue }
            bar.isInteractive = interactive
            bar.surface.setTakesPointer(interactive)
        }

        let next = pointer.flatMap { item(at: $0) }
            .flatMap { $0.bar.isInteractive ? ItemRef(bar: $0.bar.id, item: $0.item.name) : nil }
        guard next != hovered else { return }
        let previous = hovered
        hovered = next
        for ref in [previous, next].compactMap({ $0 }) { invalidate(.style, bar: ref.bar) }
    }

    // MARK: - The frame

    public func frame() {
        let now = clock()
        let started = trace == nil ? 0 : CACurrentMediaTime()
        framePending = false
        inFrame = true
        frameCount += 1
        let dirty = self.dirty
        self.dirty = Dirty()

        // 1. Render. Never waited on: each render reports back when it finishes.
        host.startRenders()

        // 2. Style and lay out whatever is dirty.
        let laidOut = styleAndLayout(dirty, at: now)

        // 3 and 4. Present every bar at this timestamp, and commit the ones that changed. A
        // renderer that asked for a frame while it drew is drawn again in the next one, at the
        // display's rate, for as long as it keeps asking: its bar is committed again, and not
        // laid out.
        var committed: [CommitReport] = []
        var drawing = false
        for bar in bars {
            let sceneChanged = laidOut.contains(bar.id) || dirty.commit.contains(bar.id)
            guard let report = present(bar, sceneChanged: sceneChanged, at: now) else { continue }
            committed.append(report)
            if report.wantsFrame {
                self.dirty.commit.insert(bar.id)
                drawing = true
            }
        }
        updatePointerTarget()
        inFrame = false

        // 5. Continue or stop. Whatever this frame invalidated itself — a renderer asking to be
        // drawn again, hover changing under a pointer standing still — waits for the next
        // refresh, so no frame can feed the next one faster than the display shows them.
        let next: String
        if drawing || bars.contains(where: \.moving) || !self.dirty.isEmpty {
            framePending = true
            scheduler.scheduleRefresh()
            next = "refresh"
        } else {
            next = "idle"
        }
        trace?(String(format: "frame %d at %.3f: %@laid out %d, committed %d of %d%@ in %.2fms → %@",
                      frameCount, now, dirty.summary, laidOut.count, committed.count, bars.count,
                      committed.isEmpty ? "" : " (" + committed.map(\.description).joined(separator: "; ") + ")",
                      (CACurrentMediaTime() - started) * 1000, next))
    }

    /// Returns the bars that were laid out.
    private func styleAndLayout(_ dirty: Dirty, at now: CFTimeInterval) -> Set<CGDirectDisplayID> {
        let bars = self.bars.filter {
            $0.styled == nil || dirty.style.contains($0.id) || dirty.layout.contains($0.id)
        }
        guard !bars.isEmpty else { return [] }

        if !dirty.style.isEmpty { resolver = ColorResolver.system(dark: dark) }
        let styler = Styler(cascade: Cascade(stylesheet: stylesheet.appending(liveStyle), dark: dark))
        let layout = BarLayout(metrics: metrics, renderers: renderers, rasters: rasters,
                               resolver: resolver)
        var states = host.states
        let banner = self.banner.map(FrameLoop.bannerItem)
        if let banner { states[banner.config.name] = banner.state }

        var laidOut: Set<CGDirectDisplayID> = []
        for bar in bars {
            guard let config = bar.config else {
                bar.reset()
                continue
            }
            if bar.styled == nil || dirty.style.contains(bar.id) {
                let interaction = Styler.Interaction(
                    hovered: hovered?.bar == bar.id ? hovered?.item : nil,
                    active: pressed?.bar == bar.id ? pressed?.item : nil)
                bar.styled = styler.style(bar: config, items: (banner.map { [$0.config] } ?? []) + config.items,
                                          states: states, interaction: interaction, modes: modes)
            }
            guard let styled = bar.styled else { continue }

            let scene = layout.layout(styled, on: bar.display)

            // A bar that is not on screen has nothing on screen to ease from.
            bar.animator.retarget(scene, at: now, animated: bar.isVisible)
            laidOut.insert(bar.id)
        }
        return laidOut
    }

    /// Returns what the commit did, if the bar was committed.
    @discardableResult
    private func present(_ bar: Bar, sceneChanged: Bool, at now: CFTimeInterval) -> CommitReport? {
        guard let config = bar.config, let scene = bar.animator.presented(at: now) else {
            setVisible(bar, false)
            return nil
        }
        let (hole, reveal) = bar.lens.present(pointer: pointer, frame: bar.surface.frame,
                                              config: config.hole, latched: revealed == bar.id,
                                              closed: optionHeld, at: now)
        let presentation = Presentation(scene: scene, hole: hole, reveal: reveal,
                                        isMoving: bar.animator.isMoving(at: now))

        // The scene only differs from the one committed last if it was laid out again, was
        // commit-dirty, or was still moving then (PLAN.md D3); the hole is compared directly.
        let sceneChanged = sceneChanged || bar.moving
        let changed = sceneChanged || !(bar.presentation.map { $0.looksLike(presentation) } ?? false)
        bar.moving = bar.animator.isMoving(at: now) || bar.lens.isMoving(at: now)
        var report: CommitReport?
        if changed {
            report = bar.compositor.commit(presentation,
                                           inputs: Compositor.Inputs(backdrop: bar.backdrop,
                                                                     shadows: bar.shadows,
                                                                     resolver: resolver,
                                                                     scale: bar.display.scale,
                                                                     renderers: renderers,
                                                                     rasters: rasters,
                                                                     surfaces: surfaces),
                                           sceneChanged: sceneChanged)
            bar.lastCommit = report
            bar.presentation = presentation
            bar.surface.presented(presentation)
        }

        // The first frame worth showing: every item has rendered once, however that went,
        // and there is a photograph to show them on. Or the deadline, with what there is.
        if !bar.isReady, bar.deadlinePassed || (bar.backdrop.image != nil && hasRendered(bar)) {
            bar.isReady = true
        }
        setVisible(bar, bar.isReady && bar.menuBarShown && !hidden)
        return report
    }

    private func hasRendered(_ bar: Bar) -> Bool {
        bar.moduleItems.allSatisfy { host.state(for: $0)?.rendered == true }
    }

    private func setVisible(_ bar: Bar, _ visible: Bool) {
        guard visible != bar.isVisible else { return }
        bar.isVisible = visible
        bar.surface.setVisible(visible)
    }

    /// The error bubble is an ordinary item: it cascades, lays out and commits like the rest,
    /// so `item.error` in the stylesheet is all that styles it.
    static func bannerItem(_ message: String) -> (config: ItemConfig, state: ModuleHost.ItemState) {
        var config = ItemConfig(name: "bario-error", kind: .module("text"))
        config.priority = 1_000
        let result = RenderResult(content: .row(gap: 4, align: .center, [
            .icon("exclamationmark.triangle.fill", classes: ["icon"]),
            .text(message, classes: ["message"]),
        ]), classes: ["error"], tooltip: message)
        return (config, ModuleHost.ItemState(result: result, rendered: true))
    }
}

/// What the next frame has to do, by stage and by bar.
struct Dirty {
    var render = false
    var style = BarSet()
    var layout = BarSet()
    var present = false
    var commit = BarSet()

    var isEmpty: Bool {
        !render && style.isEmpty && layout.isEmpty && !present && commit.isEmpty
    }

    /// The dirty stages, earliest first, for a trace.
    var summary: String {
        [(render, "render"), (!style.isEmpty, "style"), (!layout.isEmpty, "layout"),
         (present, "present"), (!commit.isEmpty, "commit")]
            .filter(\.0).map { $0.1 + " " }.joined()
    }
}

/// Some bars, or all of them, including ones that do not exist yet.
struct BarSet {
    private var all = false
    private var ids: Set<CGDirectDisplayID> = []

    var isEmpty: Bool { !all && ids.isEmpty }

    mutating func insertAll() { all = true }
    mutating func insert(_ id: CGDirectDisplayID) { ids.insert(id) }
    func contains(_ id: CGDirectDisplayID) -> Bool { all || ids.contains(id) }
}
