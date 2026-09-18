import AppKit
import Testing
@testable import BarioKit

@Suite("Actions")
struct ActionTests {
    @Test("the host's own verbs")
    func verbs() {
        #expect(Action.parse("reload") == .reload)
        #expect(Action.parse("emit refresh") == .emit("refresh", .object([:])))
        #expect(Action.parse(#"emit refresh {"why":"click"}"#)
                == .emit("refresh", .object(["why": .string("click")])))
        #expect(Action.parse(#"set ci {"status":"green"}"#)
                == .set("ci", .object(["status": .string("green")])))
    }

    @Test("exec keeps the rest of the line, so the shell sees the quoting it was given")
    func execKeepsQuoting() {
        #expect(Action.parse("exec open -a 'Activity Monitor'")
                == .exec("open -a 'Activity Monitor'"))
        #expect(Action.parse("exec  echo  hi ") == .exec("echo  hi"))
        #expect(Action.parse("exec") == nil)
    }

    @Test("anything else is the module's business")
    func moduleActions() {
        #expect(Action.parse("toggle-mute") == .module("toggle-mute", .object([:])))
        #expect(Action.parse("adjust") == .module("adjust", .object([:])))
        #expect(Action.parse("volume up")
                == .module("volume", .object(["args": .array([.string("up")])])))
    }

    @Test("quoting survives the splitter")
    func splitting() {
        #expect(Action.split("a b c") == ["a", "b", "c"])
        #expect(Action.split("a 'b c' d") == ["a", "b c", "d"])
        #expect(Action.split(#"a "b c" d"#) == ["a", "b c", "d"])
        #expect(Action.split(#"a b\ c"#) == ["a", "b c"])
        #expect(Action.split("   ") == [])
    }

    @Test("an event carries enough for a module to act on it")
    func eventPayload() {
        let event = BarEvent(kind: .scroll, item: "volume", point: CGPoint(x: 100, y: 12),
                             local: CGPoint(x: 4, y: 6), delta: CGPoint(x: 0, y: -3))
        #expect(event.topic == "scroll:volume")
        #expect(event.payload["item"]?.stringValue == "volume")
        #expect(event.payload["dy"]?.doubleValue == -3)
        #expect(event.payload["x"]?.doubleValue == 4)
        #expect(event.socketEvent.topic == "scroll:volume")
        #expect(event.socketEvent.json["target"]?.stringValue == "volume")
    }
}

@Suite("Transitions")
@MainActor
struct AnimatorTests {
    /// Any clock will do: the animator never reads one, it is only ever asked about a moment.
    let start: CFTimeInterval = 1000

