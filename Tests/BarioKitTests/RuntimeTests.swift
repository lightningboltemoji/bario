import Foundation
import Testing
@testable import BarioKit

@Suite("State store")
struct StateStoreTests {
    @Test("merge, replace and delete")
    func writing() async throws {
        let store = StateStore()
        await store.merge(.object(["pct": 43, "charging": false]), at: "battery")
        #expect(await store.value(at: "battery.pct")?.intValue == 43)

        await store.merge(.object(["pct": 44]), at: "battery")
        #expect(await store.value(at: "battery.pct")?.intValue == 44)
        #expect(await store.value(at: "battery.charging")?.boolValue == false)

        await store.merge(.object(["charging": .null]), at: "battery")
        #expect(await store.value(at: "battery.charging") == nil)

        await store.replace(.object(["pct": 1]), at: "battery")
        #expect(await store.value(at: "battery.pct")?.intValue == 1)
    }

    @Test("a write invalidates exactly the items that read it")
    func readTracking() async throws {
        let store = StateStore()
        await store.recordReads(["battery.pct"], for: "battery")
        await store.recordReads(["wifi.ssid"], for: "wifi")
        await store.recordReads(["battery.pct", "wifi.ssid"], for: "summary")

        #expect(await store.merge(.object(["pct": 50]), at: "battery") == ["battery", "summary"])
        #expect(await store.merge(.object(["ssid": "x"]), at: "wifi") == ["wifi", "summary"])
        #expect(await store.merge(.object(["temp": 3]), at: "weather") == ["weather"])
    }

    @Test("a write to a parent path invalidates a reader of a child path")
    func prefixOverlap() async throws {
        let store = StateStore()
        await store.recordReads(["battery.pct"], for: "battery")
        #expect(await store.merge(.object(["pct": 9]), at: "battery").contains("battery"))
        await store.recordReads(["battery"], for: "battery")
        #expect(await store.merge(.number(9), at: "battery.pct").contains("battery"))
    }

    @Test("a reader records absolute paths for relative reads")
    func reader() async throws {
        let store = StateStore()
        await store.merge(.object(["pct": 43]), at: "battery")
        let reader = await store.reader(for: "battery")
        #expect(reader.value("pct")?.intValue == 43)
        #expect(reader.global("wifi.ssid") == nil)
        #expect(reader.paths == ["battery.pct", "wifi.ssid"])
    }

    @Test("a write that lands while a render runs is caught when the render reports what it read")
    func writesDuringARender() async throws {
        let store = StateStore()
        await store.merge(.object(["pct": 40]), at: "battery")
        let reader = await store.reader(for: "summary")
        _ = reader.global("battery.pct")
        await store.merge(.object(["ssid": "x"]), at: "wifi")
        #expect(await store.recordReads(reader.paths, for: "summary", since: reader.version) == false,
                "an unrelated write is not a reason")
        let again = await store.reader(for: "summary")
        _ = again.global("battery.pct")
        await store.merge(.object(["pct": 41]), at: "battery")
        #expect(await store.recordReads(again.paths, for: "summary", since: again.version),
                "the render showed 40 and the store now says 41")
    }

    @Test("glob subscriptions")
    func topics() {
        #expect(TopicPattern("battery.*").matches("battery.pct"))
        #expect(TopicPattern("battery.*").matches("battery"))
        #expect(!TopicPattern("battery.*").matches("wifi.pct"))
        #expect(TopicPattern("*").matches("anything"))
        #expect(TopicPattern("state:battery").matches("battery"))
        #expect(!TopicPattern("battery").matches("battery.pct"))
    }

    @Test("changes stream what matches")
    func subscriptions() async throws {
        let store = StateStore()
        let stream = await store.changes(matching: "battery.*")
        var iterator = stream.makeAsyncIterator()
        await store.merge(.object(["ssid": "x"]), at: "wifi")
        await store.merge(.object(["pct": 43]), at: "battery")
        let change = await iterator.next()
        #expect(change?.path == "battery")
    }
}

