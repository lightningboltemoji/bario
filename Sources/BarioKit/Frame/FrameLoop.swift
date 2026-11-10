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
    /// and its items hover. A bar with `option "reveal"` is the other way round. DESIGN.md §8.
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
        didSet {
            guard revealed != oldValue else { return }
            updatePointerTarget()
            invalidate(.present)
        }
    }

    /// Every bar put away from the menu bar item, leaving the real menu bar alone. The bars keep
    /// their scenes, so showing them again is one present and no layout.
    public var hidden = false {
        didSet { if hidden != oldValue { invalidate(.present) } }
    }

    /// Whether macOS keeps the menu bar over full screen apps, so they leave its strip clear on
    /// every display and not only beside a notch: what `fullscreen "if-room"` decides from.
    /// DESIGN.md §6.
    public var menuBarStaysInFullscreen = false {
        didSet { if menuBarStaysInFullscreen != oldValue { invalidate(.present) } }
    }

    // MARK: - State

    public private(set) var bars: [Bar] = []

    // MARK: - Menus

    /// The menu that is open, if any. One at a time, as the menu bar's own.
    public private(set) var menu: Menu?
    /// The submenus open below it, one per level, each hanging from a row of the one before
    ///. They close with it.
    public private(set) var submenus: [Menu] = []
    /// The root and its submenus, outermost first.
    public var openMenus: [Menu] { (menu.map { [$0] } ?? []) + submenus }
    /// Menus on their way out, easing to their `:leaving` style before their windows go.
    public private(set) var closingMenus: [Menu] = []
    /// A menu asked for and not rendered yet: it opens once its first render has something in
    /// it, in place of the one that is open, and never if it has nothing. One asked
    /// for by a click that turns out to have nothing closes the open menu, as a click outside it
    /// would; one the pointer moving onto an item asked for leaves it be.
    public private(set) var pendingMenu: (item: String, anchor: ItemRef, hovering: Bool)?
    /// Makes the window a menu is shown in, on a display. The controller's makes a panel; a
    /// test's records.
    public var makeMenuSurface: ((DisplayInfo) -> any MenuSurface)?
    /// Makes a submenu's window, which never takes the keys from the root's. Without it, a
    /// submenu's is made as a menu's.
    public var makeSubmenuSurface: ((DisplayInfo) -> any MenuSurface)?
    /// The pointer before its last move, which says where it is heading.
    private var previousPointer: CGPoint?
    /// It has moved since the open menus last looked at it.
    private var pointerMovedSinceHover = false
    /// Heading for an open submenu across its parent's other rows: they wait for the pointer to
    /// stop before taking the hover, and the token is the wait that counts.
    private var aimPending = false
    private var aimToken = 0
    /// How long a pointer that stopped on its way to a submenu waits before the row under it
    /// takes over.
    static let aimDelay = 0.25

    /// How long a new bar waits for its first frame before it is shown anyway.
    public var revealDeadline = 1.0
    /// A backdrop for a bar whose capture has not come back by the deadline.
    public var standIn: ((Bar) -> CGImage?)?
    /// How many frames have run, for tests and for the curious.
    public private(set) var frameCount = 0
    /// Told what each frame did, for `--trace-frames`.
    public var trace: ((String) -> Void)?

    private var dirty = Dirty()
    /// The last write of the palettes to the store, which the next one waits for.
    private var publishing: Task<Void, Never>?
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
        // At the next refresh rather than the end of this turn: renders that finish within a
        // refresh of each other, as every item on the same `Tick` does, are styled in one
        // frame and not one each. Nothing waits for a render that is still running.
        host.onRendered = { [weak self] item in self?.rendered(item) }
        host.onMenuRendered = { [weak self] item in self?.menuRendered(item) }
        // A producer's `frame` changes a layer's contents and nothing else.
        surfaces.onChange = { [weak self] _ in self?.invalidate(.commit) }
    }

    // MARK: - Invalidation

    /// Everywhere.
    public func invalidate(_ stage: Stage) {
        switch stage {
        case .render: host.markDirty(Set(host.itemNames)); return
        case .style:
            dirty.style.insertAll()
            dirty.menu = true
        case .layout:
            dirty.layout.insertAll()
            dirty.menu = true
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
        // A menu is styled from its bar's palette and modes, and hangs from its bar.
        if stage == .style || stage == .layout, menu?.anchor.bar == id { dirty.menu = true }
        requestFrame()
    }

    /// The first invalidation in a turn schedules a frame for the end of it; the rest find one
    /// already coming. During a frame nothing is scheduled: what a frame invalidates, it
    /// schedules at its end.
    private func requestFrame(atRefresh: Bool = false) {
        guard !inFrame, !framePending else { return }
        framePending = true
        if atRefresh { scheduler.scheduleRefresh() } else { scheduler.scheduleFrame() }
    }

    /// Whether renders have landed since the last frame, and wait for the next refresh to be
    /// styled. For tests, which run that refresh with the clock standing still and leave the
    /// refreshes a frame asks for itself to the clock.
    private(set) var rendersWaiting = false

    /// An item's render finished and it looks different.
    private func rendered(_ item: String) {
        for bar in bars where bar.contains(item) { dirty.style.insert(bar.id) }
        // A menu is selected by its item's classes: `#apple.running menu .check`.
        if let menu, menu.item == item || menu.anchor.item == item {
            menu.dirty = true
            dirty.menu = true
        }
        rendersWaiting = true
        requestFrame(atRefresh: true)
    }

    // MARK: - Bars

    /// A bar appears with a display. It stays off screen until its first frame.
    @discardableResult
    public func addBar(display: DisplayInfo, surface: any BarSurface, menuBarShown: Bool = true,
                       fullscreen: Bool = false) -> Bar {
        let bar = Bar(display: display, surface: surface, menuBarShown: menuBarShown,
                      config: config.bar(for: display))
        bar.fullscreen = fullscreen
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
        let measured = bars.contains { $0.id == id && $0.palette != nil }
        bars.removeAll { $0.id == id }
        if menu?.anchor.bar == id { closeMenu() }
        if pendingMenu?.anchor.bar == id { cancelPendingMenu() }
        if hovered?.bar == id { hovered = nil }
        if pressed?.bar == id { pressed = nil }
        if measured { publishPalettes() }
    }

    /// A display resized, its menu bar hid or showed, or a full screen app took it or gave it
    /// back. That last changes the bar's classes, so it restyles.
    public func updateBar(_ id: CGDirectDisplayID, display: DisplayInfo, menuBarShown: Bool,
                          fullscreen: Bool = false) {
        guard let bar = bars.first(where: { $0.id == id }),
              bar.display != display || bar.menuBarShown != menuBarShown
                || bar.fullscreen != fullscreen else { return }
        let restyle = bar.fullscreen != fullscreen
        bar.display = display
        bar.menuBarShown = menuBarShown
        bar.fullscreen = fullscreen
        let config = config.bar(for: display)
        if config != bar.config || restyle {
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

    // MARK: - The wallpaper

    /// A new measurement of one display's wallpaper. One identical to the
    /// last is not new, and returns false. A new one restyles that bar and no other, and goes
    /// into the store under `wallpaper`.
    @discardableResult
    public func setPalette(_ palette: Palette, for id: CGDirectDisplayID) -> Bool {
        guard let bar = bars.first(where: { $0.id == id }) else { return false }
        bar.paletteLooked = true
        guard bar.palette != palette else { return false }
        bar.palette = palette
        invalidate(.style, bar: id)
        publishPalettes()
        return true
    }

    /// A look for one display's palette found nothing to measure. The last palette stays, and a
    /// first frame stops waiting for one.
    public func foundNoPalette(for id: CGDirectDisplayID) {
        guard let bar = bars.first(where: { $0.id == id }), !bar.paletteLooked else { return }
        bar.paletteLooked = true
        invalidate(.commit, bar: id)
    }

    /// The accent changed. Made-up vibrant slots of a wallpaper with no seed took their hue
    /// from it, so those palettes choose again; the rest come out the same and change nothing.
    public func accentChanged(to accent: RGBA) {
        for bar in bars {
            if let palette = bar.palette { setPalette(palette.with(accent: accent), for: bar.id) }
        }
    }

    /// Every measured display's palette, and the primary display's again on its own.
    private func publishPalettes() {
        let measured = bars.filter { $0.palette != nil }.sorted { $0.display.frame.minX < $1.display.frame.minX }
        // The primary display is the one at the origin of the global coordinates.
        let primary = (bars.first { $0.display.frame.origin == .zero } ?? bars.first)?.id
        let entries = measured.map { bar in
            (id: bar.id, json: bar.palette!.json(display: bar.display.name, id: bar.id, primary: bar.id == primary))
        }
        var value: [String: JSONValue] = ["displays": .array(entries.map(\.json))]
        if let entry = entries.first(where: { $0.id == primary }) { value["primary"] = entry.json }
        let (store, previous) = (host.store, publishing)
        publishing = Task { [value] in
            await previous?.value
            await store.replace(.object(value), at: Palette.storeKey)
        }
    }

    /// Whether anything is coloured from the wallpaper: the stylesheet, a socket delta or an
    /// item's own `style`. Only then has a first frame a palette to wait for.
    private var wantsPalette: Bool {
        stylesheet.usesWallpaper || liveStyle.usesWallpaper
            || config.bars.flatMap(\.items).flatMap(\.flattened).contains { item in
                guard let style = item.style, let declarations = try? Stylesheet.parseDeclarations(style)
                else { return false }
                return declarations.contains { $0.value.mentions(CSSComponent.fromWallpaper) }
            }
    }

    // MARK: - The pointer

    public func pointerMoved(to point: CGPoint) {
        if point != pointer {
            for menu in openMenus { menu.hoverFromKeys = false }
            previousPointer = pointer
            pointerMovedSinceHover = true
        }
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
        guard bar.isShowing, let hole = bar.config?.hole else { return false }
        return Lens.proximity(of: point, to: bar.surface.frame, reach: hole.proximity) > Lens.settled
    }

    /// The item on screen at a point, which is what the pointer is over: hit testing reads
    /// what is presented, not what is heading there.
    public func item(at point: CGPoint) -> (bar: Bar, item: SceneItem)? {
        for bar in bars where bar.isShowing && bar.surface.frame.containsPointer(point) {
            let frame = bar.surface.frame
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            guard let item = bar.presentation?.scene.item(at: local) else { continue }
            return (bar, item)
        }
        return nil
    }

    /// Whether a bar is bario's right now rather than a lens onto the real menu bar: its hole
    /// shut, and the pointer its own while it is over it. Option held, or, on a bar whose
    /// Option reveals the real menu bar instead, Option not held; or one of its items has its
    /// menu open, as the menu bar tracks while one of its menus is.
    private func isShut(_ bar: Bar) -> Bool {
        optionHeld != (bar.config?.option == .reveal) || menu?.anchor.bar == bar.id
    }

    /// Which bar is interactive, and which item on it is hovered. Asked when the pointer moves
    /// or Option changes, and again after each frame, since an item can slide under a pointer
    /// that is standing still.
    ///
    /// A bar a click has revealed takes nothing until the pointer leaves it: it is not on
    /// screen, and the menu that click opened is. Under `option "reveal"` that is what lets
    /// Option go after the click without the bar taking back the menu bar from under the menu.
    private func updatePointerTarget() {
        for bar in bars {
            let interactive = isShut(bar) && bar.isShowing && revealed != bar.id
                && pointer.map { bar.surface.frame.containsPointer($0) } == true
            guard interactive != bar.isInteractive else { continue }
            bar.isInteractive = interactive
            bar.surface.setTakesPointer(interactive)
        }

        let next = pointer.flatMap { point in item(at: point).flatMap { hit -> ItemRef? in
            guard hit.bar.isInteractive else { return nil }
            return ItemRef(bar: hit.bar.id, item: hit.item.name, node: control(at: point, in: hit)?.path)
        } }
        updateMenuHover()
        guard next != hovered else { return }
        let previous = hovered
        hovered = next
        for ref in [previous, next].compactMap({ $0 }) { invalidate(.style, bar: ref.bar) }
        if let next, next.item != previous?.item { switchMenu(to: next) }
    }

    /// The control under a point on a bar, inside the item there.
    private func control(at point: CGPoint, in hit: (bar: Bar, item: SceneItem)) -> (path: [Int], node: SceneNode)? {
        let frame = hit.bar.surface.frame
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        return hit.item.content?.control(at: local).map { (path: $0.0, node: $0.1) }
    }

    /// What is under a point on a bar: the item, and the control in it if there is one.
    public func target(at point: CGPoint) -> (bar: Bar, item: SceneItem, control: (path: [Int], node: SceneNode)?)? {
        guard let hit = item(at: point) else { return nil }
        return (hit.bar, hit.item, control(at: point, in: hit))
    }

    // MARK: - Menus

    /// Open `item`'s menu under `anchor`, or close it if it is the one open there.
    public func toggleMenu(_ item: String, from anchor: ItemRef) {
        let anchor = anchor.bubble
        if let menu, menu.item == item, menu.anchor == anchor {
            closeMenu()
        } else {
            openMenu(item, from: anchor)
        }
    }

    /// Ask for `item`'s menu under `anchor`. It opens once it has rendered, in place of any menu
    /// that is open, if it has anything in it.
    public func openMenu(_ item: String, from anchor: ItemRef, hovering: Bool = false) {
        let anchor = anchor.bubble
        if let menu, menu.item == item, menu.anchor == anchor {
            cancelPendingMenu()
            return
        }
        if let pending = pendingMenu, pending.item == item, pending.anchor == anchor {
            pendingMenu?.hovering = pending.hovering && hovering
            return
        }
        cancelPendingMenu()
        pendingMenu = (item, anchor, hovering)
        host.openMenu(item)
        // Already rendering for the menu that is open, which hangs from somewhere else.
        if host.menuState(for: item)?.rendered == true { menuRendered(item) }
    }

    /// Close the open menu: it eases to its `:leaving` style, and its window goes once it is
    /// there. Its bar is the pointer's again, as Option says.
    public func closeMenu() {
        cancelPendingMenu()
        guard let menu else { return }
        retire(menu, rendering: false)
    }

    /// The root goes, and every submenu with it.
    private func retire(_ menu: Menu, rendering: Bool) {
        if self.menu === menu {
            retireSubmenus(from: 0)
            self.menu = nil
        }
        menu.isClosing = true
        menu.hovered = nil
        menu.pressed = nil
        menu.surface.setTakesPointer(false)
        closingMenus.append(menu)
        if !rendering { host.closeMenu(menu.item) }
        dirty.menu = true
        updatePointerTarget()
        // It no longer wears `:open`, and the bar may open its hole again.
        invalidate(.style, bar: menu.anchor.bar)
        invalidate(.present)
    }

    /// Close the submenus from `index` in `submenus` down, deepest first; the one above them no
    /// longer has a row `:open`.
    private func retireSubmenus(from index: Int) {
        guard index < submenus.count else { return }
        for submenu in submenus[index...].reversed() {
            submenu.isClosing = true
            submenu.hovered = nil
            submenu.pressed = nil
            submenu.surface.setTakesPointer(false)
            closingMenus.append(submenu)
        }
        submenus.removeSubrange(index...)
        aimPending = false
        if let parent = openMenus.last { menuChanged(parent) }
        dirty.menu = true
        requestFrame()
    }

    /// Close whatever is open below `menu`.
    private func retireSubmenus(below menu: Menu) {
        guard let index = openMenus.firstIndex(where: { $0 === menu }) else { return }
        retireSubmenus(from: index)
    }

    /// The submenu open below `menu`, if any.
    public func submenu(of menu: Menu) -> Menu? {
        guard let index = openMenus.firstIndex(where: { $0 === menu }), index < submenus.count else { return nil }
        return submenus[index]
    }

    /// Open the submenu `row` carries in `parent`, beside it, in place of whatever was open below
    /// `parent`. Its content is already there, in its parent's render, so it
    /// is laid out at the next frame.
    public func openSubmenu(from parent: Menu, row: [Int]) {
        guard !parent.isClosing, let root = menu, let index = openMenus.firstIndex(where: { $0 === parent })
        else { return }
        if index < submenus.count, submenus[index].row == row { return }
        retireSubmenus(from: index)
        guard let rowNode = content(of: parent)?.node(at: row), let nodes = rowNode.actions.submenu,
              Node.menu(nodes) != nil,
              let bar = bars.first(where: { $0.id == root.anchor.bar }),
              let make = makeSubmenuSurface ?? makeMenuSurface else { return }
        let submenu = Menu(item: root.item, anchor: root.anchor, surface: make(bar.display),
                           row: row, depth: parent.depth + 1)
        submenu.rowNode = rowNode.withoutSubmenu
        submenus.append(submenu)
        menuChanged(parent)
        menuChanged(submenu)
    }

    /// What a menu in the chain shows: the root's render, and below it the submenu each one's row
    /// carries in the one above, so a new render of the root reaches every level.
    func content(of target: Menu) -> Node? {
        guard let root = menu, let rendered = host.menuState(for: root.item)?.content else { return nil }
        var content = root.content(rendered)
        if target === root { return content }
        for submenu in submenus {
            guard let row = submenu.row, let rowNode = content.node(at: row),
                  rowNode.withoutSubmenu == submenu.rowNode,
                  let nodes = rowNode.actions.submenu, let next = Node.menu(nodes) else { return nil }
            content = submenu.content(next)
            if submenu === target { return content }
        }
        return nil
    }

    private func cancelPendingMenu() {
        guard let pending = pendingMenu else { return }
        pendingMenu = nil
        if pending.item != menu?.item { host.closeMenu(pending.item) }
    }

    /// Moving onto another item while a menu is open switches to that item's menu, if a click on
    /// it would open one, as the menu bar's own titles do.
    private func switchMenu(to ref: ItemRef) {
        guard let menu, ref.bar == menu.anchor.bar else { return }
        guard ref.item != menu.anchor.item, let item = menuItem(forClickOn: ref.item) else {
            cancelPendingMenu()
            return
        }
        openMenu(item, from: ref, hovering: true)
    }

    /// Whose menu a click on an item opens: its own when it has no `on-click`, or the one a
    /// `menu` shortcut names. nil when its click does something else.
    public func menuItem(forClickOn name: String) -> String? {
        guard let config = config.item(named: name) else { return nil }
        guard let click = config.actions.click else { return name }
        if case .menu(let other)? = Action.parse(click) { return other ?? name }
        return nil
    }

    /// An open or asked-for menu rendered. A first render with something in it opens the menu;
    /// one with nothing in it opens nothing; any other restyles the menu that is open.
    private func menuRendered(_ item: String) {
        guard let state = host.menuState(for: item) else { return }
        if let pending = pendingMenu, pending.item == item {
            pendingMenu = nil
            guard state.content != nil,
                  let bar = bars.first(where: { $0.id == pending.anchor.bar }),
                  let make = makeMenuSurface else {
                if menu?.item != item { host.closeMenu(item) }
                if !pending.hovering { closeMenu() }
                return
            }
            if let open = menu { retire(open, rendering: open.item == item) }
            menu = Menu(item: item, anchor: pending.anchor, surface: make(bar.display))
            updatePointerTarget()
            invalidate(.style, bar: bar.id)
            invalidate(.present)
        }
        guard let menu, menu.item == item else { return }
        // A drag that has let go shows what the module made of it from now on.
        if menu.dragged?.released == true { menu.dragged = nil }
        menu.dirty = true
        dirty.menu = true
        // Styled at the next refresh, with whatever else lands by then, as a bubble's render is.
        rendersWaiting = true
        requestFrame(atRefresh: true)
    }

    /// The open menu under a point, deepest first, and what in it is there. A submenu's window
    /// reaches over its parent's edge for its shadow, so where the pointer is says which menu it
    /// is in, not which window heard it. nil off every panel.
    public func menuTarget(at point: CGPoint) -> (menu: Menu, target: MenuTarget)? {
        for menu in openMenus.reversed() {
            let target = menu.target(at: point)
            if case .outside = target { continue }
            return (menu, target)
        }
        return nil
    }

    /// The control under the pointer, in whichever open menu it is over, hovers; the others let
    /// go of theirs, and a row whose submenu is open stays lit as `:open`. Hovering a row with a
    /// submenu opens it, and another control closes it, unless the pointer is on its way to it
    ///. Off every panel, what is open stays open.
    private func updateMenuHover() {
        let moved = pointerMovedSinceHover
        pointerMovedSinceHover = false
        let chain = openMenus
        guard !chain.isEmpty, !chain.contains(where: \.hoverFromKeys) else { return }
        let over = pointer.flatMap { point in
            chain.lastIndex { if case .outside = $0.target(at: point) { false } else { true } }
        }
        for (index, menu) in chain.enumerated() where index != over && menu.hovered != nil {
            menu.hovered = nil
            menuChanged(menu)
        }
        guard let over, let point = pointer else { return }
        let menu = chain[over]
        var next: [Int]?
        var opens = false
        if case .control(let path, let node) = menu.target(at: point) {
            next = path
            opens = node.actions.submenu != nil
        }
        let child = over < submenus.count ? submenus[over] : nil
        if let child, next != child.row, !child.isClosing {
            if moved, isAiming(at: child, to: point) {
                aimPending = true
                scheduleAimCheck()
                return
            }
            // Still waiting for a pointer that was on its way to stop.
            if aimPending { return }
        }
        aimPending = false
        if next != menu.hovered {
            menu.hovered = next
            menuChanged(menu)
        }
        if let next, opens {
            openSubmenu(from: menu, row: next)
        } else if next != nil, child != nil {
            retireSubmenus(from: over)
        }
    }

    /// Whether the pointer's last move kept it inside the triangle from where it was to the near
    /// corners of `submenu`'s panel: on its way there, across whatever rows lie between.
    private func isAiming(at submenu: Menu, to point: CGPoint) -> Bool {
        guard let previous = previousPointer, previous != point, let panel = submenu.panelFrame else { return false }
        let rightward = panel.midX > previous.x
        let x = rightward ? panel.minX : panel.maxX
        guard rightward ? point.x > previous.x : point.x < previous.x else { return false }
        let a = previous, b = CGPoint(x: x, y: panel.maxY), c = CGPoint(x: x, y: panel.minY)
        func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (p.x - r.x) * (q.y - r.y) - (q.x - r.x) * (p.y - r.y)
        }
        let d1 = side(point, a, b), d2 = side(point, b, c), d3 = side(point, c, a)
        let negative = d1 < 0 || d2 < 0 || d3 < 0
        let positive = d1 > 0 || d2 > 0 || d3 > 0
        return !(negative && positive)
    }

    /// A pointer that stops on its way to a submenu is not on its way any more.
    private func scheduleAimCheck() {
        aimToken += 1
        let token = aimToken
        scheduler.after(FrameLoop.aimDelay) { [weak self] in
            guard let self, self.aimToken == token, self.aimPending else { return }
            self.aimPending = false
            self.pointerMovedSinceHover = false
            self.updateMenuHover()
        }
    }

    /// The menu the arrow keys act in: the deepest with a hover, or the root.
    public var keyMenu: Menu? {
        openMenus.last { $0.hovered != nil } ?? menu
    }

    /// Move the hover to the next control, or the one before, as the arrow keys do, in the menu
    /// they act in. Whatever was open below it closes, and the control is scrolled into view.
    public func moveMenuHover(by step: Int) {
        guard let menu = keyMenu, let content = menu.presentation?.scene.items.first?.content else { return }
        var paths: [[Int]] = []
        func visit(_ node: SceneNode, _ path: [Int]) {
            if node.actions.isControl { paths.append(path) }
            for (index, child) in node.children.enumerated() { visit(child, path + [index]) }
        }
        visit(content, [])
        guard !paths.isEmpty else { return }
        let current = menu.hovered.flatMap { paths.firstIndex(of: $0) }
        let next = current.map { ($0 + step + paths.count) % paths.count } ?? (step > 0 ? 0 : paths.count - 1)
        menu.hovered = paths[next]
        menu.reveal = paths[next]
        menu.hoverFromKeys = true
        if let child = submenu(of: menu), child.row != paths[next] { retireSubmenus(below: menu) }
        menuChanged(menu)
    }

    /// → or Return on a row with a submenu: open it, and put the hover on its first control.
    /// Returns false when the hovered control has no submenu.
    @discardableResult
    public func openSubmenuFromKeys() -> Bool {
        guard let menu = keyMenu, let path = menu.hovered,
              let nodes = content(of: menu)?.node(at: path)?.actions.submenu,
              let content = Node.menu(nodes) else { return false }
        openSubmenu(from: menu, row: path)
        guard let child = submenu(of: menu) else { return false }
        menu.hoverFromKeys = true
        child.hovered = content.firstControl()
        child.reveal = child.hovered
        child.hoverFromKeys = true
        menuChanged(child)
        return true
    }

    /// ←: close the deepest submenu with the keys in it, and put the hover back on its row.
    /// Returns false in the root, which ← leaves alone.
    @discardableResult
    public func closeSubmenuFromKeys() -> Bool {
        guard let menu = keyMenu, menu.depth > 0, let index = submenus.firstIndex(where: { $0 === menu })
        else { return false }
        let parent = openMenus[index]
        retireSubmenus(from: index)
        parent.hovered = menu.row
        parent.hoverFromKeys = true
        menuChanged(parent)
        return true
    }

    /// The control a press went down on in a menu, the root by default, and nil when it comes
    /// up: `:active`.
    public func pressMenu(_ path: [Int]?, in target: Menu? = nil) {
        guard let menu = target ?? menu, menu.pressed != path else { return }
        menu.pressed = path
        menuChanged(menu)
    }

    /// A slider in a menu, the root by default, dragged, or scrolled, to `value`. It shows that
    /// value until a render after the release.
    public func dragMenu(_ path: [Int], to value: Double, in target: Menu? = nil) {
        guard let menu = target ?? menu else { return }
        menu.dragged = (path, min(1, max(0, value)), false)
        menuChanged(menu)
    }

    /// The drag let go. The slider keeps the dragged value until the next render lands.
    public func releaseMenuDrag(in target: Menu? = nil) {
        guard let menu = target ?? menu, let dragged = menu.dragged else { return }
        menu.dragged = (dragged.path, dragged.value, true)
    }

    /// The wheel over a menu taller than its room: its rows move up for a swipe up, as a page's
    /// do. Kept in range when it is laid out.
    public func scrollMenu(_ menu: Menu, by dy: Double) {
        guard dy != 0 else { return }
        menu.scroll -= CGFloat(dy)
        menuChanged(menu)
    }

    private func menuChanged(_ menu: Menu) {
        menu.dirty = true
        dirty.menu = true
        requestFrame()
    }

    /// Where the open menu hangs from and what it is, laid out again when something changed:
    /// `shown` is false when it can no longer be shown, because its item or its bar has gone, or
    /// it has nothing in it; `laidOut` says whether it was laid out again, which its submenu
    /// follows.
    private func layOut(_ menu: Menu, force: Bool, at now: CFTimeInterval) -> (shown: Bool, laidOut: Bool) {
        guard !hidden,
              let bar = bars.first(where: { $0.id == menu.anchor.bar }), bar.isShowing,
              let barConfig = bar.config,
              let scene = bar.animator.target,
              let anchorItem = scene.allItems.first(where: { $0.name == menu.anchor.item && !$0.states.contains(.leaving) }),
              let state = host.menuState(for: menu.item) else { return (false, false) }
        guard let content = state.content else { return (!state.rendered && menu.layout != nil, false) }
        let frame = bar.surface.frame
        let anchor = anchorItem.frame.offsetBy(dx: frame.minX, dy: frame.minY)
        guard force || menu.dirty || menu.layout == nil || menu.anchorFrame != anchor else { return (true, false) }

        let styled = styleMenu(menu, content: menu.content(content), bar: bar, config: barConfig)
        let layout = BarLayout(metrics: metrics, renderers: renderers, rasters: rasters, resolver: resolver)
            .layout(menu: styled, anchor: anchor, top: frame.minY + scene.bar.minY,
                    align: config.item(named: menu.item)?.menu?.align ?? .start, on: bar.display,
                    scroll: menu.scroll, reveal: menu.reveal)
        place(menu, styled: styled, layout: layout, anchor: anchor, at: now)
        return (true, true)
    }

    /// A submenu beside its row in `parent`, laid out again when something changed or its parent
    /// was: false when it can no longer be shown, because its row has gone or carries no submenu.
    private func layOut(submenu: Menu, parent: Menu, force: Bool, at now: CFTimeInterval) -> (shown: Bool, laidOut: Bool) {
        guard !submenu.isClosing, let row = submenu.row, let parentLayout = parent.layout,
              let rowNode = parentLayout.item?.content?.node(at: row),
              let bar = bars.first(where: { $0.id == submenu.anchor.bar }), let barConfig = bar.config,
              let scene = bar.animator.target, let content = content(of: submenu) else { return (false, false) }
        let origin = parentLayout.frame.origin
        let anchor = rowNode.frame.offsetBy(dx: origin.x, dy: origin.y)
        guard force || submenu.dirty || submenu.layout == nil || submenu.anchorFrame != anchor else { return (true, false) }

        let styled = styleMenu(submenu, content: content, bar: bar, config: barConfig)
        let layout = BarLayout(metrics: metrics, renderers: renderers, rasters: rasters, resolver: resolver)
            .layout(submenu: styled, beside: parentLayout.panel.offsetBy(dx: origin.x, dy: origin.y), row: anchor,
                    top: bar.surface.frame.minY + scene.bar.minY, on: bar.display,
                    scroll: submenu.scroll, reveal: submenu.reveal)
        place(submenu, styled: styled, layout: layout, anchor: anchor, at: now)
        return (true, true)
    }

    /// Styled as its bar is: the bar's palette, schemes and modes; a submenu a `menu` deeper.
    private func styleMenu(_ menu: Menu, content: Node, bar: Bar, config barConfig: BarConfig) -> StyledMenu {
        let sheet = stylesheet.appending(liveStyle)
        var cascade = Cascade(stylesheet: sheet, environment: StyleEnvironment(dark: dark, accent: resolver.accent))
        cascade.environment.palette = bar.palette ?? Palette.nothing(accent: resolver.accent)
        cascade.environment.schemes = bar.schemes(for: sheet, in: cascade.environment)
        return Styler(cascade: cascade).style(
            menu: content, of: menu.item, bar: barConfig, states: host.states,
            interaction: Styler.NodeInteraction(hovered: menu.hovered, active: menu.pressed,
                                                open: submenu(of: menu)?.row),
            modes: bar.modes(modes), depth: menu.depth)
    }

    /// What one layout leaves behind: the scene to ease to, and the window where it goes.
    private func place(_ menu: Menu, styled: StyledMenu, layout: MenuScene, anchor: CGRect, at now: CFTimeInterval) {
        menu.styled = styled
        menu.layout = layout
        menu.anchorFrame = anchor
        menu.scroll = layout.scroll
        menu.reveal = nil
        menu.dirty = false
        menu.sceneChanged = true
        menu.animator.retarget(layout.scene, at: now, animated: menu.isVisible)
        if menu.surface.frame != layout.frame { menu.surface.place(layout.frame) }
    }

    /// Lay out the open menus that need it, the root first and each submenu after the one it
    /// hangs from, then present and commit them and those on their way out. Returns whether any
    /// is still moving.
    private func presentMenus(_ dirty: Dirty, at now: CFTimeInterval) -> (moving: Bool, committed: [CommitReport]) {
        if let menu {
            let root = layOut(menu, force: dirty.menu, at: now)
            if !root.shown {
                closeMenu()
            } else {
                var parent = menu
                var parentLaidOut = root.laidOut
                for (index, submenu) in submenus.enumerated() {
                    let laid = layOut(submenu: submenu, parent: parent, force: dirty.menu || parentLaidOut, at: now)
                    guard laid.shown else {
                        retireSubmenus(from: index)
                        break
                    }
                    parent = submenu
                    parentLaidOut = laid.laidOut
                }
            }
        }
        var moving = false
        var committed: [CommitReport] = []
        for menu in openMenus + closingMenus {
            if let report = present(menu, at: now) { committed.append(report) }
            if menu.moving { moving = true }
        }
        closingMenus.removeAll(where: \.finished)
        return (moving, committed)
    }

    /// One menu at a timestamp: in from its `@starting-style` on its first frame, out to its
    /// `:leaving` style once closed, and its window closed when it gets there.
    @discardableResult
    private func present(_ menu: Menu, at now: CFTimeInterval) -> CommitReport? {
        var report: CommitReport?
        var turned = false
        if menu.isClosing, menu.closedAt == nil {
            menu.closedAt = now
            turned = menu.isVisible && menu.animator.leave(at: now)
        } else if !menu.isClosing, !menu.isVisible, menu.animator.target != nil {
            turned = menu.animator.arrive(at: now)
        }
        if let scene = menu.animator.presented(at: now) {
            let isMoving = menu.animator.isMoving(at: now)
            if menu.sceneChanged || menu.moving || turned {
                let presentation = Presentation(scene: scene, isMoving: isMoving)
                report = menu.compositor.commit(presentation,
                                       inputs: Compositor.Inputs(backdrop: menu.backdrop, resolver: resolver,
                                                                 scale: scene.display.scale,
                                                                 renderers: renderers, rasters: rasters,
                                                                 surfaces: surfaces),
                                       sceneChanged: true)
                menu.presentation = presentation
                menu.surface.presented(presentation)
            }
            menu.sceneChanged = false
            menu.moving = isMoving
        }

        let visible = menu.animator.target != nil
            && (!menu.isClosing || (menu.isVisible && menu.animator.isOnItsWayOut(at: now)))
        if visible != menu.isVisible {
            menu.isVisible = visible
            menu.surface.setVisible(visible)
            menu.surface.setTakesPointer(visible && !menu.isClosing)
        }
        if menu.isClosing, !visible, !menu.finished {
            menu.finished = true
            menu.moving = false
            menu.surface.close()
        }
        return report
    }

    // MARK: - The frame

    public func frame() {
        let now = clock()
        let started = trace == nil ? 0 : CACurrentMediaTime()
        framePending = false
        rendersWaiting = false
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
        // An open menu, and those on their way out, after the bars they hang from.
        let (menusMoving, menuCommits) = presentMenus(dirty, at: now)
        updatePointerTarget()
        inFrame = false

        // 5. Continue or stop. Whatever this frame invalidated itself — a renderer asking to be
        // drawn again, hover changing under a pointer standing still — waits for the next
        // refresh, so no frame can feed the next one faster than the display shows them.
        let next: String
        if drawing || menusMoving || bars.contains(where: \.moving) || !self.dirty.isEmpty {
            framePending = true
            scheduler.scheduleRefresh()
            next = "refresh"
        } else {
            next = "idle"
        }
        trace?(String(format: "frame %d at %.3f: %@laid out %d, committed %d of %d%@%@ in %.2fms → %@",
                      frameCount, now, dirty.summary, laidOut.count, committed.count, bars.count,
                      committed.isEmpty ? "" : " (" + committed.map(\.description).joined(separator: "; ") + ")",
                      menuCommits.isEmpty ? "" : ", menu (" + menuCommits.map(\.description).joined(separator: "; ") + ")",
                      (CACurrentMediaTime() - started) * 1000, next))
    }

    /// Returns the bars that were laid out.
    private func styleAndLayout(_ dirty: Dirty, at now: CFTimeInterval) -> Set<CGDirectDisplayID> {
        let bars = self.bars.filter {
            $0.styled == nil || dirty.style.contains($0.id) || dirty.layout.contains($0.id)
        }
        guard !bars.isEmpty else { return [] }

        if !dirty.style.isEmpty { resolver = ColorResolver.system(dark: dark) }
        let sheet = stylesheet.appending(liveStyle)
        var styler = Styler(cascade: Cascade(stylesheet: sheet,
                                             environment: StyleEnvironment(dark: dark, accent: resolver.accent)))
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
                // Each bar is coloured from its own display's wallpaper, and its schemes grow from
                // it. One not measured yet has the palette of nothing, made once here rather than
                // for every wallpaper() it styles.
                styler.cascade.environment.palette = bar.palette ?? Palette.nothing(accent: resolver.accent)
                styler.cascade.environment.schemes = bar.schemes(for: sheet, in: styler.cascade.environment)
                let interaction = Styler.Interaction(
                    hovered: hovered?.bar == bar.id ? hovered?.item : nil,
                    active: pressed?.bar == bar.id ? pressed?.item : nil,
                    hoveredNode: hovered?.bar == bar.id ? hovered?.node : nil,
                    activeNode: pressed?.bar == bar.id ? pressed?.node : nil,
                    open: menu?.anchor.bar == bar.id ? menu?.anchor.item : nil)
                bar.styled = styler.style(bar: config, items: (banner.map { [$0.config] } ?? []) + config.items,
                                          states: states, interaction: interaction,
                                          modes: bar.modes(modes))
            }
            guard let styled = bar.styled else { continue }

            let scene = layout.layout(styled, on: bar.display)
            warnSqueezed(scene, on: bar)

            // A bar that is not on screen has nothing on screen to ease from.
            bar.animator.retarget(scene, at: now, animated: bar.isVisible)
            laidOut.insert(bar.id)
        }
        return laidOut
    }

    /// An item taller than its bar is squeezed to fit, which is easy to miss on one display
    /// and not another, since the default height is each display's menu bar. Said once per
    /// item and height, with the height that would hold it everywhere.
    private func warnSqueezed(_ scene: Scene, on bar: Bar) {
        for (item, needs) in scene.squeezed {
            let message = String(format: "'%@' needs a %.0fpt bar but the bar on %@ is %.0fpt, so it"
                                 + " is squeezed; `height %.0f` in the bar fits it on every display",
                                 item, needs, scene.display.name, scene.bar.height, needs)
            if bar.squeezeWarnings.insert(message).inserted { warn(message) }
        }
    }

    /// Returns what the commit did, if the bar was committed.
    @discardableResult
    private func present(_ bar: Bar, sceneChanged: Bool, at now: CFTimeInterval) -> CommitReport? {
        guard let config = bar.config, bar.animator.target != nil else {
            setVisible(bar, false)
            return nil
        }

        // The first frame worth showing: every item has rendered once, however that went,
        // and there is a photograph to show them on, and a palette to colour them with if
        // anything asks for one. Or the deadline, with what there is.
        if !bar.isReady, bar.deadlinePassed
            || (bar.backdrop.image != nil && hasRendered(bar) && (bar.paletteLooked || !wantsPalette)) {
            bar.isReady = true
        }
        // Coming on screen eases from the bar's `@starting-style`, and going off it to its
        // `:leaving` style, so either starts before the scene is sampled: the window comes up
        // on the first frame of the one, and goes down after the last frame of the other.
        let wanted = bar.isReady && bar.placeOnScreen(menuBarStays: menuBarStaysInFullscreen) && !hidden
        var turned = false
        if wanted, !bar.isVisible || bar.animator.isLeaving {
            turned = bar.animator.arrive(at: now)
        } else if !wanted, bar.isVisible, !bar.animator.isLeaving {
            turned = bar.animator.leave(at: now)
        }
        guard let scene = bar.animator.presented(at: now) else { return nil }

        let (hole, reveal) = bar.lens.present(pointer: pointer, frame: bar.surface.frame,
                                              config: config.hole, latched: revealed == bar.id,
                                              closed: isShut(bar), at: now)
        let presentation = Presentation(scene: scene, hole: hole, reveal: reveal,
                                        isMoving: bar.animator.isMoving(at: now))

        // The scene only differs from the one committed last if it was laid out again, was
        // commit-dirty, was still moving then, or has just started coming or going; the hole
        // is compared directly.
        let sceneChanged = sceneChanged || bar.moving || turned
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
        setVisible(bar, wanted || (bar.isVisible && bar.animator.isOnItsWayOut(at: now)))
        return report
    }

    private func hasRendered(_ bar: Bar) -> Bool {
        bar.moduleItems.allSatisfy { host.state(for: $0)?.rendered == true }
    }

    private func setVisible(_ bar: Bar, _ visible: Bool) {
        guard visible != bar.isVisible else { return }
        bar.isVisible = visible
        if !visible { bar.animator.gone() }
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
    /// The open menu restyles and lays out again.
    var menu = false

    var isEmpty: Bool {
        !render && style.isEmpty && layout.isEmpty && !present && commit.isEmpty && !menu
    }

    /// The dirty stages, earliest first, for a trace.
    var summary: String {
        [(render, "render"), (!style.isEmpty, "style"), (!layout.isEmpty, "layout"),
         (present, "present"), (!commit.isEmpty, "commit"), (menu, "menu")]
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
