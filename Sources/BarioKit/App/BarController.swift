import AppKit

/// The daemon: config and stylesheet in, one cover window per display out. Everything here is
/// an input to the frame loop, which does all the drawing (DESIGN.md §10). This file turns
/// AppKit, the socket and the file watcher into those inputs, and nothing else.
@MainActor
public final class BarController: NSObject, NSApplicationDelegate {
    private let options: RunOptions
    private var theme: Theme
    private let startupError: String?

    private let host = ModuleHost()
    private let scheduler = RunLoopScheduler()
    private lazy var loop = FrameLoop(host: host, scheduler: scheduler)

    private var covers: [CGDirectDisplayID: BarCover] = [:]
    private var monitors: [Any] = []
    private var timers: [Timer] = []
    private var observations: [NSKeyValueObservation] = []
    private var captureAllowed = false
    private var captureInFlight = false
    private var captureQueued = false
    /// Captures in a row that each found the desktop still changing.
    private var unsettled = 0
    /// An event has asked for a capture since the last one, which is then looked at again
    /// whatever it finds. See `captureBackdrops`.
    private var lookAgain = false
    /// Reads Option while the pointer rests on a bar, for when no key event says it changed.
    private var modifierPoll: Timer?
    private var watchers: [FileWatcher] = []
    private var wallpaperWatcher: FileWatcher?
    /// Photographs each display's wallpaper for its palette, or reads the file.
    private let paletteCapture = PaletteCapture()
    /// What each display's palette was last measured from: an image identical to it is not new.
    private var paletteImages: [CGDirectDisplayID: CGImage] = [:]
    /// Follows the windows whose shadows fall into the bars.
    private let shadows = ShadowWatcher()
    /// Displays a full screen app has started zooming into, and when, until its Space is
    /// current. See `zoomStarted`.
    private var zooming: [CGDirectDisplayID: CFTimeInterval] = [:]
    private var server: SocketServer?
    private var service: BarioService?
    private var surfaceListener: SurfaceListener?
    private var stateFeed: Task<Void, Never>?
    private var hupSource: DispatchSourceSignal?
    private var quitSources: [DispatchSourceSignal] = []
    private var menuBarItem: MenuBarItem?
    /// The press in an open menu, on a control or a slider being dragged, and which menu of the
    /// chain it is in.
    private var menuPress: (menu: Menu, path: [Int], dragging: Bool)?
    /// The modifier keys as last written to the store.
    private var modifiers: ModifierKeys?
    /// A slider's newest value not yet sent, and whether one is on its way: one `on-change` in
    /// flight at a time, the newest value next.
    private var pendingChange: (action: Action, item: String, value: Double, confined: Bool)?
    private var changing = false

    public init(options: RunOptions, theme: Theme, startupError: String? = nil) {
        self.options = options
        self.theme = theme
        self.startupError = startupError
        super.init()
    }

    // MARK: - Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        ModuleRegistry.registerBuiltIns()
        captureAllowed = StripSource.ensureCaptureAccess(mode: options.source)

        if options.traceFrames { loop.trace = { note($0) } }
        loop.config = theme.config
        loop.stylesheet = theme.stylesheet
        loop.banner = startupError
        loop.dark = systemIsDark
        loop.standIn = { [options] bar in
            // `--source capture` asked for captures only; anything else would rather show an
            // approximation than nothing.
            guard options.source != .capture,
                  let screen = NSScreen.screens.first(where: { $0.displayID == bar.id }) else { return nil }
            return StripSource.fromWallpaperFile(info: bar.display, spec: WallpaperSpec(screen: screen))
        }
        if options.windowShadows {
            shadows.onChange = { [weak self] id, field in self?.loop.setShadows(field, for: id) }
        }
        loop.renderers.load(theme.config.renderers, store: host.store, events: host.events)
        let items = theme.config.bars.flatMap(\.items)
        let sources = theme.config.sources
        Task { await host.load(items, sources: sources) }

        loop.makeMenuSurface = { [weak self] display in
            let panel = self?.menuPanel(on: display, takesKeys: true) ?? MenuPanel(screen: nil)
            // Another app came forward. Not when another menu took over: that one is open now.
            panel.onResignKey = { [weak self, weak panel] in
                guard let self, let panel, self.loop.menu?.surface === panel else { return }
                self.loop.closeMenu()
            }
            return panel
        }
        loop.makeSubmenuSurface = { [weak self] display in
            self?.menuPanel(on: display, takesKeys: false) ?? MenuPanel(screen: nil, takesKeys: false)
        }

        syncDisplays()
        startTimers()
        startMonitors()
        observeSystem()
        startWatching()
        startSocket()
        startMenuBarItem()
        printBanner()

