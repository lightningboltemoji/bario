import AppKit
import Testing
@testable import BarioKit

@Suite("Writes that change nothing")
struct QuietWriteTests {
    @Test("a write that leaves every value as it was invalidates and notifies nothing")
    func noOp() async throws {
        let store = StateStore()
        await store.recordReads(["battery.pct"], for: "summary")
        #expect(await store.merge(.object(["pct": 43, "charging": false]), at: "battery") == ["battery", "summary"])
        #expect(await store.merge(.object(["pct": 43]), at: "battery") == [])
        #expect(await store.replace(.object(["pct": 43, "charging": false]), at: "battery") == [])
        #expect(await store.merge(.object(["gone": .null]), at: "battery") == [], "deleting nothing")

        let stream = await store.changes(matching: "battery.*")
        var iterator = stream.makeAsyncIterator()
        await store.merge(.object(["pct": 43]), at: "battery")
        await store.merge(.object(["pct": 44]), at: "battery")
        #expect(await iterator.next()?.value == .object(["pct": 44]), "the no-op was not announced")
    }

    @Test("a write invalidates the readers of what it changed, not of everything it wrote")
    func precise() async throws {
        let store = StateStore()
        await store.merge(.object(["focus": 1, "moving": false]), at: "emira")
        await store.recordReads(["emira.focus"], for: "names")
        await store.recordReads(["emira.moving"], for: "spinner")
        #expect(await store.merge(.object(["focus": 1, "moving": true]), at: "emira") == ["emira", "spinner"])
    }

    @Test("the paths two values differ at, as shallow as they can be named")
    func differences() {
        let old: JSONValue = ["a": 1, "b": ["c": 1, "d": [1, 2]], "e": "x"]
        let new: JSONValue = ["a": 1, "b": ["c": 2, "d": [1, 3]], "f": true]
        #expect(JSONValue.differences(from: old, to: new, at: "s") == ["s.b.c", "s.b.d", "s.e", "s.f"])
        #expect(JSONValue.differences(from: old, to: old, at: "s") == [])
        #expect(JSONValue.differences(from: nil, to: 1, at: "") == [""])
    }

    @Test("values are watched through every value they pass, a change and its undoing included")
    func watchedValues() async throws {
        let store = StateStore()
        await store.merge(.object(["focus": 1]), at: "emira")
        let stream = await store.values(of: ["emira.focus", "emira.moving"])
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == [.number(1), nil], "where they are now, first")

        await store.merge(.object(["other": 1]), at: "emira")
        await store.merge(.object(["focus": 2]), at: "emira")
        await store.merge(.object(["focus": 1]), at: "emira")
        await store.merge(.object(["moving": true]), at: "emira")
        #expect(await iterator.next() == [.number(2), nil], "an unwatched write is not a yield")
        #expect(await iterator.next() == [.number(1), nil])
        #expect(await iterator.next() == [.number(1), .bool(true)])
    }

    @Test("truthiness")
    func truthy() {
        for value: JSONValue in [true, 1, "x", [1], ["a": 1]] { #expect(value.isTruthy) }
        for value: JSONValue in [false, 0, "", [], [:], .null] { #expect(!value.isTruthy) }
    }
}

@Suite("Sources and modes in the config")
struct ModeConfigTests {
    func message(_ text: String) -> String {
        do {
            _ = try ConfigLoader.parse(text)
            return "parsed, but should not have"
        } catch {
            return "\(error)"
        }
    }

    @Test("a source, a mode, and items shown by it")
    func parses() throws {
        let config = try ConfigLoader.parse("""
        source "emira" module="exec" interval="watch" {
          command "emira" "watch"
        }
        mode "guide" {
          while "emira.moving"
          changed "emira.focus" "emira.displays"
          hold "700ms"
        }
        bar {
          item "app" module="front-app" unless="guide"
          spacer when="guide"
          item "names" module="text" text="…" when="guide"
        }
        """)
        #expect(config.sources.map(\.name) == ["emira"])
        #expect(config.sources[0].moduleName == "exec")
        #expect(config.sources[0].interval == .watch)
        #expect(config.modes == [{
            var mode = ModeConfig(name: "guide", position: config.modes[0].position)
            mode.whilePaths = ["emira.moving"]
            mode.changed = ["emira.focus", "emira.displays"]
            mode.hold = ConfigLoader.parseDuration("700ms")!
            return mode
        }()])
        let items = config.bars[0].items
        #expect(items[0].unless == "guide")
        #expect(items[1].when == "guide")
        #expect(items[2].when == "guide")
    }

    @Test("what is wrong with a source or a mode is said, and where")
    func errors() {
        #expect(message(#"bar { item "a" module="text" when="guide" }"#)
            .contains(#"names a mode "guide" that no mode node declares; there are none"#))
        let bar = #"bar { item "a" module="text" }"#
        #expect(message(#"mode "guide" { hold "1s" }"# + "\n" + bar).contains("has nothing to turn it on"))
        #expect(message(#"mode "g" { changed "x" }; mode "g" { changed "y" }"# + "\n" + bar)
            .contains("two modes called"))
        #expect(message(#"mode "g" { soon "x" }"# + "\n" + bar).contains("expected while, changed or hold"))
        #expect(message(#"source "a" module="exec" { command "x" }"# + "\n" + bar).contains("already has"))
        #expect(message(#"source "s" module="exec" format="{text}" { command "x" }"# + "\n" + bar)
            .contains("is never shown"))
        #expect(message(#"source "s""# + "\n" + bar).contains("source \"s\" needs module="))
    }
}