@Suite("Format strings")
struct FormatStringTests {
    func render(_ format: String, _ state: [String: JSONValue]) throws -> Node? {
        try FormatString.parse(format).render { state[$0] }
    }

    @Test("literals and slots")
    func basics() throws {
        #expect(try render("{pct}%", ["pct": 73]) == .row(align: .center, [
            .text("73", classes: ["pct"]), .text("%"),
        ]))
        #expect(try render("hello", [:]) == .text("hello"))
        #expect(try render("{name}", ["name": "Safari"]) == .text("Safari", classes: ["name"]))
    }

    @Test("an icon slot becomes an icon node")
    func icons() throws {
        #expect(try render("{icon}", ["icon": "wifi"]) == .icon("wifi", classes: ["icon"]))
        #expect(try render("{icon} {pct}%", ["icon": "battery.75percent", "pct": 73])
                == .row(align: .center, [
                    .icon("battery.75percent", classes: ["icon"]),
                    .text(" "),
                    .text("73", classes: ["pct"]),
                    .text("%"),
                ]))
        #expect(try render("{status:icon}", ["status": "checkmark.circle"])
                == .icon("checkmark.circle", classes: ["status"]))
    }

    @Test("specs: printf, truncation and date patterns")
    func specs() throws {
        #expect(FormatString.format(.number(0.734), spec: "%.1f") == "0.7")
        #expect(FormatString.format(.number(42), spec: "%03d") == "042")
        #expect(FormatString.format(.string("a very long title"), spec: "8") == "a very …")
        #expect(FormatString.format(.string("short"), spec: "8") == "short")
        let noon = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        #expect(FormatString.format(.number(noon.timeIntervalSince1970), spec: "HH:mm")
                == formatter.string(from: noon))
    }

    @Test("a missing slot renders as nothing")
    func missing() throws {
        #expect(try render("{ssid}", [:]) == nil)
        #expect(try render("[{ssid}]", [:]) == .text("[]"))
    }

    @Test("doubled braces are literal")
    func literalBraces() throws {
        #expect(try render("{{{pct}}}", ["pct": 5]) == .row(align: .center, [
            .text("{"), .text("5", classes: ["pct"]), .text("}"),
        ]))
    }

    @Test("malformed formats are rejected")
    func errors() throws {
        #expect(throws: ModuleError.self) { try FormatString.parse("{unclosed") }
        #expect(throws: ModuleError.self) { try FormatString.parse("stray }") }
        #expect(throws: ModuleError.self) { try FormatString.parse("{}") }
    }

    @Test("slot names become classes the stylesheet can address")
    func classes() throws {
        #expect(FormatString.Slot(name: "pct", spec: nil).className == "pct")
        #expect(FormatString.Slot(name: "time-remaining", spec: nil).className == "remaining")
    }
}

@Suite("Modules")
struct ModuleTests {
    @Test("the clock aligns to the next boundary")
    func clockAlignment() {
        let at = Date(timeIntervalSince1970: 1_700_000_012.4)
        let nextSecond = ClockModule.secondsUntilNextTick(after: at, ticksEverySecond: true)
        #expect(abs(nextSecond - 0.605) < 0.01)
        let nextMinute = ClockModule.secondsUntilNextTick(after: at, ticksEverySecond: false)
        #expect(abs(nextMinute - 27.605) < 0.01)
        #expect(ClockModule.patternHasSeconds("HH:mm:ss"))
        #expect(!ClockModule.patternHasSeconds("EEE d MMM  HH:mm"))
        #expect(!ClockModule.patternHasSeconds("'seconds' HH:mm"))
    }

    @Test("the clock renders its format as a date pattern")
    func clock() async throws {
        let store = StateStore()
        let context = ModuleContext(item: "clock", format: "HH:mm", store: store)
        let clock = ClockModule(context: context)
        let poll = await clock.poll()
        #expect(poll.patch?["now"] != nil)
        await store.merge(poll.patch!, at: "clock")

        let result = try await clock.render(await store.reader(for: "clock"))
        guard case .text(let text)? = result.content?.kind else { Issue.record("not text"); return }
        #expect(text.count == 5 && text.contains(":"))
    }