    func scene(opacity: Double, transition: String = "opacity 100ms linear",
               width: Double = 40, radius: Double = 0) throws -> Scene {
        try bar(#"item "a" module="text" width=\#(width)"#, style: """
        item { opacity: \(opacity); border-radius: \(radius)pt; transition: \(transition) }
        """, content: ["a": .text("a")])
    }

    func opacity(_ scene: Scene?) -> Double { scene?.allItems[0].style.opacity ?? -1 }

    /// A bar from config, with the given items rendered and everything else never rendered.
    /// A nil node is an item that rendered and had nothing to show.
    func bar(_ items: String, style: String = "", content: [String: Node?]) throws -> Scene {
        let config = try ConfigLoader.parse("bar { \(items) }")
        let sheet = try Stylesheet.parse("""
        bar { padding: 0; gap: 0; transition: layout 100ms linear }
        item { padding: 0 }
        group { padding: 0; gap: 0 }
        \(style)
        """)
        let display = DisplayInfo(displayID: 1, name: "T",
                                  frame: CGRect(x: 0, y: 0, width: 400, height: 900),
                                  scale: 2, stripHeight: 24)
        let states = content.mapValues {
            ModuleHost.ItemState(result: RenderResult(content: $0), rendered: true)
        }
        let builder = SceneBuilder(cascade: Cascade(stylesheet: sheet), metrics: FixedMetrics())
        return builder.build(bar: config.bars[0], display: display,
                             items: config.bars[0].items, states: states)
    }

    func item(_ name: String, in scene: Scene?) -> SceneItem? {
        scene?.allItems.first { $0.name == name }
    }

    func near(_ value: CGFloat?, _ expected: CGFloat) -> Bool {
        value.map { abs($0 - expected) < 0.001 } ?? false
    }

    @Test("a first scene is placed, not animated in from nothing")
    func firstScene() throws {
        var animator = Animator()
        animator.retarget(try scene(opacity: 0.5), at: start)
        #expect(opacity(animator.presented(at: start)) == 0.5)
        #expect(!animator.isMoving(at: start))
    }

    @Test("a changed property eases from where it was to where it is going")
    func easing() throws {
        var animator = Animator()
        animator.retarget(try scene(opacity: 1), at: start)
        animator.retarget(try scene(opacity: 0), at: start)
        #expect(opacity(animator.presented(at: start)) == 1, "an animation starts where it was")
        #expect(animator.isMoving(at: start))

        let half = opacity(animator.presented(at: start + 0.05))
        #expect(half > 0.3 && half < 0.7)

        #expect(opacity(animator.presented(at: start + 0.2)) == 0)
        #expect(!animator.isMoving(at: start + 0.2), "frames have to be able to stop")
    }

    @Test("what is on screen is a function of time: looking does not move anything")
    func sampling() throws {
        var animator = Animator()
        animator.retarget(try scene(opacity: 1), at: start)
        animator.retarget(try scene(opacity: 0), at: start)
        let first = opacity(animator.presented(at: start + 0.03))
        _ = animator.presented(at: start + 0.09)
        _ = animator.presented(at: start + 5)
        #expect(opacity(animator.presented(at: start + 0.03)) == first)
        #expect(animator.isMoving(at: start + 0.03))
    }

    @Test("retargeting mid-flight starts from what is on screen")
    func retargeting() throws {
        var animator = Animator()
        animator.retarget(try scene(opacity: 1), at: start)
        animator.retarget(try scene(opacity: 0), at: start)
        let midway = opacity(animator.presented(at: start + 0.05))
        #expect(midway > 0.3 && midway < 0.7)

        // Turn around; the next frame must not jump back to 1.
        animator.retarget(try scene(opacity: 1), at: start + 0.05)
        #expect(abs(opacity(animator.presented(at: start + 0.05)) - midway) < 0.02)
    }

    @Test("a property easing toward a target that did not change carries on undisturbed")
    func independentProperties() throws {
        let both = "opacity 100ms linear, border-radius 100ms linear"
        var animator = Animator()
        animator.retarget(try scene(opacity: 1, transition: both), at: start)
        animator.retarget(try scene(opacity: 0, transition: both), at: start)
        // Halfway through the fade, the radius changes and the opacity does not.
        animator.retarget(try scene(opacity: 0, transition: both, radius: 8), at: start + 0.05)
        let later = animator.presented(at: start + 0.075)
        #expect(abs(opacity(later) - 0.25) < 0.001, "the fade kept its own clock")
        #expect(abs((later?.allItems[0].style.borderRadius.topLeft ?? 0) - 2) < 0.001)
    }

    @Test("a property with no transition snaps")
    func noTransition() throws {
        var animator = Animator()
        animator.retarget(try scene(opacity: 1, transition: "color 100ms"), at: start)
        animator.retarget(try scene(opacity: 0, transition: "color 100ms"), at: start)
        #expect(opacity(animator.presented(at: start)) == 0)
        #expect(!animator.isMoving(at: start))
    }

    @Test("a bar that is not on screen takes a new scene without easing")
    func notOnScreen() throws {
        var animator = Animator()
        animator.retarget(try scene(opacity: 1), at: start)
        animator.retarget(try scene(opacity: 0), at: start, animated: false)
        #expect(opacity(animator.presented(at: start)) == 0)
        #expect(!animator.isMoving(at: start))
    }

    @Test("an item's colour easing reaches the text that inherits it, and not text with its own")
    func inheritedColour() throws {
        let tree = Node.row([.text("a"), .text("b", classes: ["own"])])
        func colours(_ fg: String) throws -> Scene {
            try bar(#"item "a" module="text""#, style: """
            item { color: \(fg); transition: color 100ms linear }
            .own { color: rgb(255, 0, 0) }
            """, content: ["a": tree])
        }
        var animator = Animator()
        animator.retarget(try colours("rgb(0, 0, 0)"), at: start)
        animator.retarget(try colours("rgb(255, 255, 255)"), at: start)
        let content = animator.presented(at: start + 0.05)?.allItems[0].content
        guard case .rgba(let inherited)? = content?.children[0].style.color else {
            Issue.record("expected a blended colour, got \(String(describing: content?.children[0].style.color))")
            return
        }
        #expect(abs(inherited.r - 0.5) < 0.01)
        #expect(content?.children[1].style.color == .rgba(RGBA(r: 1, g: 0, b: 0)))
    }

    @Test("layout eases too, so a bubble changing width does not make its neighbours jump")
    func layout() throws {
        var animator = Animator()
        animator.retarget(try scene(opacity: 1, width: 40), at: start)
        animator.retarget(try scene(opacity: 1, width: 120), at: start)
        #expect(animator.presented(at: start)?.allItems[0].frame.width == 40, "the width starts where it was")

        let half = animator.presented(at: start + 0.05)?.allItems[0].frame.width ?? 0
        #expect(half > 50 && half < 110)
        #expect(animator.presented(at: start + 0.2)?.allItems[0].frame.width == 120)
        #expect(!animator.isMoving(at: start + 0.2))
    }

    @Test("an item in a group moves once, not once for itself and again with the group")
    func groupChildren() throws {
        var animator = Animator()
        func scene(_ width: Double) throws -> Scene {
            try bar("""
                item "x" module="text" width=\(width)
                group "g" { item "a" module="text" width=40; item "b" module="text" width=40; }
                """, content: ["x": .text("x"), "a": .text("a"), "b": .text("b")])
        }
        animator.retarget(try scene(40), at: start)
        animator.retarget(try scene(120), at: start)

        let half = animator.presented(at: start + 0.05)
        #expect(near(item("g", in: half)?.frame.minX, 80))
        #expect(near(item("a", in: half)?.frame.minX, 80), "the first child stays at the group's edge")
        #expect(near(item("b", in: half)?.frame.minX, 120))
    }

    @Test("the whole frame eases, and content keeps its size, centred in it")
    func verticalFrame() throws {
        var animator = Animator()
        let content: [String: Node?] = ["a": .text("a")]
        animator.retarget(try bar(#"item "a" module="text" width=40"#, content: content), at: start)
        let target = try bar(#"item "a" module="text" width=40"#, style: "item { padding: 4pt 0 }",
                             content: content)
        animator.retarget(target, at: start)

        let half = item("a", in: animator.presented(at: start + 0.05))
        #expect(near(half?.frame.minY, 3))
        #expect(near(half?.frame.height, 18), "height eases with the position")
        #expect(near(half?.content?.frame.midY, 12), "content stays centred")
        #expect(half?.content?.frame.size == item("a", in: target)?.content?.frame.size)
    }

    @Test("an item's first content places it; it does not grow out of its empty padding")
    func firstContent() throws {
        var animator = Animator()
        let items = #"item "a" module="text"; item "b" module="text""#
        animator.retarget(try bar(items, style: "item { padding: 0 8pt }",
                                  content: ["a": nil, "b": .text("b")]), at: start)
        let target = try bar(items, style: "item { padding: 0 8pt }",
                             content: ["a": .text("hello"), "b": .text("b")])
        animator.retarget(target, at: start)

        let shown = animator.presented(at: start)
        #expect(item("a", in: shown)?.frame == item("a", in: target)?.frame)
        #expect(item("b", in: shown)?.frame.minX == 16, "its neighbour still slides over")
        #expect(animator.isMoving(at: start))
    }

    @Test("an item appearing is placed where it belongs while its neighbours slide")
    func appearing() throws {
        var animator = Animator()
        let items = #"item "a" module="text"; item "b" module="text""#
        animator.retarget(try bar(items, content: ["b": .text("b")]), at: start)
        let target = try bar(items, content: ["a": .text("hello"), "b": .text("b")])
        animator.retarget(target, at: start)

        let shown = animator.presented(at: start)
        #expect(item("a", in: shown)?.frame == item("a", in: target)?.frame)
        #expect(item("b", in: shown)?.frame.minX == 0, "b starts where it was")
        #expect(item("b", in: animator.presented(at: start + 0.2))?.frame == item("b", in: target)?.frame)
    }
}
