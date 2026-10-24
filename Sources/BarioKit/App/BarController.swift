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
                cover.view.onPress = { [weak self] item in
                    self?.loop.pressed = item.map { ItemRef(bar: info.displayID, item: $0) }
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
            MainActor.assumeIsolated { self?.loop.optionHeld = event.modifierFlags.contains(.option) }
        }) { monitors.append(monitor) }
    }

    /// Whether a cover takes the pointer's events is the frame loop's decision: only while
    /// Option is held over it, or, under `option "reveal"`, while it is not.
    private func pointerMoved() {
        let mouse = NSEvent.mouseLocation
        loop.pointerMoved(to: mouse)
        loop.optionHeld = NSEvent.modifierFlags.contains(.option)

        // Pressing or releasing Option with the pointer resting on a bar moves nothing, and
        // without Accessibility permission sends nothing either. So while the pointer is on a
        // bar, and only then, Option is read a few times a second.
        let onBar = loop.bars.contains { $0.isShowing && $0.surface.frame.containsPointer(mouse) }
        if onBar, modifierPoll == nil {
            let poll = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.loop.optionHeld = NSEvent.modifierFlags.contains(.option)
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
    /// and whenever the strip came back new (PLAN.md W6).
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
        Task { @MainActor in
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
    /// one (PLAN.md W5, W11). A full screen Space has no wallpaper window, so its display keeps
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
    /// the module, socket subscribers, and the item's own shortcut. DESIGN.md §8.
    private func handle(_ event: BarEvent, on display: CGDirectDisplayID) {
        server?.broadcast(event.socketEvent)
        guard let name = event.item else { return }
        let action = self.action(for: name, kind: event.kind)
        Task { @MainActor in
            await self.host.deliver(ModuleEvent(name: event.kind.rawValue, payload: event.payload),
                                    to: name)
            if let action { await self.perform(action, item: name, event: event) }
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
        return text.flatMap(Action.parse)
    }

    private func perform(_ action: Action, item: String, event: BarEvent) async {
        switch action {
        case .exec(let command):
            // Detached: a shortcut must never make the bar wait on a process.
            Task.detached {
                _ = try? ExecModule.run(path: "/bin/sh", arguments: ["-c", command], item: item)
            }
        case .emit(let name, let payload):
            server?.broadcast(SocketEvent(kind: name, topic: "event:\(name)",
                                          fields: ["name": .string(name), "payload": payload]))
            await host.broadcast(ModuleEvent(name: name, payload: payload))
        case .set(let target, let value):
            let dirty = await host.store.merge(value, at: target)
            host.markDirty(dirty)
        case .reload:
            reload()
        case .module(let name, let payload):
            // Not a verb bario knows: the module decides what it means.
            var fields = payload.objectValue ?? [:]
            for (key, value) in event.payload.objectValue ?? [:] where fields[key] == nil {
                fields[key] = value
            }
            await host.deliver(ModuleEvent(name: name, payload: .object(fields)), to: item)
        }
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