    @Test("a data item renders what was pushed to it")
    func data() async throws {
        let store = StateStore()
        let context = ModuleContext(item: "ci", config: .object(["hidden-until-set": true]),
                                    format: "{icon} {status}", store: store)
        let module = DataModule(context: context)

        let empty = try await module.render(await store.reader(for: "ci"))
        #expect(!empty.visible)

        await store.merge(.object(["icon": "checkmark.circle", "status": "green"]), at: "ci")
        let filled = try await module.render(await store.reader(for: "ci"))
        #expect(filled.visible)
        #expect(filled.content?.children.count == 3)
    }

    @Test("content written in the config is what a text item shows, and a data item until a push")
    func configContent() async throws {
        let store = StateStore()
        let tree = Node.row(gap: 2, [.icon("wifi"), .text("home")])
        let text = TextModule(context: ModuleContext(item: "net", content: tree, store: store))
        #expect(try await text.render(await store.reader(for: "net")).content == tree)

        let data = DataModule(context: ModuleContext(item: "wave", config: .object(["hidden-until-set": true]),
                                                     content: tree, store: store))
        let before = try await data.render(await store.reader(for: "wave"))
        #expect(before.content == tree && before.visible, "shown from the start, however it is configured")
        await store.merge(.object(["content": .object(["text": "pushed"])]), at: "wave")
        #expect(try await data.render(await store.reader(for: "wave")).content == .text("pushed"))
    }

    @Test("a pushed content tree beats the format string")
    func pushedContent() async throws {
        let store = StateStore()
        let module = DataModule(context: ModuleContext(item: "ci", format: "{status}", store: store))
        await store.merge(.object(["content": .object(["text": "pushed"]), "classes": .array([.string("ok")])]),
                          at: "ci")
        let result = try await module.render(await store.reader(for: "ci"))
        #expect(result.content == .text("pushed"))
        #expect(result.classes == ["ok"])
    }
}

