import AppKit
import Testing
@testable import BarioKit

@Suite("Arriving and leaving in the stylesheet")
struct EnterExitStyleTests {
    let item = [StyleNode(type: "bar"), StyleNode(type: "item", id: "names")]

    func message(_ css: String) -> String {
        do {
            _ = try Stylesheet.parse(css)
            return "parsed, but should not have"
        } catch {
            return "\(error)"
        }
    }

    @Test("@starting-style is part of the starting cascade only")
    func starting() throws {
        let cascade = Cascade(stylesheet: try Stylesheet.parse("""
        item { opacity: 1; transition: opacity 200ms }
        @starting-style { #names { opacity: 0 } }
        """))
        #expect(cascade.style(for: item).style.opacity == 1)
        let starting = try #require(cascade.startingStyle(for: item))
        #expect(starting.opacity == 0)
        #expect(starting.transition(for: "opacity") != nil, "the rest of the cascade still applies")
        #expect(cascade.startingStyle(for: [StyleNode(type: "bar"), StyleNode(type: "item", id: "app")]) == nil)
    }

    @Test(":leaving is a state an item's own rules name")
    func leaving() throws {
        let cascade = Cascade(stylesheet: try Stylesheet.parse("""
        item { opacity: 1 }
        #names:leaving { opacity: 0; transform: translateY(-20pt) }
        """))
        #expect(cascade.style(for: item).style.opacity == 1)
        let leaving = try #require(cascade.leavingStyle(for: item))
        #expect(leaving.opacity == 0)
        #expect(leaving.transform.translateY == -20)
        #expect(cascade.leavingStyle(for: [StyleNode(type: "bar"), StyleNode(type: "item", id: "app")]) == nil)
    }

    @Test("what is wrong with them is said")
    func errors() {
        #expect(message("@starting-style { @media (prefers-color-scheme: dark) { item { opacity: 0 } } }")
            .contains("do not nest"))
        #expect(message("@starting-style item { opacity: 0 }").contains("expected { after @starting-style"))
        #expect(message("@starting-style { item { opacity: 0 }").contains("unterminated @starting-style"))
    }
}

@Suite("Turning in depth")
struct DepthTests {
    func transform(_ css: String) throws -> Transform {
        try Cascade(stylesheet: Stylesheet.parse("item { transform: \(css) }"))
            .style(for: [StyleNode(type: "item")]).style.transform
    }

    /// Where a point of a box, relative to its centre in y-up points, lands on screen.
    func project(_ matrix: CATransform3D, _ x: Double, _ y: Double) -> CGPoint {
        let X = x * matrix.m11 + y * matrix.m21 + matrix.m41
        let Y = x * matrix.m12 + y * matrix.m22 + matrix.m42
        let W = x * matrix.m14 + y * matrix.m24 + matrix.m44
        return CGPoint(x: X / W, y: Y / W)
    }

    @Test("rotateX, rotateY, perspective, translateX and translateY parse")
    func parses() throws {
        #expect(try transform("perspective(40pt) translateY(-20pt) rotateX(90deg)")
                == Transform(translateY: -20, rotateX: 90, perspective: 40))
        #expect(try transform("rotateY(0.25turn) translateX(3pt) rotateZ(5deg)")
                == Transform(translateX: 3, rotate: 5, rotateY: 90))
        func message(_ css: String) -> String {
            do { _ = try transform(css); return "parsed" } catch { return "\(error)" }
        }
        #expect(message("perspective(0)").contains("more than 0"))
        #expect(message("translate(1pt) translateY(2pt)").contains("not both"))
        #expect(message("rotateX(1deg, 2deg)").contains("one angle"))
    }

    @Test("they turn the way CSS turns them: positive tips the top, or the right, away")
    func directions() throws {
        let away = try transform("perspective(40pt) rotateX(40deg)").matrix
        let top = project(away, 10, 5).x - project(away, -10, 5).x
        let bottom = project(away, 10, -5).x - project(away, -10, -5).x
        #expect(top < bottom, "the top edge is further away, so shorter")

        let right = try transform("perspective(40pt) rotateY(40deg)").matrix
        let rightEdge = project(right, 10, 5).y - project(right, 10, -5).y
        let leftEdge = project(right, -10, 5).y - project(right, -10, -5).y
        #expect(rightEdge < leftEdge)

        let flat = try transform("rotateX(60deg)").matrix
        #expect(abs(project(flat, 0, 10).y - 5) < 0.001, "without perspective it only foreshortens")
    }

    @Test("a perspective on one side of a transition holds all the way")
    func blending() throws {
        var style = Style()
        style.transform = Transform(rotateX: 0)
        var from = Style()
        from.transform = Transform(rotateX: 90, perspective: 40)
        style.blend(.transform, from: from, t: 0.5)
        #expect(style.transform == Transform(rotateX: 45, perspective: 40))
    }
}

@Suite("Arriving and leaving")
@MainActor
struct EnterExitTests {
    static let checker = Shot.checkerboard(width: 800, height: 48)!
    static let fade = "item { opacity: 1; transition: opacity 100ms linear }\n"

    func started(_ items: String, css: String) async throws -> Harness {
        let h = try Harness(items, css: css)
        await h.start()
        h.loop.setBackdrop(EnterExitTests.checker, for: 1)
        await h.settle()
        #expect(h.surface.visible)
        return h
    }

    func show(_ h: Harness, _ items: String) throws {
        h.loop.config = try ConfigLoader.parse("bar { \(items) }")
        h.scheduler.run()
    }

    func item(_ h: Harness, _ name: String) -> SceneItem? {
        h.surface.presentations.last?.scene.allItems.first { $0.name == name }
    }

    func tick(_ h: Harness, _ seconds: Double) {
        h.scheduler.advance(by: seconds)
        h.scheduler.run()
    }

