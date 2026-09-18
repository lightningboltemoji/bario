import AppKit

/// When frames happen. The frame loop asks for at most one frame at a time; the scheduler
/// decides only when it runs. Injected, so the loop is testable with no run loop and no
/// display at all. DESIGN.md §10.
@MainActor
public protocol FrameScheduler: AnyObject {
    /// Runs one frame. Set by the frame loop.
    var onFrame: (@MainActor () -> Void)? { get set }
    /// One frame at the end of the current run-loop turn, for something that was invalidated.
    func scheduleFrame()
    /// One frame at the next display refresh, for something that is still moving.
    func scheduleRefresh()
    /// `work` once, `seconds` from now.
    func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void)
}

/// The real scheduler: a run-loop observer for the end of a turn, and a display link for
/// refreshes.
@MainActor
public final class RunLoopScheduler: FrameScheduler {
    public var onFrame: (@MainActor () -> Void)?

    private var observer: CFRunLoopObserver?
    private var turnPending = false
    private var inTurnFrame = false
    private var refreshPending = false
    private var link: CADisplayLink?
    private let target = LinkTarget()

    public init() {
        target.scheduler = self
        // Core Animation commits at order 2,000,000 on the same activities, and that commit
        // is where AppKit turns `needsDisplay` into drawing. Running just before it puts a
        // frame's paint on screen in the same pass, as late in the turn as anything can be.
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
            true, 1_000_000
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.endOfTurn() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    public func scheduleFrame() {
        turnPending = true
        // Asked for by the frame running at the end of this very turn: wake the run loop so
        // there is another end of turn to run it at, rather than sleeping on it.
        if inTurnFrame { CFRunLoopWakeUp(CFRunLoopGetMain()) }
    }

    public func scheduleRefresh() {
        refreshPending = true
        guard let link = link ?? makeLink() else {
            // No display to follow: a sixtieth of a second is a refresh as good as any.
            after(1.0 / 60) { [weak self] in self?.refresh() }
            return
        }
        link.isPaused = false
    }

    public func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The display link follows one screen. When screens come and go, the next refresh picks
    /// the fastest again.
    public func screensChanged() {
        link?.invalidate()
        link = nil
        if refreshPending { scheduleRefresh() }
    }

    private func endOfTurn() {
        guard turnPending else { return }
        turnPending = false
        inTurnFrame = true
        onFrame?()
        inTurnFrame = false
    }

    fileprivate func refresh() {
        guard refreshPending else {
            link?.isPaused = true
            return
        }
        refreshPending = false
        onFrame?()
        if !refreshPending { link?.isPaused = true }
    }

    /// A link on a screen rather than a view, because frames have to arrive whether or not a
    /// bar is on screen: a bar waits off screen for its first frame. The fastest screen, so an
    /// animation on a 120Hz display is sampled at 120Hz.
    private func makeLink() -> CADisplayLink? {
        guard let screen = NSScreen.screens.max(by: {
            $0.maximumFramesPerSecond < $1.maximumFramesPerSecond
        }) else { return nil }
        let link = screen.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        return link
    }
}

/// The display link retains its target, so it holds this rather than the scheduler. A link
/// added to the main run loop calls it on the main thread.
@MainActor
private final class LinkTarget: NSObject {
    weak var scheduler: RunLoopScheduler?

    @objc func tick(_ link: CADisplayLink) {
        scheduler?.refresh()
    }
}