        // `killall -HUP bario` re-reads the config and re-photographs the desktop.
        signal(SIGHUP, SIG_IGN)
        let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        hup.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reload()
                self?.captureBackdrops()
            }
        }
        hup.resume()
        hupSource = hup

        // Ctrl-C and `kill` end watches' processes on the way out, as Quit does. Off the main
        // queue, so a bar that has stopped answering still dies when told to. `@Sendable`, or the
        // handler is inferred to be the main actor's and traps on its first line off the main queue.
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { @Sendable in
                ExecModule.terminateHeld()
                signal(number, SIG_DFL)
                raise(number)
            }
            source.resume()
            quitSources.append(source)
        }

        if let duration = options.duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { NSApp.terminate(nil) }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Now, not in the shutdown below: that is a task, and the app exits before it runs.
        ExecModule.terminateHeld()
        shadows.stop()
        stateFeed?.cancel()
        server?.stop()
        surfaceListener?.stop()
        watchers.forEach { $0.stop() }
        wallpaperWatcher?.stop()
        let host = self.host
        Task { await host.shutdown() }
    }

    private var systemIsDark: Bool {
        options.dark ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    /// Asked of the session rather than kept from the lock and unlock notifications, so a
    /// missed one cannot stop the captures for good.
    private var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduler.screensChanged()
                self?.syncDisplays()
            }
        }
        // The accent colour is resolved into every colour that names it, and a made-up slot of
        // a wallpaper with no seed takes its hue.
        center.addObserver(forName: NSColor.systemColorsDidChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loop.invalidate(.style)
                self?.loop.accentChanged(to: RGBA(NSColor.controlAccentColor))
            }
        }
        // The appearance also changes the wallpaper, if it is a dynamic one, and the shading
        // under the menu bar.
        observations.append(NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loop.dark = self.systemIsDark
                    self.captureBackdrops()
                }
            }
        })

        // The desktop behind the bar is the wallpaper and the shading under the menu bar, and
        // nothing announces a change to either, so these are the moments one is likely: a
        // space with its own wallpaper, and waking or unlocking, after which a dynamic
        // wallpaper has moved on and an aerial has stopped somewhere new. A new Space may also
        // be a full screen app's, which decides whether a bar shows at all.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.syncDisplays()
                    self?.captureBackdrops()
                    self?.shadows.poke()
                }
            }
        }
        SkyLight.whenFullscreenZoomStarts { [weak self] space in self?.zoomStarted(into: space) }
        // macOS draws the key window a much larger shadow than the rest, so an app coming
        // forward changes the strip more than a window moving does.
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shadows.poke() }
        }
        // Unlocking is announced before it is over: WallpaperAgent takes the lock screen's
        // wallpaper window down about 0.3s after the notification, and a capture until then
        // photographs it.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.captureBackdrops() }
            }
        }
        // Choosing a wallpaper rewrites WallpaperAgent's store. Not an API, so if the file moves
        // this goes quiet and the periodic refresh is what notices.
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        wallpaperWatcher = FileWatcher(url: store) { [weak self] in
            Task { @MainActor in self?.captureBackdrops() }
        }
    }

    // MARK: - Displays

    /// A display as its bar covers it: the menu bar, and the bar where it hangs lower.
    private func strip(on screen: NSScreen) -> DisplayInfo? {
        DisplayInfo(screen: screen).map(loop.config.strip(on:))
    }

    /// One bar per display. A display that appears gets a bar that waits off screen for its
    /// first frame; one that moves, resizes or hides its menu bar invalidates its bar's layout,
    /// as does a config that changes how tall its bar is. A full screen app taking a display,
    /// or giving it back, restyles its bar and may take it off screen.
    private func syncDisplays() {
        var seen: Set<CGDirectDisplayID> = []
        var changed = false
        var fullscreen = SkyLight.fullscreenDisplays(among: NSScreen.screens.compactMap(\.displayID))
        // A display a full screen app is zooming into is the app's already. Its Space being
        // current ends the wait, and an app that has not landed in a second and a half is let go.
        let now = CACurrentMediaTime()
        zooming = zooming.filter { !fullscreen.contains($0.key) && now - $0.value < 1.5 }
        fullscreen.formUnion(zooming.keys)
        loop.menuBarStaysInFullscreen = MenuBar.staysInFullscreen
        for screen in NSScreen.screens {
            guard let info = strip(on: screen) else { continue }
            seen.insert(info.displayID)
            let menuBarShown = screen.menuBarInset > 1
            let isFullscreen = fullscreen.contains(info.displayID)
            // Whether a cover is fixed is settled when it is made, so a config that changes it
            // gets a new one, which waits for its first frame like any other.
            let fixed = loop.config.bar(for: info)?.placement == .fixed
            if let cover = covers[info.displayID], cover.fixed != fixed {
                loop.removeBar(info.displayID)
                cover.close()
                covers[info.displayID] = nil
            }
            if let cover = covers[info.displayID] {
                cover.fit(to: screen, strip: info)
                if loop.bars.first(where: { $0.id == info.displayID })?.display != info { changed = true }
                loop.updateBar(info.displayID, display: info, menuBarShown: menuBarShown,
                               fullscreen: isFullscreen)
            } else {
                let cover = BarCover(info: info, screen: screen, debugTint: options.debugTint,
                                     fixed: fixed)
                cover.view.onEvent = { [weak self] event in self?.handle(event, on: info.displayID) }
                cover.view.onPress = { [weak self] press in
                    self?.loop.pressed = press.map { ItemRef(bar: info.displayID, item: $0.item, node: $0.node) }
                }
                cover.view.onPointer = { [weak self] in self?.pointerMoved() }
                covers[info.displayID] = cover
                loop.addBar(display: info, surface: cover, menuBarShown: menuBarShown,
                            fullscreen: isFullscreen)
                changed = true
            }
        }
        for (id, cover) in covers where !seen.contains(id) {
            loop.removeBar(id)
            cover.close()
            covers[id] = nil
            paletteImages[id] = nil
            changed = true
        }
        // A new display, or one with a new size or scale, needs a photograph that fits it.
        if changed { captureBackdrops() }
        if options.windowShadows {
            shadows.displays = loop.bars.map(\.display)
        }
    }

    /// A full screen app has started zooming into `space`. Its Space becomes current only as it
    /// lands, half a second on, and the zoom is drawn over every window meanwhile, the bar
    /// included. A bar that waited for the Space would come back from under the zoom and only
    /// then go; this way it goes under the zoom, and a bar that stays has its `fullscreen` look
    /// by the time the app is there. DESIGN.md §6.
    private func zoomStarted(into space: UInt64) {
        let displays = SkyLight.displays(withFullscreenSpace: space,
                                         among: NSScreen.screens.compactMap(\.displayID))
        guard !displays.isEmpty else { return }
        let now = CACurrentMediaTime()
        for id in displays { zooming[id] = now }
        syncDisplays()
    }

    // MARK: - The pointer

    private func startMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                            .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(monitor) }
        // While a cover is taking events, moves over it never reach the global monitor; its
        // view's tracking area reports those.

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                           handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clicked(at: NSEvent.mouseLocation)
                // A window about to be dragged, most likely. Following it from the press costs
                // a third of a second of polling if nothing moves after all.
                self?.shadows.poke()
            }
        }) { monitors.append(monitor) }
        // A press can end anywhere, including somewhere the cover is no longer taking events.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.loop.pressed = nil }
        }) { monitors.append(monitor) }
        // Option. Key events only reach a global monitor with Accessibility permission, so the
        // modifier poll below is what makes this work without it.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.loop.optionHeld = event.modifierFlags.contains(.option)
                self?.noteModifiers(event.modifierFlags)
            }
        }) { monitors.append(monitor) }
    }

    /// The modifier keys held, into the store when they change, for a template that asks: an open
    /// menu showing an app's Option variants renders again.
    private func noteModifiers(_ flags: NSEvent.ModifierFlags) {
        let next = ModifierKeys(option: flags.contains(.option), shift: flags.contains(.shift),
                                control: flags.contains(.control), command: flags.contains(.command))
        guard next != modifiers else { return }
        modifiers = next
        let store = host.store
        Task { await store.replace(next.json, at: ModifierKeys.storeKey) }
    }

    /// Whether a cover takes the pointer's events is the frame loop's decision: only while
    /// Option is held over it, or, under `option "reveal"`, while it is not.
    private func pointerMoved() {
        let mouse = NSEvent.mouseLocation
        loop.pointerMoved(to: mouse)
        loop.optionHeld = NSEvent.modifierFlags.contains(.option)
        noteModifiers(NSEvent.modifierFlags)

        // Pressing or releasing Option with the pointer resting on a bar moves nothing, and
        // without Accessibility permission sends nothing either. So while the pointer is on a
        // bar, and only then, Option is read a few times a second.
        let onBar = loop.bars.contains { $0.isShowing && $0.surface.frame.containsPointer(mouse) }
        if onBar, modifierPoll == nil {
            let poll = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.loop.optionHeld = NSEvent.modifierFlags.contains(.option)
                    self?.noteModifiers(NSEvent.modifierFlags)
                }
            }
            RunLoop.main.add(poll, forMode: .common)
            modifierPoll = poll
        } else if !onBar {
            modifierPoll?.invalidate()
            modifierPoll = nil
        }
    }

    /// A click on a bar that falls through to the real menu bar uncovers everything until the
    /// pointer leaves, so the menu you clicked is usable. One below the menu bar, where a tall
    /// bar hangs over a window, is on the window, and opened no menu.
    private func clicked(at point: CGPoint) {
        // A click anywhere but bario's own windows closes a menu, as one outside a menu does.
        loop.closeMenu()
        if let bar = loop.bars.first(where: { $0.isShowing && $0.menuBarFrame.containsPointer(point)
                                              && $0.config?.hole.click == .reveal }) {
            loop.revealed = bar.id
        }
    }

    // MARK: - Backdrop

    private func startTimers() {
        // For what changes the wallpaper with nothing to say so: a dynamic wallpaper following
        // the time of day, a shuffled one.
        if options.refresh > 0 {
            let refresh = Timer(timeInterval: options.refresh, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.captureBackdrops(event: false) }
            }
            RunLoop.main.add(refresh, forMode: .common)
            timers.append(refresh)
        }
        // Nothing announces a menu bar auto-hiding, a full screen app on another display being
        // clicked into, or another app's window moving.
        let house = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncDisplays()
                self?.shadows.tick()
            }
        }
        RunLoop.main.add(house, forMode: .common)
        timers.append(house)
    }

    /// Photograph what is behind every bar. A capture already out finishes first and the next
    /// one follows it, so a display plugged in mid-capture is not skipped.
    ///
    /// The desktop tends to change over a moment rather than at once — a wallpaper fading in,
    /// an aerial slowing to a stop — and the event that says so comes at the start, or before
    /// it: `screenIsUnlocked` comes about 0.3s before the lock screen's wallpaper goes. So a
    /// capture for an event is followed by another a second later whatever it found, and a
    /// capture that found something new by another, until one finds the desktop holding
    /// still, or ten in a row have not.
    ///
    /// Nothing is photographed while the screen is locked. WallpaperAgent shows the lock
    /// screen's wallpaper in a window of its own below normal level, which the capture filter
    /// would take for the desktop, and the bars are hidden behind the lock screen anyway.
    /// Unlocking captures again.
    ///
    /// Each display's palette is measured in the same round, after its strip: for an event,
    /// and whenever the strip came back new.
    private func captureBackdrops(event: Bool = true) {
        if event { lookAgain = true }
        guard !captureInFlight else {
            captureQueued = true
            return
        }
        guard !screenIsLocked else { return }
        let pending = covers.values.compactMap { cover -> (BarCover, DisplayInfo, WallpaperSpec)? in
            guard photographs(cover.displayID),
                  let screen = NSScreen.screens.first(where: { $0.displayID == cover.displayID }),
                  let info = strip(on: screen) else { return nil }
            return (cover, info, WallpaperSpec(screen: screen))
        }
        guard !pending.isEmpty else { return }

        captureInFlight = true
        let lookAgain = self.lookAgain
        self.lookAgain = false
        let mode = options.source
        let allowed = captureAllowed
        Task { @MainActor [self] in
            var changed = false
            for (cover, info, spec) in pending {
                let strip = await StripSource.strip(info: info, spec: spec, mode: mode, captureAllowed: allowed)
                // A full screen app may have taken the display while this was out.
                guard self.covers[cover.displayID] === cover, self.photographs(cover.displayID) else { continue }
                var stripNew = false
                if let strip {
                    if cover.lastSource != strip.source {
                        cover.lastSource = strip.source
                        note("  \(cover.name): \(strip.source)")
                    }
                    stripNew = self.loop.setBackdrop(strip.image, for: cover.displayID)
                    if stripNew { changed = true }
                } else {
                    warn("no backdrop image for \(cover.name); leaving the real menu bar alone")
                }
                if lookAgain || stripNew {
                    await self.measurePalette(of: cover.displayID, info: info, spec: spec, mode: mode,
                                              captureAllowed: allowed)
                }
            }
            self.captureInFlight = false
            if self.captureQueued {
                self.captureQueued = false
                self.captureBackdrops(event: false)
            } else if changed || lookAgain, self.unsettled < 10 {
                self.unsettled += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    MainActor.assumeIsolated { self?.captureBackdrops(event: false) }
                }
            } else {
                self.unsettled = 0
            }
        }
    }

    /// Whether a display's desktop is photographed for its bar. A full screen Space has no
    /// desktop, so its photograph is black: right for a bar shown over the app, in the black strip
    /// beside a notch, but one that is not would wear it on its way out, mid-fade, and come back
    /// in it. That one keeps the photograph it had.
    private func photographs(_ id: CGDirectDisplayID) -> Bool {
        guard let bar = loop.bars.first(where: { $0.id == id }), bar.fullscreen else { return true }
        return bar.placeOnScreen(menuBarStays: loop.menuBarStaysInFullscreen)
    }

    /// One display's wallpaper, measured into a palette off the main actor, against the last
    /// one. A full screen Space has no wallpaper window, so its display keeps
    /// the palette it had.
    private func measurePalette(of id: CGDirectDisplayID, info: DisplayInfo, spec: WallpaperSpec,
                                mode: SourceMode, captureAllowed: Bool) async {
        guard let bar = loop.bars.first(where: { $0.id == id }), !bar.fullscreen else { return }
        guard let image = await paletteCapture.image(info: info, spec: spec, mode: mode,
                                                     captureAllowed: captureAllowed) else {
            loop.foundNoPalette(for: id)
            return
        }
        guard covers[id] != nil else { return }
        if let last = paletteImages[id], BackdropImage.same(last, image) { return }
        paletteImages[id] = image
        let (previous, accent, box) = (bar.palette, RGBA(NSColor.controlAccentColor), Box(value: image))
        let palette = await Task.detached { Palette.extract(box.value, previous: previous, accent: accent) }.value
        guard covers[id] != nil else { return }
        loop.setPalette(palette, for: id)
    }

    // MARK: - Events

    /// An item's events go to three places at once, which is what keeps the tiers equivalent:
    /// the module, socket subscribers, and the item's own shortcut. DESIGN.md §8. A control
    /// inside the item takes the event instead of the item's shortcut, and a
    /// click with no shortcut at all opens the item's menu, if it has one.
    private func handle(_ event: BarEvent, on display: CGDirectDisplayID) {
        server?.broadcast(event.socketEvent)
        guard let name = event.item else {
            // The bar between items: as good as outside the menu.
            if event.kind == .click { loop.closeMenu() }
            return
        }
        let anchor = ItemRef(bar: display, item: name)
        if let path = event.node, let control = control(at: path, in: name, on: display) {
            if event.kind == .click, !isMenuToggle(control.actions.click) { loop.closeMenu() }
            use(control, path: path, kind: event.kind, item: name, anchor: anchor, payload: event.payload,
                confined: host.isConfined(name), at: event.local)
            return
        }
        let action = self.action(for: name, kind: event.kind)
        if event.kind == .click {
            if action == nil {
                loop.toggleMenu(name, from: anchor)
            } else if !isMenuToggle(theme.config.item(named: name)?.actions.click) {
                loop.closeMenu()
            }
        }
        Task { @MainActor in
            await self.host.deliver(ModuleEvent(name: event.kind.rawValue, payload: event.payload),
                                    to: name)
            if let action { await self.perform(action, item: name, payload: event.payload, anchor: anchor) }
        }
    }

    private func isMenuToggle(_ text: String?) -> Bool {
        guard let text, case .menu? = Action.parse(text) else { return false }
        return true
    }

    /// The control at a path in an item on a bar, as it is on screen.
    private func control(at path: [Int], in item: String, on display: CGDirectDisplayID) -> SceneNode? {
        loop.bars.first { $0.id == display }?.presentation?.scene.allItems
            .first { $0.name == item }?.content?.node(at: path)
    }

    /// A control used: clicked, right-clicked or scrolled, on a bar or in a menu. A slider
    /// clicked jumps to where it was clicked, and scrolled moves with the wheel.
    private func use(_ control: SceneNode, path: [Int], kind: BarEvent.Kind, item: String, anchor: ItemRef,
                     payload: JSONValue, confined: Bool, at local: CGPoint, delta: CGPoint = .zero) {
        if case .slider(let meter) = control.kind, let change = control.actions.change,
           let action = Action.parse(change, confined: confined) {
            switch kind {
            case .click:
                send(action, item: item, value: Double(local.x / max(1, control.frame.width)), confined: confined)
                return
            case .scroll where control.actions.scroll == nil:
                let dy = payload["dy"]?.doubleValue ?? 0, dx = payload["dx"]?.doubleValue ?? 0
                send(action, item: item, value: meter.value + (dy != 0 ? dy : -dx) * 0.005, confined: confined)
                return
            default:
                break
            }
        }
        let text: String?
        switch kind {
        case .click: text = control.actions.click
        case .rightClick: text = control.actions.rightClick
        case .scroll: text = control.actions.scroll
        default: text = nil
        }
        guard let text, let action = Action.parse(text, confined: confined) else { return }
        Task { @MainActor in await self.perform(action, item: item, payload: payload, anchor: anchor) }
    }

    /// A slider moved: its `on-change`, with the value, once whatever was sent last has been
    /// dealt with. A drag sends far more values than a module needs; the newest one wins.
    private func send(_ action: Action, item: String, value: Double, confined: Bool) {
        pendingChange = (action, item, min(1, max(0, value)), confined)
        guard !changing else { return }
        changing = true
        Task { @MainActor in
            while let change = self.pendingChange {
                self.pendingChange = nil
                await self.perform(change.action, item: change.item,
                                   payload: .object(["item": .string(change.item), "value": .number(change.value)]),
                                   anchor: nil, waits: true)
            }
            self.changing = false
        }
    }

    // MARK: - Menus

    /// A menu's window, for the root (which takes the keys) or a submenu (which never does).
    private func menuPanel(on display: DisplayInfo, takesKeys: Bool) -> MenuPanel {
        let panel = MenuPanel(screen: NSScreen.screens.first { $0.displayID == display.displayID },
                              takesKeys: takesKeys)
        panel.view.onPointer = { [weak self] in self?.pointerMoved() }
        panel.view.onMouse = { [weak self] mouse, point in self?.menuMouse(mouse, at: point) }
        panel.view.onKey = { [weak self] key in self?.menuKey(key) }
        panel.view.onModifiers = { [weak self] flags in self?.noteModifiers(flags) }
        return panel
    }

    /// The pointer in an open menu's window. A control is used when the press comes up on it,
    /// as a menu item is chosen, and the menu closes unless it says `keep-open`; a slider moves
    /// from the press on and never closes it. A row with a submenu and nothing
    /// else to do opens it. The menu a press is in is the one under it, deepest first, whichever
    /// window heard it. A press off every panel is outside the menu, or,
    /// where the window reaches up over its bar, on the bar.
    private func menuMouse(_ mouse: MenuView.Mouse, at point: CGPoint) {
        guard let root = loop.menu else { return }
        let confined = host.menuState(for: root.item)?.confined ?? false
        let hit = loop.menuTarget(at: point)
        switch mouse {
        case .down:
            menuPress = nil
            guard let (menu, target) = hit else {
                if let bar = loop.target(at: point), bar.bar.isInteractive {
                    forward(.click, at: point, to: bar)
                } else {
                    loop.closeMenu()
                }
                return
            }
            if case .control(let path, let node) = target {
                loop.pressMenu(path, in: menu)
                let slides = { if case .slider = node.kind { return node.actions.change != nil } else { return false } }()
                menuPress = (menu, path, slides)
                if slides { slide(menu, path: path, to: point, confined: confined) }
            }
        case .drag:
            if let press = menuPress, press.dragging { slide(press.menu, path: press.path, to: point, confined: confined) }
        case .up:
            guard let press = menuPress else { return }
            menuPress = nil
            loop.pressMenu(nil, in: press.menu)
            if press.dragging {
                loop.releaseMenuDrag(in: press.menu)
            } else if let (menu, target) = hit, case .control(let path, let node) = target {
                if node.actions.submenu != nil, node.actions.click == nil {
                    loop.openSubmenu(from: menu, row: path)
                } else {
                    choose(node, at: path, in: menu, confined: confined)
                }
            }
        case .rightDown:
            if let (menu, target) = hit, case .control(_, let node) = target, let text = node.actions.rightClick,
               let action = Action.parse(text, confined: confined) {
                Task { @MainActor in
                    await self.perform(action, item: menu.item, payload: .object(["item": .string(menu.item)]),
                                       anchor: menu.anchor)
                }
            } else if hit == nil, let bar = loop.target(at: point) {
                forward(.rightClick, at: point, to: bar)
            }
        case .scroll(let dx, let dy):
            guard let (menu, target) = hit else {
                if let bar = loop.target(at: point) {
                    forward(.scroll, at: point, to: bar, delta: CGPoint(x: dx, y: dy))
                }
                return
            }
            guard case .control(let path, let node) = target else {
                loop.scrollMenu(menu, by: dy)
                return
            }
            if case .slider(let meter) = node.kind, node.actions.change != nil, node.actions.scroll == nil {
                let value = min(1, max(0, meter.value + (dy != 0 ? dy : -dx) * 0.005))
                loop.dragMenu(path, to: value, in: menu)
                loop.releaseMenuDrag(in: menu)
                if let text = node.actions.change, let action = Action.parse(text, confined: confined) {
                    send(action, item: menu.item, value: value, confined: confined)
                }
            } else if let text = node.actions.scroll, let action = Action.parse(text, confined: confined) {
                Task { @MainActor in
                    await self.perform(action, item: menu.item,
                                       payload: .object(["item": .string(menu.item), "dx": .number(dx), "dy": .number(dy)]),
                                       anchor: menu.anchor)
                }
            } else {
                // The rows of a menu taller than its room, from anywhere over them.
                loop.scrollMenu(menu, by: dy)
            }
        }
    }

    /// A slider in an open menu, dragged to a point.
    private func slide(_ menu: Menu, path: [Int], to point: CGPoint, confined: Bool) {
        guard let value = menu.value(of: path, at: point),
              let node = menu.presentation?.scene.items.first?.content?.node(at: path),
              let text = node.actions.change, let action = Action.parse(text, confined: confined) else { return }
        loop.dragMenu(path, to: value, in: menu)
        send(action, item: menu.item, value: value, confined: confined)
    }

    /// A control in a menu chosen: its action, as its item's own, and the menu closes, with every
    /// submenu, unless the control or something around it says `keep-open`.
    private func choose(_ node: SceneNode, at path: [Int], in menu: Menu, confined: Bool) {
        guard let text = node.actions.click, let action = Action.parse(text, confined: confined) else { return }
        let keep = menu.presentation?.scene.items.first?.content?.keepsOpen(at: path) ?? false
        if !keep, !isMenuToggle(text) { loop.closeMenu() }
        var payload: [String: JSONValue] = ["item": .string(menu.item),
                                            "node": node.id.map(JSONValue.string) ?? .array(path.map { .number(Double($0)) })]
        payload["menu"] = .bool(true)
        server?.broadcast(SocketEvent(kind: "click", topic: "click:\(menu.item)",
                                      fields: payload.merging(["target": .string(menu.item)]) { a, _ in a }))
        Task { @MainActor in await self.perform(action, item: menu.item, payload: .object(payload), anchor: menu.anchor) }
    }

    /// A press in a menu's window that is really on the bar under it.
    private func forward(_ kind: BarEvent.Kind, at point: CGPoint,
                         to hit: (bar: Bar, item: SceneItem, control: (path: [Int], node: SceneNode)?),
                         delta: CGPoint = .zero) {
        let frame = hit.bar.surface.frame
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let origin = hit.control?.node.frame ?? hit.item.frame
        var event = BarEvent(kind: kind, item: hit.item.name, point: local,
                             local: CGPoint(x: local.x - origin.minX, y: local.y - origin.minY), delta: delta,
                             modifiers: UInt(NSEvent.modifierFlags.rawValue))
        event.node = hit.control?.path
        event.nodeID = hit.control?.node.id
        handle(event, on: hit.bar.id)
    }

    /// A key while a menu is open: Escape closes it, ↑ and ↓ move between the controls of the menu
    /// the keys are in, → opens the submenu of the one they are on and ← goes back out of it, and
    /// Return chooses it, or opens its submenu.
    private func menuKey(_ key: String) {
        guard loop.menu != nil else { return }
        switch key {
        case "escape":
            loop.closeMenu()
        case "up", "down":
            loop.moveMenuHover(by: key == "down" ? 1 : -1)
        case "right":
            loop.openSubmenuFromKeys()
        case "left":
            loop.closeSubmenuFromKeys()
        case "return":
            guard let menu = loop.keyMenu, let path = menu.hovered,
                  let node = menu.presentation?.scene.items.first?.content?.node(at: path) else { return }
            if node.actions.submenu != nil, node.actions.click == nil {
                loop.openSubmenuFromKeys()
            } else {
                choose(node, at: path, in: menu, confined: host.menuState(for: menu.item)?.confined ?? false)
            }
        default:
            break
        }
    }

    private func action(for item: String, kind: BarEvent.Kind) -> Action? {
        guard let config = theme.config.bars.lazy
            .flatMap(\.items).flatMap(\.flattened).first(where: { $0.name == item })
        else { return nil }
        let text: String?
        switch kind {
        case .click: text = config.actions.click
        case .rightClick: text = config.actions.rightClick
        case .scroll: text = config.actions.scroll
        default: text = nil
        }
        return text.flatMap { Action.parse($0) }
    }

    /// `anchor` is where a `menu` it opens hangs from; `waits` holds a command until it exits, for
    /// a slider that should not start a process per pixel dragged.
    private func perform(_ action: Action, item: String, payload: JSONValue, anchor: ItemRef?,
                         waits: Bool = false) async {
        switch action {
        case .exec(let command):
            var extra: [String: String] = [:]
            if let value = payload["value"]?.doubleValue { extra["BARIO_VALUE"] = String(format: "%.3f", value) }
            // Detached: a shortcut must never make the bar wait on a process.
            let run = Task.detached {
                _ = try? ExecModule.run(path: "/bin/sh", arguments: ["-c", command], item: item, extra: extra)
            }
            if waits { await run.value }
        case .emit(let name, let eventPayload):
            server?.broadcast(SocketEvent(kind: name, topic: "event:\(name)",
                                          fields: ["name": .string(name), "payload": eventPayload]))
            await host.broadcast(ModuleEvent(name: name, payload: eventPayload))
        case .set(let target, let value):
            let dirty = await host.store.merge(value, at: target)
            host.markDirty(dirty)
        case .key(let chord):
            // The press that got here has already dismissed the panel, as any press outside it
            // does. Its shortcut on top would throw it back open half way out, and it would jump
            // and vanish, so the press is left to close it.
            if chord.togglesNotificationCenter, NotificationCenterPanel.isOpen { return }
            // Without Accessibility permission the events vanish without an error, so ask for
            // it (macOS prompts once) and say why nothing happened.
            guard CGPreflightPostEventAccess() else {
                _ = CGRequestPostEventAccess()
                warn("\(item): key \(chord) needs Accessibility permission for bario "
                     + "(System Settings › Privacy & Security › Accessibility)")
                return
            }
            chord.post()
        case .reload:
            reload()
        case .menu(let other):
            let owner = other ?? item
            if let anchor {
                loop.toggleMenu(owner, from: anchor)
            } else if let anchor = defaultAnchor(for: owner) {
                loop.toggleMenu(owner, from: anchor)
            }
        case .send(let target, let name, let args):
            await host.deliver(ModuleEvent(name: name, payload: merged(args, with: payload)), to: target)
        case .module(let name, let args):
            // Not a verb bario knows: the module decides what it means.
            await host.deliver(ModuleEvent(name: name, payload: merged(args, with: payload)), to: item)
        }
    }

    /// An action's own arguments, and beside them whatever the event says that they do not.
    private func merged(_ args: JSONValue, with payload: JSONValue) -> JSONValue {
        var fields = args.objectValue ?? [:]
        for (key, value) in payload.objectValue ?? [:] where fields[key] == nil { fields[key] = value }
        return .object(fields)
    }

    /// Where a menu opened from outside any bar hangs: its item on the bar under the pointer, or
    /// on the first bar that shows it; a source's, or an item no bar shows, from the leftmost item
    /// of the bar under the pointer.
    private func defaultAnchor(for item: String) -> ItemRef? {
        let mouse = NSEvent.mouseLocation
        let bars = loop.bars.filter(\.isShowing).sorted { a, b in
            a.surface.frame.minX < b.surface.frame.minX
        }
        let preferred = bars.first { $0.display.frame.contains(mouse) }
        for bar in [preferred].compactMap({ $0 }) + bars {
            if bar.presentation?.scene.allItems.contains(where: { $0.name == item }) == true {
                return ItemRef(bar: bar.id, item: item)
            }
        }
        guard let bar = preferred ?? bars.first,
              let first = bar.presentation?.scene.items.first(where: { $0.kind != .spacer }) else { return nil }
        return ItemRef(bar: bar.id, item: first.name)
    }

    // MARK: - The socket

    private func startSocket() {
        let service = BarioService(store: host.store, host: host)
        service.onReload = { [weak self] in self?.reload() }
        service.onStyle = { [weak self] css in
            guard let self else { return }
            // Parse before applying: a bad delta should be an error reply, not a broken bar. It
            // may name the schemes of what it is layered over.
            let under = self.loop.stylesheet.appending(self.loop.liveStyle)
            let delta = try Stylesheet.parse(css, source: "<socket>", knownSchemes: Set(under.schemes.keys))
            self.loop.liveStyle = self.loop.liveStyle.appending(delta)
        }
        service.onFrame = { [weak self] name, index in try self?.loop.surfaces.frame(name, index: index) }
        service.onMenu = { [weak self] item in
            guard let self else { return }
            guard let item else { return self.loop.closeMenu() }
            guard self.theme.config.item(named: item) != nil else {
                throw ProtocolError("there is no item or source called '\(item)'")
            }
            guard let anchor = self.defaultAnchor(for: item) else {
                throw ProtocolError("no bar is showing to hang \(item)'s menu from")
            }
            self.loop.toggleMenu(item, from: anchor)
        }
        self.service = service

        // Native processes hand over their surfaces through a Mach port, since that is the
        // only thing an IOSurface crosses processes as; they say which one they drew over the
        // socket. DESIGN.md §9.3.
        do {
            surfaceListener = try SurfaceListener(surfaces: loop.surfaces)
            note("  surfaces: \(SurfaceListener.defaultService())")
        } catch {
            warn("no shared surfaces: \(error)")
        }

        let server = SocketServer { request in
            await MainActor.run { service }.handle(request)
        }
        service.publish = { [weak server] event in server?.broadcast(event) }
        do {
            try server.start()
            self.server = server
            note("  socket: \(server.path)")
        } catch {
            warn("no socket: \(error)")
            return
        }

        // A module's `emit` reaches the socket and every module that subscribed to it, which
        // is what makes the two tiers the same API rather than similar ones.
        host.events.onPost { [weak self] event, origin in
            Task { @MainActor in
                guard let self else { return }
                self.server?.broadcast(SocketEvent(kind: event.name, topic: "event:\(event.name)",
                                                   fields: ["name": .string(event.name),
                                                            "payload": event.payload]))
                await self.host.deliver(event, topic: "event:\(event.name)", except: origin)
            }
        }

        // Every state change is published to the socket, and to the modules that asked for it.
        let store = host.store
        stateFeed = Task { [weak server, weak self] in
            for await change in await store.changes(matching: "*") {
                server?.broadcast(.state(path: change.path, value: change.value))
                guard let self else { continue }
                let topic = "state:\(change.path)"
                await MainActor.run { self.host }
                    .deliver(ModuleEvent(name: "state",
                                         payload: .object(["target": .string(change.path),
                                                           "value": change.value])),
                             topic: topic)
            }
        }
    }

    // MARK: - The menu bar item

    private func startMenuBarItem() {
        let item = MenuBarItem()
        item.isHidden = { [weak self] in self?.loop.hidden ?? false }
        item.error = { [weak self] in self?.loop.banner }
        item.configDirectory = { [weak self] in
            self?.theme.configURL?.deletingLastPathComponent() ?? ConfigLoader.searchDirectories[0]
        }
        item.onSetHidden = { [weak self] hidden in self?.loop.hidden = hidden }
        item.onReload = { [weak self] in self?.reload() }
        item.refresh()
        menuBarItem = item
    }

    // MARK: - Live reload

    /// Watch both files, and both directories, so creating one for the first time works too.
    private func startWatching() {
        watchers.forEach { $0.stop() }
        let paths = [
            options.configPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? theme.configURL ?? ConfigLoader.searchDirectories[0].appendingPathComponent("config.kdl"),
            options.stylePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? theme.styleURL ?? ConfigLoader.searchDirectories[0].appendingPathComponent("style.css"),
        ]
        watchers = paths.map { url in
            FileWatcher(url: url) { [weak self] in
                Task { @MainActor in self?.reload() }
            }
        }
    }

    /// One reload path, for the watcher, SIGHUP and the socket. A failure keeps the last good
    /// theme and says so on the bar. Everything it changes is an input: the stylesheet and
    /// config invalidate style everywhere, and only modules whose options changed restart.
    public func reload() {
        defer { menuBarItem?.refresh() }
        let next: Theme
        do {
            next = try Theme.load(configPath: options.configPath, stylePath: options.stylePath)
        } catch {
            warn("\(error)")
            loop.banner = "\(error)"
            return
        }
        theme = next
        note("reloaded \(next.configURL?.lastPathComponent ?? "config") ·"
             + " \(next.styleURL?.lastPathComponent ?? "default style")")

        loop.banner = nil
        loop.liveStyle = Stylesheet()      // a socket delta lasts until the file it was iterating on
        loop.stylesheet = next.stylesheet
        loop.config = next.config
        // A bar's height is how tall its cover is, and how much desktop to photograph.
        syncDisplays()
        // Renderers and decoded rasters are layout inputs.
        loop.renderers.load(next.config.renderers, store: host.store, events: host.events)
        loop.rasters.clear()
        loop.invalidate(.layout)

        let items = next.config.bars.flatMap(\.items)
        let sources = next.config.sources
        Task { await host.load(items, sources: sources) }
    }

    // MARK: - Chatter

    private func printBanner() {
        note("bario \(barioVersion) · \(covers.count) bar\(covers.count == 1 ? "" : "s")")
        note("  config: \(theme.configURL?.path ?? "built-in default")")
        note("  style:  \(theme.styleURL?.path ?? "built-in default")")
        for cover in covers.values.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            let f = cover.frame
            let notched = NSScreen.screens.first { $0.displayID == cover.displayID }?.notchFrame != nil
            note(String(format: "  %@: %.0f×%.0f at (%.0f, %.0f)%@",
                        cover.name, f.width, f.height, f.minX, f.minY, notched ? " · notched" : ""))
        }
        if covers.isEmpty { warn("no screens found") }
        note("  Ctrl-C, or Quit in bario's menu bar item, to quit.")
    }
}
