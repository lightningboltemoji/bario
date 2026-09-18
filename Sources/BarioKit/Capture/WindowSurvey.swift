import AppKit

/// One window as the window server describes it.
public struct SurveyedWindow: Sendable, Hashable {
    public var id: CGWindowID
    /// In screen coordinates: y up, origin at the bottom left of the primary display, like
    /// `NSScreen.frame`. The window server's own list is y-down from the top of it.
    public var frame: CGRect
    public var pid: pid_t

    public init(id: CGWindowID, frame: CGRect, pid: pid_t) {
        self.id = id
        self.frame = frame
        self.pid = pid
    }
}

/// Where the casters come from: the window server's list of what is on screen.
///
/// Asking costs about 0.8ms, near enough all of it the round trip rather than the windows, so
/// `ShadowWatcher` decides when it is worth spending. It needs no permission bario does not
/// already have — geometry is public, only a window's *title* is behind Screen Recording, and
/// nothing here reads one.
public enum WindowSurvey {
    /// Every ordinary window on screen, front to back.
    ///
    /// Layer 0 only. A panel, a menu, a torn-off palette or a drag image either casts no shadow
    /// or casts one of its own, and the list does not say which; a shadow bario invents is
    /// worse than one it leaves out, so only windows whose shadow is known get cast.
    public static func windows(primaryMaxY: CGFloat, excluding pid: pid_t? = nil) -> [SurveyedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner != pid,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 1, height > 1
            else { return nil }
            return SurveyedWindow(id: id,
                                  frame: CGRect(x: x, y: primaryMaxY - (y + height),
                                                width: width, height: height),
                                  pid: owner)
        }
    }

    /// The key window: the frontmost application's frontmost ordinary window. The list is front
    /// to back, so the first one that app owns is the one in front.
    public static func focusedWindow(in windows: [SurveyedWindow], frontmost: pid_t?) -> CGWindowID? {
        guard let frontmost else { return nil }
        return windows.first { $0.pid == frontmost }?.id
    }

    /// The field one bar sees: the windows near enough to reach it, in the bar's coordinates.
    ///
    /// A window on another display is culled by the same reach test as one too far down, since
    /// its rectangle lands outside this bar's altogether.
    public static func field(for display: DisplayInfo, windows: [SurveyedWindow],
                             focused: CGWindowID?) -> ShadowField {
        let barBottom = display.frame.maxY - display.stripHeight
        let casters = windows.compactMap { window -> ShadowCaster? in
            let shadow = WindowShadow.of(focused: window.id == focused)
            let rect = CGRect(x: window.frame.minX - display.frame.minX,
                              y: window.frame.minY - barBottom,
                              width: window.frame.width, height: window.frame.height)
            guard rect.maxY + shadow.reachUp > 0,
                  rect.minY - shadow.reachDown < display.stripHeight,
                  rect.maxX + shadow.reachSide > 0,
                  rect.minX - shadow.reachSide < display.frame.width
            else { return nil }
            return ShadowCaster(rect: rect, shadow: shadow)
        }
        return ShadowField(casters: casters)
    }
}

/// Keeps every bar's `ShadowField` up to date.
///
/// Nothing announces another app's window moving — Accessibility would, and bario needs it for
/// nothing else — so this polls, and polling is the whole cost of the feature, so it is gated.
/// At rest it samples with the housekeeping timer, four times a second, which is free. `poke()`
/// — a mouse going down, an app coming forward, a space changing — starts it sampling at the
/// display's rate, and it keeps that up until the windows have held still for a moment. The
/// cost is paid while windows are moving, which is the only time a stale field is visible.
///
/// This is the same shape as the backdrop's own unsettled decay in `BarController`: an event
/// says something is probably changing, and sampling stops when it has stopped.
@MainActor
public final class ShadowWatcher {
    /// Told a display's field whenever it changes.
    public var onChange: ((CGDirectDisplayID, ShadowField) -> Void)?
    /// The displays to survey, set by whoever owns the bars.
    public var displays: [DisplayInfo] = [] {
        didSet { if displays != oldValue { poke() } }
    }
    /// Samples in a row that found nothing moving before chasing gives up.
    public var settleSamples = 20
    public var chaseInterval = 1.0 / 60

    private var fields: [CGDirectDisplayID: ShadowField] = [:]
    private var unchanged = 0
    private var timer: Timer?
    private let own = ProcessInfo.processInfo.processIdentifier
    /// Swapped out in tests, which have no window server worth asking.
    var survey: (CGFloat, pid_t?) -> [SurveyedWindow] = WindowSurvey.windows
    var frontmost: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var primaryMaxY: () -> CGFloat = { NSScreen.screens.first?.frame.maxY ?? 0 }

    public init() {}

    /// One sample. Returns whether any bar's field changed.
    @discardableResult
    public func sample() -> Bool {
        guard !displays.isEmpty else { return false }
        let windows = survey(primaryMaxY(), own)
        let focused = WindowSurvey.focusedWindow(in: windows, frontmost: frontmost())
        var moved = false
        var seen: Set<CGDirectDisplayID> = []
        for display in displays {
            seen.insert(display.displayID)
            let field = WindowSurvey.field(for: display, windows: windows, focused: focused)
            guard fields[display.displayID] != field else { continue }
            fields[display.displayID] = field
            onChange?(display.displayID, field)
            moved = true
        }
        for id in fields.keys where !seen.contains(id) { fields[id] = nil }
        return moved
    }

    /// The idle sample: if anything moved, follow it until it settles. Called a few times a
    /// second by whatever housekeeping timer is already running.
    public func tick() {
        if sample() { chase() }
    }

    /// Something that usually precedes a window moving, which is worth following before the
    /// next idle sample would have noticed.
    public func poke() {
        unchanged = 0
        chase()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether the watcher is sampling at the display's rate, for tests and for a trace.
    public var isChasing: Bool { timer != nil }

    private func chase() {
        guard timer == nil, !displays.isEmpty else { return }
        let timer = Timer(timeInterval: chaseInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.chased() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func chased() {
        if sample() {
            unchanged = 0
        } else {
            unchanged += 1
            if unchanged >= settleSamples { stop() }
        }
    }
}
