import AppKit
import Testing
@testable import BarioKit

/// The frame loop, tested headlessly against the rules in DESIGN.md §10 rather than against
/// particular symptoms: a clock the test moves, a scheduler that runs a frame only when the
/// test says the turn has ended or the display has refreshed, and surfaces that record what
/// they were given.
@Suite("Frame loop")
@MainActor
struct FrameLoopTests {
    static let checker = Shot.checkerboard(width: 800, height: 48)!

    @Test("any number of invalidations in one turn produce exactly one frame")
    func coalescing() async throws {
        let h = try Harness(#"item "a" module="echo-test""#)
        await h.start()
        await h.settle()
        let frames = h.loop.frameCount
        let requests = h.scheduler.requests.count

        h.loop.invalidate(.style)
        h.loop.invalidate(.layout, bar: 1)
        h.loop.invalidate(.commit, bar: 1)
        h.loop.invalidate(.present)
        h.loop.stylesheet = try Stylesheet.parse("item { color: red }")
        h.loop.pressed = ItemRef(bar: 1, item: "a")
        h.loop.setBackdrop(FrameLoopTests.checker, for: 1)
        await h.host.store.merge(.object(["text": "hello"]), at: "a")

        #expect(h.scheduler.requests.count == requests + 1)
        h.scheduler.run()
        #expect(h.loop.frameCount == frames + 1)
    }

    @Test("frames keep coming while a transition runs, and stop when it ends")
    func continuing() async throws {
        let h = try Harness(#"item "a" module="echo-test""#,
                            css: "item { opacity: 1; transition: opacity 100ms linear }")
        await h.start()
        h.loop.setBackdrop(FrameLoopTests.checker, for: 1)
        await h.settle()
        #expect(h.surface.visible)
        #expect(h.scheduler.pending == nil, "an idle bar asks for nothing")
        h.scheduler.advance(by: 2)
        #expect(h.scheduler.pending == nil, "not even at the deadline it already met")

        h.style("item { opacity: 0.2; transition: opacity 100ms linear }")
        h.scheduler.run()
        #expect(h.scheduler.pending == .refresh, "moving, so the next frame comes from the display")

        var refreshes = 0
        while h.scheduler.pending == .refresh, refreshes < 100 {
            h.scheduler.advance(by: 1.0 / 60)
            h.scheduler.run()
            refreshes += 1
        }
        #expect((6...7).contains(refreshes), "100ms at 60Hz, got \(refreshes)")
        #expect(h.scheduler.pending == nil)
        #expect(h.surface.presentations.last?.scene.allItems[0].style.opacity == 0.2,
                "the last frame committed where the transition ended")
    }

    @Test("a bar that is not on screen yet takes new scenes without transitions")
    func offScreenSnaps() async throws {
        let h = try Harness(#"item "a" module="echo-test""#,
                            css: "item { opacity: 1; transition: opacity 100ms linear }")
        await h.start()
        await h.settle()
        #expect(!h.surface.visible, "no backdrop yet")

        h.style("item { opacity: 0.2; transition: opacity 100ms linear }")
        h.scheduler.run()
        #expect(h.scheduler.pending == nil)
        #expect(h.surface.presentations.last?.scene.allItems[0].style.opacity == 0.2)
    }