    @Test("an item that leaves eases to its :leaving style out of reach of the pointer, and is then gone")
    func leaves() async throws {
        let h = try await started(#"item "a" module="echo-test"; item "b" module="echo-test""#,
                                  css: EnterExitTests.fade + "#b:leaving { opacity: 0 }")
        let frame = try #require(item(h, "b")).frame
        try show(h, #"item "a" module="echo-test""#)

        let ghost = try #require(item(h, "b"))
        #expect(ghost.states.contains(.leaving))
        #expect(ghost.frame == frame, "it goes from where it was")
        #expect(ghost.style.opacity == 1)
        #expect(h.surface.presentations.last?.scene.item(at: CGPoint(x: frame.midX, y: frame.midY)) == nil)
        #expect(h.scheduler.pending == .refresh)

        tick(h, 0.05)
        #expect(abs((item(h, "b")?.style.opacity ?? 0) - 0.5) < 0.01)
        #expect(h.loop.bars[0].lastCommit?.rasters == 0, "a ghost keeps its pixels")

        tick(h, 0.06)
        #expect(item(h, "b") == nil)
        #expect(h.scheduler.pending == nil, "and frames stop")
    }

    @Test("without a :leaving style an item goes at once")
    func vanishes() async throws {
        let h = try await started(#"item "a" module="echo-test"; item "b" module="echo-test""#,
                                  css: EnterExitTests.fade)
        try show(h, #"item "a" module="echo-test""#)
        #expect(item(h, "b") == nil)
        #expect(h.scheduler.pending == nil)
    }

    @Test("an item that arrives transitions from its @starting-style")
    func arrives() async throws {
        let both = #"item "a" module="echo-test"; item "c" module="echo-test""#
        let h = try await started(both, css: EnterExitTests.fade + "@starting-style { #c { opacity: 0 } }")
        #expect(item(h, "c")?.style.opacity == 1, "not on the bar's first frame")
        try show(h, #"item "a" module="echo-test""#)
        try show(h, both)

        #expect(item(h, "c")?.style.opacity == 0)
        tick(h, 0.05)
        #expect(abs((item(h, "c")?.style.opacity ?? 0) - 0.5) < 0.01)
        tick(h, 0.06)
        #expect(item(h, "c")?.style.opacity == 1)
        #expect(h.scheduler.pending == nil)
    }

    @Test("an item that comes back before it has gone turns round from where it is")
    func returns() async throws {
        let both = #"item "a" module="echo-test"; item "b" module="echo-test""#
        let h = try await started(both, css: EnterExitTests.fade
                                  + "#b:leaving { opacity: 0 } @starting-style { #b { opacity: 0 } }")
        try show(h, #"item "a" module="echo-test""#)
        tick(h, 0.07)
        let gone = try #require(item(h, "b")?.style.opacity)
        #expect(abs(gone - 0.3) < 0.01)

        try show(h, both)
        let back = try #require(item(h, "b"))
        #expect(!back.states.contains(.leaving))
        #expect(abs(back.style.opacity - 0.3) < 0.01, "not from its starting style, and not snapped")
        tick(h, 0.05)
        #expect(abs((item(h, "b")?.style.opacity ?? 0) - 0.65) < 0.01)
        #expect(h.surface.presentations.last?.scene.allItems.filter { $0.name == "b" }.count == 1)
    }

    @Test("a group goes as one, with its items inside it")
    func groups() async throws {
        let h = try await started(#"item "a" module="echo-test"; group "g" { item "x" module="echo-test"; item "y" module="echo-test" }"#,
                                  css: "group { opacity: 1; transition: opacity 100ms linear } #g:leaving { opacity: 0 }"
                                  + " #x:leaving { opacity: 0 }")
        try show(h, #"item "a" module="echo-test""#)
        let scene = try #require(h.surface.presentations.last?.scene)
        #expect(scene.items.map(\.name) == ["a", "g"])
        #expect(scene.items[1].children.map(\.name) == ["x", "y"])
        #expect(scene.allItems.filter { $0.name == "x" }.count == 1)
    }

    @Test("an item leaving a group that stays leaves from inside it")
    func leavesGroup() async throws {
        let h = try await started(#"group "g" { item "x" module="echo-test"; item "y" module="echo-test" }"#,
                                  css: EnterExitTests.fade + "#x:leaving { opacity: 0 }")
        try show(h, #"group "g" { item "y" module="echo-test" }"#)
        let scene = try #require(h.surface.presentations.last?.scene)
        #expect(scene.items.map(\.name) == ["g"])
        #expect(scene.items[0].children.map(\.name) == ["x", "y"])
    }

    @Test("a bar that is not on screen takes the scene without anything leaving")
    func offScreen() async throws {
        let h = try Harness(#"item "a" module="echo-test"; item "b" module="echo-test""#,
                            css: EnterExitTests.fade + "#b:leaving { opacity: 0 }")
        await h.start()
        await h.settle()
        #expect(!h.surface.visible)
        try show(h, #"item "a" module="echo-test""#)
        #expect(item(h, "b") == nil)
    }
}

@Suite("Turning in depth on the layer tree")
@MainActor
struct DepthCompositorTests {
    @Test("a box turned out of the bar's plane is lifted in front of its neighbours, and only then")
    func lifted() throws {
        let tests = CompositorTests()
        tests.commit(try tests.scene(#"item "a" module="text"; item "b" module="text""#,
                                     css: "#a { transform: perspective(40pt) rotateX(30deg) } #b { transform: rotate(10deg) }"))
        #expect(tests.compositor.layer(for: .item("a"))?.zPosition == Motion.lift)
        #expect(tests.compositor.layer(for: .item("b"))?.zPosition == 0)
    }
}