@Suite("Module host")
struct ModuleHostTests {
    @Test("an unknown module becomes an error bubble, not a dead bar")
    @MainActor
    func unknownModule() async throws {
        ModuleRegistry.registerBuiltIns()
        let host = ModuleHost()
        let config = try ConfigLoader.parse(#"bar { item "x" module="nope" }"#)
        await host.load(config.bars[0].items)
        await host.renderPending()
        let state = host.state(for: "x")
        #expect(state?.error?.contains("no module called 'nope'") == true)
        #expect(state?.result.classes == ["error"])
    }

    @Test("a module over its budget keeps its last content and goes stale")
    @MainActor
    func budget() async throws {
        ModuleRegistry.register("slow-test") { _ in SlowModule() }
        let host = ModuleHost()
        let config = try ConfigLoader.parse(#"bar { item "slow" module="slow-test" }"#)
        await host.load(config.bars[0].items)

        await host.renderPending()
        #expect(host.state(for: "slow")?.result.content == .text("first"))
        #expect(host.state(for: "slow")?.stale == false)

        await host.store.merge(.object(["tick": 1]), at: "slow")
        host.markDirty(["slow"])
        await host.renderPending()
        #expect(host.state(for: "slow")?.stale == true)
        #expect(host.state(for: "slow")?.result.content == .text("first"))
        await host.shutdown()
    }

    @Test("only dirty items re-render")
    @MainActor
    func caching() async throws {
        ModuleRegistry.registerBuiltIns()
        ModuleRegistry.register("counting-test") { _ in CountingModule() }
        let host = ModuleHost()
        let config = try ConfigLoader.parse("""
        bar { item "a" module="counting-test"
              item "b" module="counting-test" }
        """)
        await host.load(config.bars[0].items)
        await host.renderPending()
        #expect(host.needsRender == false)

        await host.store.merge(.object(["x": 1]), at: "a")
        await host.renderPending()

        guard let a = host.state(for: "a")?.result.content,
              let b = host.state(for: "b")?.result.content else { Issue.record("no content"); return }
        #expect(a == .text("2"))            // rendered twice
        #expect(b == .text("1"))            // untouched
        await host.shutdown()
    }

    @Test("a render that read another item's state renders again if that state changed meanwhile")
    @MainActor
    func writeDuringFirstRender() async throws {
        ModuleRegistry.register("reads-other-test") { context in ReadsOtherModule(store: context.store) }
        let host = ModuleHost()
        let config = try ConfigLoader.parse(#"bar { item "summary" module="reads-other-test" }"#)
        await host.load(config.bars[0].items)
        await host.firstPolls(within: 1)
        await host.store.merge(.object(["value": 1]), at: "other")
        // The render writes 2 after reading 1. Nothing is recorded as read yet, so that write
        // dirties nobody by itself.
        host.startRenders()
        await host.finishRenders()
        #expect(host.state(for: "summary")?.result.content == .text("1"))
        #expect(host.needsRender, "the render is already out of date")
        await host.renderPending()
        #expect(host.state(for: "summary")?.result.content == .text("2"))
        await host.shutdown()
    }

    @Test("a module that never finishes starting holds up nothing else, and not the next reload")
    @MainActor
    func stuckStart() async throws {
        ModuleRegistry.register("stuck-start-test") { _ in StuckStartModule() }
        let host = ModuleHost()
        let config = try ConfigLoader.parse(#"bar { item "stuck" module="stuck-start-test"; item "t" module="text" text="hi" }"#)
        let started = Date()
        await host.load(config.bars[0].items)
        await host.renderPending()
        #expect(host.state(for: "t")?.result.content == .text("hi"))
        let next = try ConfigLoader.parse(#"bar { item "t" module="text" text="bye" }"#)
        await host.load(next.bars[0].items)
        await host.renderPending()
        #expect(host.state(for: "t")?.result.content == .text("bye"))
        // The stuck module sleeps for a minute, so anything short of that says we did not wait
        // for it. The bound is loose on purpose: every `@MainActor` test in the run shares this
        // thread, and on a small CI runner the lines above can sit descheduled for seconds.
        #expect(Date().timeIntervalSince(started) < 10)
        await host.shutdown()
    }

    @Test("a first render can wait for the first poll, so it is not a placeholder")
    @MainActor
    func firstPolls() async throws {
        ModuleRegistry.register("polled-test") { _ in PolledModule(delay: 0.05) }
        // A deadline far enough off that a busy test run cannot reach it first.
        let host = ModuleHost(firstStateDeadline: 5)
        let config = try ConfigLoader.parse(#"bar { item "p" module="polled-test" }"#)
        await host.load(config.bars[0].items)
        await host.firstPolls(within: 2)
        await host.renderPending()
        #expect(host.state(for: "p")?.result.content == .text("polled"))
        await host.shutdown()
    }

    @Test("waiting for first polls gives up at the deadline")
    @MainActor
    func firstPollDeadline() async throws {
        // A poll far longer than the run: whatever else delays the lines below, the answer this
        // test is about — that we did not wait for the poll — cannot arrive on its own.
        ModuleRegistry.register("stuck-poll-test") { _ in PolledModule(delay: 60) }
        let host = ModuleHost()
        let config = try ConfigLoader.parse(#"bar { item "p" module="stuck-poll-test" }"#)
        await host.load(config.bars[0].items)
        let start = Date()
        await host.firstPolls(within: 0.1)
        #expect(Date().timeIntervalSince(start) < 5)
        await host.renderPending()
        #expect(host.state(for: "p")?.result.content == nil)
        await host.shutdown()
    }
}

/// Reads another item's state, and the first time, has it change before the render returns:
/// a write landing mid-render, without depending on timing.
actor ReadsOtherModule: Module {
    private let store: StateStore
    private var first = true
    init(store: StateStore) { self.store = store }

    func render(_ state: StateReader) async throws -> RenderResult {
        let value = state.global("other.value")?.intValue ?? 0
        if first {
            first = false
            await store.merge(.object(["value": 2]), at: "other")
        }
        return RenderResult(content: .text("\(value)"))
    }
}

/// A module whose `start` does not come back for a very long time.
actor StuckStartModule: Module {
    func start() async {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
    }

    func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: .text("stuck"))
    }
}

actor PolledModule: Module {
    private let delay: Double
    init(delay: Double) { self.delay = delay }

    func poll() async -> PollResult {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        return PollResult(patch: .object(["word": "polled"]))
    }

    func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: state.value("word")?.stringValue.map { Node.text($0) })
    }
}

actor SlowModule: Module {
    private var calls = 0
    func render(_ state: StateReader) async throws -> RenderResult {
        calls += 1
        if calls == 1 { return RenderResult(content: .text("first")) }
        try await Task.sleep(nanoseconds: 400_000_000)
        return RenderResult(content: .text("late"))
    }
}

actor CountingModule: Module {
    private var calls = 0
    func render(_ state: StateReader) async throws -> RenderResult {
        calls += 1
        _ = state.own
        return RenderResult(content: .text("\(calls)"))
    }
}

@Suite("Event bus")
struct EventBusTests {
    @Test("a module hears only the topics it subscribed to")
    func subscriptions() {
        let bus = EventBus()
        bus.subscribe(item: "weather", topic: "state:location.*")
        bus.subscribe(item: "weather", topic: "event:refresh")
        bus.subscribe(item: "ci", topic: "event:*")

        #expect(bus.subscribers(of: "state:location.city") == ["weather"])
        #expect(bus.subscribers(of: "event:refresh") == ["ci", "weather"])
        #expect(bus.subscribers(of: "event:anything") == ["ci"])
        #expect(bus.subscribers(of: "state:battery.pct").isEmpty)
    }

    @Test("posting reaches the handler with the item that emitted it")
    func posting() {
        let bus = EventBus()
        let seen = Seen()
        bus.onPost { event, origin in seen.record(event.name, origin) }
        bus.post(ModuleEvent(name: "refresh"), from: "weather")
        #expect(seen.values == [["refresh", "weather"]])
    }

    @Test("retiring an item forgets what it asked for")
    func forgetting() {
        let bus = EventBus()
        bus.subscribe(item: "weather", topic: "event:*")
        bus.forget("weather")
        #expect(bus.isEmpty)
        #expect(bus.subscribers(of: "event:refresh").isEmpty)
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[String]] = []
        func record(_ name: String, _ origin: String?) {
            lock.lock(); stored.append([name, origin ?? ""]); lock.unlock()
        }
        var values: [[String]] { lock.lock(); defer { lock.unlock() }; return stored }
    }
}

@Suite("Module subscriptions")
struct ModuleSubscriptionTests {
    @Test("an emitted event reaches only the modules that subscribed")
    @MainActor
    func delivery() async throws {
        ModuleRegistry.register("listener-test") { context in ListeningModule(context: context) }
        let host = ModuleHost()
        let config = try ConfigLoader.parse("""
        bar { item "a" module="listener-test"
              item "b" module="listener-test" }
        """)
        await host.load(config.bars[0].items)
        host.events.subscribe(item: "a", topic: "event:refresh")

        await host.deliver(ModuleEvent(name: "refresh"), topic: "event:refresh")
        #expect(await host.store.value(at: "a.heard")?.stringValue == "refresh")
        #expect(await host.store.value(at: "b.heard") == nil)
        await host.shutdown()
    }
}

actor ListeningModule: Module {
    private let context: ModuleContext
    init(context: ModuleContext) { self.context = context }

    func onEvent(_ event: ModuleEvent) async -> JSONValue? {
        .object(["heard": .string(event.name)])
    }

    func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: .text(state.value("heard")?.stringValue ?? "-"))
    }
}