    @Test("a spinner on the bar costs no frames")
    func spinnerIsIdle() async throws {
        let h = try Harness(#"item "a" module="echo-test""#, css: """
        @keyframes spin { to { transform: rotate(360deg) } }
        item { animation: spin 800ms linear infinite }
        """)
        await h.start()
        h.loop.setBackdrop(FrameLoopTests.checker, for: 1)
        await h.settle()
        #expect(h.surface.visible)
        let layer = h.loop.bars[0].compositor.layer(for: .item("a"))
        #expect(layer?.animation(forKey: "bario.spin.transform.rotation.z") != nil)
        #expect(h.scheduler.pending == nil, "the window server runs it; bario sleeps")
        #expect(!h.loop.bars[0].moving)
    }

    @Test("a render invalidated while it is running runs again afterwards")
    func inFlight() async throws {
        let module = SlowCountingModule()
        let name = "slow-count-\(UUID().uuidString)"
        ModuleRegistry.register(name) { _ in module }
        let h = try Harness(#"item "slow" module="\#(name)""#)
        await h.start()
        h.scheduler.run()
        #expect(h.host.state(for: "slow")?.rendered == false, "a frame never waits for a render")
        await h.settle()
        #expect(await module.renders == 1)

        // A write starts a second render, and another write lands while it runs. The second
        // render's result is no different, so nothing but the lost write can ask for a third.
        await h.host.store.merge(.object(["tick": 1]), at: "slow")
        h.scheduler.run()
        await h.host.store.merge(.object(["tick": 2]), at: "slow")
        #expect(h.scheduler.pending == nil, "nothing can start while the render is still running")

        await h.host.finishRenders()
        #expect(await module.renders == 2)
        #expect(h.scheduler.pending == .turn, "the finished render asks for the frame that starts the next")
        await h.settle()
        #expect(await module.renders == 3, "and no more than that")
    }

    @Test("a bar is ordered in only after a frame in which every item has rendered, on a backdrop")
    func firstFrame() async throws {
        let h = try Harness(#"item "a" module="echo-test"; item "b" module="echo-test""#)
        await h.start(only: ["a"])
        await h.settle()
        #expect(!h.surface.visible, "b has not rendered")

        h.loop.setBackdrop(FrameLoopTests.checker, for: 1)
        await h.settle()
        #expect(!h.surface.visible, "b still has not rendered")

        await h.start()
        await h.settle()
        #expect(h.surface.visible)
        #expect(h.surface.orderedInWith.count == 1)
        #expect(h.surface.orderedInWith.first??.scene.allItems.map(\.name) == ["a", "b"],
                "the frame it was ordered in with had everything in it")
    }

    @Test("a bar waits no longer than its deadline, and a capture that never came is stood in for")
    func deadline() async throws {
        let h = try Harness(#"item "a" module="echo-test"; item "never" module="echo-test""#)
        var stoodIn = 0
        h.loop.standIn = { _ in
            stoodIn += 1
            return FrameLoopTests.checker
        }
        await h.start(only: ["a"])
        await h.settle()

        h.scheduler.advance(by: 0.9)
        #expect(h.scheduler.pending == nil)
        #expect(!h.surface.visible)

        h.scheduler.advance(by: 0.2)
        #expect(h.scheduler.pending == .turn)
        h.scheduler.run()
        #expect(h.surface.visible)
        #expect(stoodIn == 1)
        #expect(h.surface.orderedInWith.first??.scene.allItems.map(\.name) == ["a"])
    }

    @Test("a pointer nowhere near a bar costs nothing; near one, only that bar repaints")
    func pointer() async throws {
        let h = try Harness(#"item "a" module="echo-test""#, bars: 2)
        await h.start()
        for bar in h.loop.bars { h.loop.setBackdrop(FrameLoopTests.checker, for: bar.id) }
        await h.settle()
        let (left, right) = (h.surfaces[0], h.surfaces[1])
        #expect(left.visible && right.visible)
        let before = (left.presentations.count, right.presentations.count)

        h.loop.pointerMoved(to: CGPoint(x: 200, y: 400))
        #expect(h.scheduler.pending == nil, "far from every bar")

        // Onto "a" on the left bar: the hole opens there, and nothing hovers.
        h.loop.pointerMoved(to: CGPoint(x: 5, y: 888))
        #expect(h.scheduler.pending == .turn)
        h.scheduler.run()
        #expect(left.presentations.count == before.0 + 1)
        #expect(right.presentations.count == before.1, "the other bar is nowhere near")
        #expect(left.presentations.last?.hole.isVisible == true)
        #expect(left.presentations.last?.scene.allItems[0].states.contains(.hover) == false,
                "without Option the bar does not react to the pointer")
        #expect(!left.takesPointer)

        // Leaving takes one more frame to close the hole, then nothing.
        h.loop.pointerMoved(to: CGPoint(x: 200, y: 400))
        h.scheduler.run()
        #expect(left.presentations.last?.hole.isVisible == false)
        h.loop.pointerMoved(to: CGPoint(x: 210, y: 400))
        #expect(h.scheduler.pending == nil)
    }

    @Test("the click reveal eases in over time, frames stop when it settles, and it eases out")
    func reveal() async throws {
        let h = try Harness(#"item "a" module="echo-test""#)
        await h.start()
        h.loop.setBackdrop(FrameLoopTests.checker, for: 1)
        await h.settle()

        h.loop.pointerMoved(to: CGPoint(x: 200, y: 888))
        h.scheduler.run()
        h.loop.revealed = 1
        h.scheduler.run()
        #expect(h.surface.presentations.last?.reveal == 0, "the reveal starts where it was")
        var frames = 0
        while h.scheduler.pending == .refresh, frames < 100 {
            h.scheduler.advance(by: 1.0 / 60)
            h.scheduler.run()
            frames += 1
        }
        #expect(h.surface.presentations.last?.reveal == 1)
        #expect(frames > 5 && frames < 40, "about a third of a second, got \(frames) frames")

        // Leaving the bar unlatches it, and the bar comes back the same way.
        h.loop.pointerMoved(to: CGPoint(x: 200, y: 400))
        #expect(h.loop.revealed == nil)
        h.scheduler.run()
        #expect(h.scheduler.pending == .refresh)
        while h.scheduler.pending == .refresh, frames < 200 {
            h.scheduler.advance(by: 1.0 / 60)
            h.scheduler.run()
            frames += 1
        }
        #expect(h.surface.presentations.last?.reveal == 0)
    }

    @Test("a click reveals the bar it was on, and no other")
    func revealIsPerBar() async throws {
        let h = try Harness(#"item "a" module="echo-test""#, bars: 2)
        await h.start()
        for bar in h.loop.bars { h.loop.setBackdrop(FrameLoopTests.checker, for: bar.id) }
        await h.settle()

        h.loop.pointerMoved(to: CGPoint(x: 200, y: 888))
        h.loop.revealed = 1
        // Along the top edge onto the other display, still near the first bar.
        h.loop.pointerMoved(to: CGPoint(x: 410, y: 888))
        #expect(h.loop.revealed == 1)
        for _ in 0..<60 where h.scheduler.pending != nil {
            h.scheduler.advance(by: 1.0 / 60)
            h.scheduler.run()
        }
        #expect(h.surfaces[0].presentations.last?.reveal == 1)
        #expect(h.surfaces[1].presentations.last?.reveal == 0, "the other bar was never clicked")

        h.loop.pointerMoved(to: CGPoint(x: 600, y: 888))
        #expect(h.loop.revealed == nil, "leaving the clicked bar ends its reveal")
    }

    @Test("holding Option over a bar closes its hole, and it takes clicks and hovers")
    func option() async throws {
        let h = try Harness(#"item "a" module="echo-test"; item "b" module="echo-test""#, bars: 2)
        await h.start()
        for bar in h.loop.bars { h.loop.setBackdrop(FrameLoopTests.checker, for: bar.id) }
        await h.settle()
        let (left, right) = (h.surfaces[0], h.surfaces[1])

        // "a" is 0…24, "b" 24…48 ("echo" at 12pt is 24pt wide).
        h.loop.pointerMoved(to: CGPoint(x: 30, y: 888))
        await h.drain()
        #expect(left.presentations.last?.hole.isVisible == true)
        #expect(!left.takesPointer)

        h.loop.optionHeld = true
        #expect(left.takesPointer, "a click on the bar now reaches bario")
        #expect(!right.takesPointer, "only the bar under the pointer")
        #expect(h.loop.hovered == ItemRef(bar: 1, item: "b"))
        await h.drain()
        #expect(left.presentations.last?.hole.isVisible == false, "the hole has eased shut")
        #expect(left.presentations.last?.scene.allItems[1].states.contains(.hover) == true)
        #expect(h.scheduler.pending == nil)

        // Off the bar with Option still held: nothing is interactive.
        h.loop.pointerMoved(to: CGPoint(x: 30, y: 600))
        #expect(!left.takesPointer)
        #expect(h.loop.hovered == nil)

        // Back on, and Option let go: the bar ignores the pointer again, and the hole opens.
        h.loop.pointerMoved(to: CGPoint(x: 30, y: 888))
        #expect(left.takesPointer)
        h.loop.optionHeld = false
        #expect(!left.takesPointer)
        #expect(h.loop.hovered == nil)
        await h.drain()
        #expect(left.presentations.last?.hole.isVisible == true)
        #expect(left.presentations.last?.scene.allItems[1].states.contains(.hover) == false)
    }

    @Test("Option pressed with the pointer nowhere near a bar costs nothing")
    func optionFarAway() async throws {
        let h = try Harness(#"item "a" module="echo-test""#)
        await h.start()
        h.loop.setBackdrop(FrameLoopTests.checker, for: 1)
        await h.settle()
        h.loop.pointerMoved(to: CGPoint(x: 200, y: 400))
        #expect(h.scheduler.pending == nil)
        h.loop.optionHeld = true
        #expect(h.scheduler.pending == nil)
        h.loop.optionHeld = false
        #expect(h.scheduler.pending == nil)
        #expect(!h.surface.takesPointer)
    }

    @Test("what a frame invalidates itself waits for the next refresh")
    func selfInvalidationIsPaced() async throws {
        let h = try Harness(#"item "a" module="echo-test"; item "b" module="echo-test""#)
        await h.start()
        h.loop.setBackdrop(FrameLoopTests.checker, for: 1)
        await h.settle()
        h.loop.optionHeld = true
        h.loop.pointerMoved(to: CGPoint(x: 30, y: 888))
        await h.drain()
        #expect(h.loop.hovered?.item == "b")

        // "a" grows and "b" slides out from under a pointer that does not move.
        await h.host.store.merge(.object(["text": "a much longer text"]), at: "a")
        await h.settle()
        #expect(h.loop.hovered?.item == "a")
        #expect(h.scheduler.pending == .refresh, "the hover change the frame found waits for the display")
        h.scheduler.advance(by: 1.0 / 60)
        h.scheduler.run()
        #expect(h.scheduler.pending == nil)
        #expect(h.surface.presentations.last?.scene.allItems.first { $0.name == "a" }?.states.contains(.hover) == true)
    }

    @Test("the hole is where the pointer is, and fades with distance")
    func lens() {
        let bar = CGRect(x: 0, y: 876, width: 400, height: 24)
        var lens = Lens()
        let config = HoleConfig()
        let over = lens.present(pointer: CGPoint(x: 100, y: 888), frame: bar, config: config,
                                latched: false, closed: false, at: 0)
        #expect(over.hole.center == CGPoint(x: 100, y: 12))
        #expect(over.hole.strength == 1)
        let near = lens.present(pointer: CGPoint(x: 100, y: 836), frame: bar, config: config,
                                latched: false, closed: false, at: 0)
        #expect(near.hole.strength > 0 && near.hole.strength < 1)
        let far = lens.present(pointer: CGPoint(x: 100, y: 500), frame: bar, config: config,
                               latched: false, closed: false, at: 0)
        #expect(!far.hole.isVisible)
        #expect(!lens.isMoving(at: 0))

        // Closing eases; far away, it is simply closed.
        let closing = lens.present(pointer: CGPoint(x: 100, y: 888), frame: bar, config: config,
                                   latched: false, closed: true, at: 1)
        #expect(closing.hole.strength == 1, "it starts from open")
        #expect(lens.isMoving(at: 1))
        let shut = lens.present(pointer: CGPoint(x: 100, y: 888), frame: bar, config: config,
                                latched: false, closed: true, at: 2)
        #expect(!shut.hole.isVisible)
        _ = lens.present(pointer: CGPoint(x: 100, y: 500), frame: bar, config: config,
                         latched: false, closed: false, at: 3)
        #expect(!lens.isMoving(at: 3), "a hole too far away to show does not ease")
    }

    @Test("a photograph identical to the last is not a new one")
    func sameBackdrop() async throws {
        let h = try Harness(#"item "a" module="echo-test""#)
        await h.start()
        h.loop.setBackdrop(Shot.checkerboard(width: 800, height: 48), for: 1)
        await h.settle()
        h.loop.setBackdrop(Shot.checkerboard(width: 800, height: 48), for: 1)
        #expect(h.scheduler.pending == nil)
        h.loop.setBackdrop(Shot.checkerboard(width: 800, height: 48, square: 4), for: 1)
        #expect(h.scheduler.pending == .turn)
    }

    @Test("a renderer that asks for a frame is drawn again at the display's rate, while it asks, without laying the bar out")
    func requestFrame() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bario-blink-\(UUID().uuidString.prefix(6)).wat")
        try FrameLoopTests.blink.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let renderers = RendererHost()
        renderers.load([RendererConfig(nodeType: "blink", path: url.path, options: .object([:]),
                                       position: .start)], store: StateStore())
        #expect(renderers.has("blink"))

        let h = try Harness(#"item "b" module="blink-test""#, renderers: renderers)
        h.loop.setBackdrop(FrameLoopTests.checker, for: 1)
        await h.start()
        await h.settle()
        #expect(h.surface.visible)
        #expect(h.scheduler.pending == .refresh, "the renderer asked while it was drawn")
        #expect(h.loop.bars[0].lastCommit?.draws == 1)

        var layouts = 0
        h.loop.trace = { line in if !line.contains("laid out 0") { layouts += 1 } }
        var refreshes = 0
        while h.scheduler.pending == .refresh, refreshes < 100 {
            h.scheduler.advance(by: 1.0 / 60)
            h.scheduler.run()
            refreshes += 1
            #expect(h.loop.bars[0].lastCommit?.draws == 1, "each frame draws it once")
        }
        // Measuring and drawing are both `draw`, and it asks on its first four calls. A request
        // made while measuring means nothing; the three made while drawing each get a frame.
        #expect(refreshes == 3)
        #expect(layouts == 0, "a frame for a drawing commits the bar and does not lay it out")
        #expect(h.scheduler.pending == nil)
    }

    @Test("a renderer drawing every frame draws nothing else on the bar")
    func requestFrameIsolated() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bario-flip-\(UUID().uuidString.prefix(6)).wat")
        try FrameLoopTests.flip.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let renderers = RendererHost()
        renderers.load([RendererConfig(nodeType: "blink", path: url.path, options: .object([:]),
                                       position: .start)], store: StateStore())

        let h = try Harness(#"item "a" module="echo-test"; item "b" module="blink-test""#, renderers: renderers)
        h.loop.setBackdrop(FrameLoopTests.checker, for: 1)
        await h.start()
        await h.settle()
        #expect(h.scheduler.pending == .refresh)
        for _ in 0..<4 {
            h.scheduler.advance(by: 1.0 / 60)
            h.scheduler.run()
            let report = h.loop.bars[0].lastCommit
            #expect(report?.draws == 1)
            #expect(report?.rasters == 1, "its own drawing changed, and nothing else was drawn")
        }
    }

    /// A renderer that always asks for another frame, and draws one of two drawings in turn.
    static let flip = #"""
    (module
      (import "bario" "request_frame" (func $request_frame))
      (memory (export "memory") 1)
      (global $next (mut i32) (i32.const 1024))
      (global $calls (mut i32) (i32.const 0))
      (func (export "alloc") (param $len i32) (result i32)
        (local $ptr i32)
        (local.set $ptr (global.get $next))
        (global.set $next (i32.add (global.get $next) (i32.add (local.get $len) (i32.const 8))))
        (local.get $ptr))
      (data (i32.const 0) "{\"width\":10,\"height\":10,\"ops\":[{\"fill\":\"red\",\"path\":[[\"rect\",0,0,4,4]]}]}")
      (data (i32.const 128) "{\"width\":10,\"height\":10,\"ops\":[{\"fill\":\"red\",\"path\":[[\"rect\",4,4,4,4]]}]}")
      (func (export "draw") (param $ptr i32) (param $len i32) (result i64)
        (global.set $calls (i32.add (global.get $calls) (i32.const 1)))
        (call $request_frame)
        (if (result i64) (i32.and (global.get $calls) (i32.const 1))
          (then (i64.const 73))
          (else (i64.or (i64.shl (i64.const 128) (i64.const 32)) (i64.const 73)))))
    )
    """#

    /// A renderer that asks for another frame the first four times it is called.
    static let blink = #"""
    (module
      (import "bario" "request_frame" (func $request_frame))
      (memory (export "memory") 1)
      (global $next (mut i32) (i32.const 1024))
      (global $calls (mut i32) (i32.const 0))
      (func (export "alloc") (param $len i32) (result i32)
        (local $ptr i32)
        (local.set $ptr (global.get $next))
        (global.set $next (i32.add (global.get $next) (i32.add (local.get $len) (i32.const 8))))
        (local.get $ptr))
      (data (i32.const 0) "{\"width\":10,\"height\":10,\"ops\":[]}")
      (func (export "draw") (param $ptr i32) (param $len i32) (result i64)
        (global.set $calls (i32.add (global.get $calls) (i32.const 1)))
        (if (i32.le_u (global.get $calls) (i32.const 4)) (then (call $request_frame)))
        (i64.const 33))
    )
    """#
}

// MARK: - The harness

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    var now: CFTimeInterval = 1000
}

/// Stands in for the end of a run-loop turn and the display link.
@MainActor
final class ManualScheduler: FrameScheduler {
    enum Request: Equatable { case turn, refresh }

    var onFrame: (@MainActor () -> Void)?
    private(set) var pending: Request?
    private(set) var requests: [Request] = []
    private var timers: [(due: CFTimeInterval, work: @MainActor () -> Void)] = []
    let clock: TestClock

    init(clock: TestClock) { self.clock = clock }

    func scheduleFrame() { request(.turn) }
    func scheduleRefresh() { request(.refresh) }

    private func request(_ kind: Request) {
        #expect(pending == nil, "a second frame was asked for while one was already coming")
        pending = kind
        requests.append(kind)
    }

    func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        timers.append((clock.now + seconds, work))
    }

    /// The turn ends, or the display refreshes: the frame that was asked for runs.
    @discardableResult
    func run() -> Bool {
        guard pending != nil else { return false }
        pending = nil
        onFrame?()
        return true
    }

    /// Move the clock, firing the timers that come due.
    func advance(by seconds: Double) {
        clock.now += seconds
        let due = timers.filter { $0.due <= clock.now }
        timers.removeAll { $0.due <= clock.now }
        for timer in due { timer.work() }
    }
}

@MainActor
final class RecordingSurface: BarSurface {
    let frame: CGRect
    let hostLayer = CALayer()
    private(set) var presentations: [Presentation] = []
    private(set) var visible = false
    /// What was last committed each time the bar was ordered in.
    private(set) var orderedInWith: [Presentation?] = []

    init(frame: CGRect) { self.frame = frame }

    func presented(_ presentation: Presentation) {
        presentations.append(presentation)
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if visible { orderedInWith.append(presentations.last) }
    }

    private(set) var takesPointer = false
    func setTakesPointer(_ takes: Bool) { takesPointer = takes }
}

/// Renders what was written under its key, at once.
actor EchoModule: Module {
    func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: .text(state.value("text")?.stringValue ?? "echo"))
    }
}

/// Counts its renders, takes a moment over each, and always shows the same thing.
actor SlowCountingModule: Module {
    private(set) var renders = 0
    func render(_ state: StateReader) async throws -> RenderResult {
        renders += 1
        _ = state.own
        try await Task.sleep(nanoseconds: 20_000_000)
        return RenderResult(content: .text("slow"))
    }
}

/// Content for a custom node type.
actor BlinkModule: Module {
    func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: Node(.custom("blink", .object([:]))))
    }
}

/// One or more 400×900 displays side by side, each with a 24pt bar, all showing one config.
@MainActor
final class Harness {
    static let base = "bar { padding: 0; gap: 0; background: none } item { padding: 0; background: none }\n"

    let clock = TestClock()
    let scheduler: ManualScheduler
    let host = ModuleHost()
    let loop: FrameLoop
    private(set) var surfaces: [RecordingSurface] = []
    var surface: RecordingSurface { surfaces[0] }

    init(_ items: String, css: String = "", bars: Int = 1,
         renderers: RendererHost = RendererHost()) throws {
        ModuleRegistry.register("echo-test") { _ in EchoModule() }
        ModuleRegistry.register("blink-test") { _ in BlinkModule() }

        scheduler = ManualScheduler(clock: clock)
        loop = FrameLoop(host: host, renderers: renderers, metrics: FixedMetrics(),
                         scheduler: scheduler, clock: { [clock] in clock.now })
        loop.config = try ConfigLoader.parse("bar { \(items) }")
        style(css)
        for index in 0..<bars {
            let x = Double(index) * 400
            let display = DisplayInfo(displayID: CGDirectDisplayID(index + 1), name: "T\(index)",
                                      frame: CGRect(x: x, y: 0, width: 400, height: 900),
                                      scale: 2, stripHeight: 24)
            let surface = RecordingSurface(frame: CGRect(x: x, y: 876, width: 400, height: 24))
            surfaces.append(surface)
            loop.addBar(display: display, surface: surface)
        }
    }

    func style(_ css: String) {
        loop.stylesheet = (try? Stylesheet.parse(Harness.base + css)) ?? Stylesheet()
    }

    /// Start the modules, or some of them, and let their first polls land.
    func start(only names: Set<String>? = nil) async {
        let items = loop.config.bars.flatMap(\.items).filter { names?.contains($0.name) ?? true }
        await host.load(items)
        await host.firstPolls(within: 1)
    }

    /// Every frame there is to run, refreshes included, a sixtieth of a second apart.
    func drain() async {
        for _ in 0..<200 {
            if scheduler.pending == .refresh { scheduler.advance(by: 1.0 / 60) }
            guard scheduler.run() else {
                await host.finishRenders()
                await Task.yield()
                if scheduler.pending == nil { return }
                continue
            }
            await host.finishRenders()
            await Task.yield()
        }
    }

    /// What the run loop does while the clock stands still: run the frames asked for at the
    /// end of a turn, and let the renders they start come back. A frame asking for a refresh
    /// is left waiting for the test to move the clock.
    func settle() async {
        for _ in 0..<20 {
            if scheduler.pending == .turn { scheduler.run() }
            await host.finishRenders()
            await Task.yield()
            guard scheduler.pending == .turn else { return }
        }
    }
}