@Suite("Modes")
@MainActor
struct ModeTests {
    static let checker = Shot.checkerboard(width: 800, height: 48)!
    static let top = #"mode "guide" { changed "src.focus"; hold "700ms" }"#
    static let items = #"item "app" module="echo-test" unless="guide"; item "names" module="echo-test" when="guide""#

    /// Let the store's values reach the tracker, and the frames they cause run.
    func observe(_ h: Harness, _ write: (() async -> Void)? = nil) async {
        let before = h.loop.modeTracker.observations
        await write?()
        for _ in 0..<500 where h.loop.modeTracker.observations == before {
            await Task.yield()
        }
        await h.settle()
    }

    func names(_ h: Harness) -> [String] {
        h.surface.presentations.last?.scene.allItems.map(\.name) ?? []
    }

    func started(_ top: String = ModeTests.top, items: String = ModeTests.items,
                 css: String = "") async throws -> Harness {
        let h = try Harness(items, css: css, top: top)
        await h.start()
        h.loop.setBackdrop(ModeTests.checker, for: 1)
        await observe(h)
        return h
    }

    @Test("a change turns a mode on; it holds for its hold after the last one, and items follow it")
    func changedHolds() async throws {
        let h = try await started()
        await observe(h) { await h.host.store.merge(.object(["focus": 1]), at: "src") }
        #expect(h.loop.modes.isEmpty, "a first value is not a change")
        #expect(names(h) == ["app"])

        await observe(h) { await h.host.store.merge(.object(["focus": 2]), at: "src") }
        #expect(h.loop.modes == ["guide"])
        #expect(names(h) == ["names"])

        h.scheduler.advance(by: 0.5)
        await observe(h) { await h.host.store.merge(.object(["focus": 3]), at: "src") }
        h.scheduler.advance(by: 0.5)
        await h.settle()
        #expect(h.loop.modes == ["guide"], "the second change started the hold again")
        h.scheduler.advance(by: 0.3)
        await h.settle()
        #expect(h.loop.modes.isEmpty)
        #expect(names(h) == ["app"])
    }

    @Test("while holds a mode on for as long as its path is truthy, and the hold starts when it lets go")
    func whileHolds() async throws {
        let h = try await started(#"mode "guide" { while "src.moving"; hold "200ms" }"#)
        await observe(h) { await h.host.store.merge(.object(["moving": true]), at: "src") }
        #expect(h.loop.modes == ["guide"], "no first-value rule for while: it is a state, not a change")
        h.scheduler.advance(by: 5)
        await h.settle()
        #expect(h.loop.modes == ["guide"])

        await observe(h) { await h.host.store.merge(.object(["moving": false]), at: "src") }
        #expect(h.loop.modes == ["guide"])
        h.scheduler.advance(by: 0.25)
        await h.settle()
        #expect(h.loop.modes.isEmpty)
    }

    @Test("a mode is a class on the bar")
    func barClass() async throws {
        let h = try await started(items: #"item "a" module="echo-test""#,
                                  css: "item { opacity: 1 } bar.guide item { opacity: 0.5 }")
        await observe(h) { await h.host.store.merge(.object(["focus": 1]), at: "src") }
        #expect(h.surface.presentations.last?.scene.allItems[0].style.opacity == 1)
        await observe(h) { await h.host.store.merge(.object(["focus": 2]), at: "src") }
        #expect(h.surface.presentations.last?.scene.allItems[0].style.opacity == 0.5)
    }

    @Test("an item a mode leaves out still renders, so it has content the moment it is shown")
    func rendersWhileHidden() async throws {
        let h = try await started()
        await h.host.store.merge(.object(["text": "ready"]), at: "names")
        await h.settle()
        #expect(names(h) == ["app"])
        #expect(h.host.state(for: "names")?.result.content == .text("ready"))

        await observe(h) { await h.host.store.merge(.object(["focus": 1]), at: "src") }
        await observe(h) { await h.host.store.merge(.object(["focus": 2]), at: "src") }
        let node = h.surface.presentations.last?.scene.allItems.first?.content
        if case .text(let text)? = node?.kind { #expect(text == "ready") } else { Issue.record("no text") }
    }
}

/// Polls once, writing `value`; counts renders it should never be asked for.
actor FeedModule: Module {
    private(set) var renders = 0
    func poll() async -> PollResult { PollResult(patch: .object(["value": 1])) }
    func render(_ state: StateReader) async throws -> RenderResult {
        renders += 1
        return RenderResult(content: .text("rendered"))
    }
}
