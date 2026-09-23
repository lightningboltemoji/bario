import AppKit
import Testing
@testable import BarioKit

/// Increment 20: windows, content templates, graphs that scroll ([20-stats-widgets.md]).
@Suite("Sampling")
struct SamplingTests {
    func sampling(_ options: [String: JSONValue], interval: Double? = nil,
                  defaultWindows: [String] = []) throws -> Sampling {
        try Sampling(context: ModuleContext(item: "cpu", config: .object(options),
                                            interval: interval.map(Interval.seconds), store: StateStore()),
                     defaultInterval: 2, defaultWindows: defaultWindows)
    }

    @Test("windows and history are durations, turned into samples at the item's interval")
    func durations() throws {
        let s = try sampling(["windows": "5s 1m", "history": "60s"], interval: 0.5)
        #expect(s.interval == 0.5)
        #expect(s.windows == [.init(name: "5s", samples: 10), .init(name: "1m", samples: 120)])
        #expect(s.history == 120)
        #expect(s.depth == 121, "one more snapshot than the longest window, for the difference")
    }

    @Test("a window rounds to the nearest whole number of samples")
    func rounding() throws {
        let s = try sampling(["windows": "5s"])
        #expect(s.interval == 2, "the module's default, when the item names none")
        #expect(s.windows[0].samples == 3)
    }

    @Test("windows come as a string, a list, or bare seconds")
    func forms() throws {
        #expect(try sampling(["windows": "5s, 1m"]).windows.map(\.name) == ["5s", "1m"])
        #expect(try sampling(["windows": .array(["5s", 60])]).windows.map(\.name) == ["5s", "60s"])
        #expect(try sampling([:], defaultWindows: ["5s", "1m"]).windows.map(\.name) == ["5s", "1m"])
        #expect(try sampling(["windows": "10s"], defaultWindows: ["5s"]).windows.map(\.name) == ["10s"])
    }

    @Test("history is a number of samples as before, or a duration")
    func history() throws {
        #expect(try sampling(["history": 10]).history == 10)
        #expect(try sampling(["history": "1m"], interval: 1).history == 60)
        #expect(try sampling([:]).history == 32)
    }

    @Test("a window shorter than the interval is refused, naming both")
    func tooShort() throws {
        let error = #expect(throws: ModuleError.self) { try sampling(["windows": "1s"], interval: 2) }
        #expect(error?.description.contains("1s") == true)
        #expect(error?.description.contains("2s") == true)
        #expect(throws: ModuleError.self) { try sampling(["windows": "soon"]) }
        #expect(throws: ModuleError.self) { try sampling(["history": "later"]) }
    }

    @Test("a ring reaches back as far as it has")
    func ring() {
        var ring = Ring<Int>(capacity: 3)
        #expect(ring.back(1) == nil)
        for n in 1...5 { ring.append(n) }
        #expect(ring.elements == [3, 4, 5])
        #expect(ring.back(0) == 5)
        #expect(ring.back(1) == 4)
        #expect(ring.back(10) == 3, "a window not yet full reports over what there is")
        #expect(Array(ring.suffix(2)) == [4, 5])
    }

    @Test("history is always full length, null in front until it fills")
    func padded() {
        var history = History(capacity: 4)
        history.append(0.5)
        #expect(history.padded == .array([.null, .null, .null, .number(0.5)]))
    }

    @Test("byte counters that wrap still only grow")
    func byteCounter() {
        var counter = ByteCounter()
        let near = UInt32.max - 99
        #expect(counter.read(["en0": (near, 10)], counting: ["en0"]) == (0, 0), "the first read is a baseline")
        let wrapped = counter.read(["en0": (50, 20)], counting: ["en0"])
        #expect(wrapped.rx == 150)
        #expect(wrapped.tx == 10)
        // An interface that appears adds nothing; one not counted adds nothing.
        let more = counter.read(["en0": (60, 20), "en1": (1_000_000, 0), "utun0": (9, 9)],
                                counting: ["en0", "en1"])
        #expect(more.rx == 160)
        // Once seen, it counts from there.
        #expect(counter.read(["en0": (60, 20), "en1": (1_000_500, 0)], counting: ["en0", "en1"]).rx == 660)
    }

    @Test("a rate is bytes over the time between two snapshots")
    func rates() {
        let rate = NetModule.rate(.init(rx: 0, tx: 100, at: 10), .init(rx: 4000, tx: 100, at: 12))
        #expect(rate.rx == 2000)
        #expect(rate.tx == 0)
        #expect(NetModule.rate(.init(rx: 0, tx: 0, at: 1), .init(rx: 5, tx: 5, at: 1)) == (0, 0))
    }

    @Test("a CPU window is the difference across it, not an average of averages")
    func cpuWindow() {
        var ring = Ring<CPUModule.Ticks>(capacity: 4)
        // Busy 100% for one sample, then idle for two.
        ring.append(.init(user: 0, system: 0, idle: 0, nice: 0))
        ring.append(.init(user: 300, system: 0, idle: 0, nice: 0))
        ring.append(.init(user: 300, system: 0, idle: 100, nice: 0))
        ring.append(.init(user: 300, system: 0, idle: 200, nice: 0))
        let latest = ring.latest!
        #expect(CPUModule.delta(ring.back(1)!, latest).load == 0)
        // Three samples back: 300 busy ticks of 500. The mean of per-sample loads would be 1/3.
        #expect(abs(CPUModule.delta(ring.back(3)!, latest).load - 0.6) < 0.0001)
    }

    @Test("a memory window is the mean of its samples")
    func memWindow() {
        #expect(abs(MemModule.mean([0.2, 0.4, 0.6]) - 0.4) < 1e-12)
        #expect(MemModule.mean([]) == 0)
    }

    @Test("thresholds set one class, never both")
    func thresholds() {
        let t = Thresholds(ModuleContext(item: "cpu", config: .object(["warn": 70, "critical": 90]),
                                         store: StateStore()))
        #expect(t.classes(50) == [])
        #expect(t.classes(70) == ["warn"])
        #expect(t.classes(95) == ["critical"])
        #expect(t.classes(nil) == [])
    }
}

@Suite("Content templates")
struct ContentTemplateTests {
    func template(_ json: String) throws -> ContentTemplate? {
        let template = try ContentTemplate(JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        return template.hasSlots ? template : nil
    }

    @Test("a whole slot keeps its value's type; any other string formats")
    func filling() throws {
        let t = try #require(try template(#"""
            {"row": {"children": [
              {"graph": {"values": "{history}", "max": 1}},
              {"text": "{load:%3.0f}% of {cores}"},
              {"meter": "{fraction}"}
            ]}}
            """#))
        let state: [String: JSONValue] = [
            "history": .array([.null, .number(0.5)]), "load": .number(7), "cores": .number(8),
            "fraction": .number(0.25),
        ]
        let node = try t.render { state[$0] }
        #expect(node == .row([
            Node(.graph(Graph(values: [nil, 0.5], max: 1))),
            .text("  7% of 8"),
            Node(.meter(Meter(value: 0.25))),
        ]))
    }

    @Test("a tree with no slots is not a template")
    func plain() throws {
        #expect(try template(#"{"text": "hello"}"#) == nil)
        #expect(try template(#"{"text": "{{literal}}"}"#) == nil, "escaped braces are text")
        let escaped = try ContentTemplate(.object(["text": "{{literal}}"]))
        #expect(escaped.plain == .object(["text": "{literal}"]), "and unescaped, as in a format")
    }

    @Test("escaped braces stay literal inside a template")
    func escapes() throws {
        let t = try #require(try template(#"{"row": [{"text": "{{x}}"}, {"text": "{x}"}]}"#))
        #expect(try t.render { _ in .string("1") } == .row([.text("{x}"), .text("1")]))
    }

    @Test("classes and ids can come from state")
    func classes() throws {
        let t = try #require(try template(#"{"text": "{used}", "class": "{pressure}"}"#))
        let node = try t.render { $0 == "pressure" ? .string("warn") : .string("11 GB") }
        #expect(node == .text("11 GB", classes: ["warn"]))
    }

    @Test("a missing value is empty text, and a missing array fails to decode with a message")
    func missing() throws {
        #expect(try #require(try template(#"{"text": "{nope}"}"#)).render { _ in nil } == .text(""))
        let graph = try #require(try template(#"{"graph": {"values": "{nope}"}}"#))
        let error = #expect(throws: ModuleError.self) { try graph.render { _ in nil } }
        #expect(error?.description.contains("values") == true)
    }

    @Test("a malformed slot is refused when the config loads")
    func malformed() {
        #expect(throws: (any Error).self) { try template(#"{"text": "{oops"}"#) }
    }

    @Test("rendering records what it read, so the item re-renders when that changes")
    func tracking() throws {
        let t = try #require(try template(#"{"row": [{"text": "{load}"}, {"graph": "{history}"}]}"#))
        let reader = StateReader(root: .object(["cpu": .object(["load": 5, "history": .array([1, 2])])]),
                                 item: "cpu")
        _ = try t.render(reader)
        #expect(reader.paths == ["cpu.load", "cpu.history"])
    }

    @Test("a content block with slots loads as a template; siblings without are still checked")
    func loading() throws {
        let config = try ConfigLoader.parse(#"""
            bar {
              item "cpu" module="cpu" {
                content {
                  row {
                    graph values="{history}" kind="area"
                    text "{load}%"
                  }
                }
              }
              item "plain" module="text" {
                content { text "hi" }
              }
            }
            """#)
        let items = config.bars[0].items
        #expect(items[0].template != nil)
        #expect(items[0].content == nil)
        #expect(items[1].content == .text("hi"))
        #expect(items[1].template == nil)

        // A static sibling beside a templated one is still decoded, and its error still found.
        #expect(throws: KDLError.self) {
            try ConfigLoader.parse(#"""
                bar { item "x" module="cpu" { content { row { text "{load}"; meter } } } }
                """#)
        }
        #expect(throws: KDLError.self) {
            try ConfigLoader.parse(#"bar { item "x" module="cpu" { content { text "{load" } } }"#)
        }
    }

    @Test("byte counts and rates format to units, rates to a fixed width")
    func specs() {
        #expect(FormatString.format(.number(11_200_000_000), spec: "bytes") == "11 GB")
        #expect(FormatString.format(.number(0), spec: "rate") == "\u{2007}\u{2007}\u{2007}0 B/s")
        for value in [0.0, 12, 999.7, 1234, 12_345, 123_456, 9_960, 1_234_567] {
            #expect(Humanise.rate(value).count == 8, "\(value) → \(Humanise.rate(value))")
        }
        #expect(Humanise.bytes(999.7, perSecond: true) == "1.0 kB/s")
        #expect(Humanise.bytes(9_960) == "10 kB")
        #expect(FormatString.format(.string("x"), spec: "rate") == "")
    }
}

@Suite("Stats presets")
struct StatsPresetTests {
    func run(_ module: String, _ options: [String: JSONValue], polls: Int = 2) async throws
        -> (RenderResult, JSONValue) {
        ModuleRegistry.registerBuiltIns()
        let store = StateStore()
        let context = ModuleContext(item: module, config: .object(options), interval: .seconds(0.5),
                                    store: store)
        let instance = try ModuleRegistry.make(module, context: context)
        for _ in 0..<polls {
            if let patch = await instance.poll().patch { await store.merge(patch, at: module) }
        }
        let result = try await instance.render(await store.reader(for: module))
        return (result, await store.value(at: module) ?? .null)
    }

    @Test("every preset of every stats module renders", arguments: [
        ("cpu", "stacked"), ("cpu", "graph"), ("net", "stacked"), ("net", "graph"),
        ("mem", "stacked"), ("mem", "meter"), ("mem", "graph"),
    ])
    func presets(module: String, preset: String) async throws {
        let (result, _) = try await run(module, ["preset": .string(preset), "scroll": "smooth"])
        let content = try #require(result.content)
        #expect(content.classes.contains(preset), "the root carries the preset's name as a class")
        if preset == "stacked" { #expect(content.children.count == 2) }
        if preset == "graph" {
            guard case .graph(let graph) = content.children[0].kind else {
                Issue.record("a graph preset starts with its graph"); return
            }
            #expect(graph.scroll == .smooth, "the item's scroll= reaches the preset's graph")
            #expect(graph.kind == .area)
        }
    }

    @Test("stacked cpu shows a line per window")
    func cpuStacked() async throws {
        let (result, state) = try await run("cpu", ["preset": "stacked", "windows": "1s 2s 3s"])
        #expect(result.content?.children.count == 3)
        #expect(state["load-1s"] != nil && state["load-3s"] != nil)
        #expect(result.tooltip?.contains("3s:") == true)
    }

    @Test("windows reach every stats module's state")
    func windowKeys() async throws {
        let (_, net) = try await run("net", ["windows": "1s"])
        #expect(net["rx-1s"] != nil && net["tx-1s"] != nil)
        #expect(net["rx-history"]?.arrayValue?.count == 32)
        let (_, mem) = try await run("mem", ["windows": "1s"])
        #expect((mem["pct-1s"]?.doubleValue ?? -1) > 0)
        #expect(["normal", "warn", "critical"].contains(mem["pressure"]?.stringValue ?? ""))
        #expect(mem["swap-used"]?.doubleValue != nil)
    }

    @Test("a preset beside a format, an unknown preset, or a bad graph kind is a config error")
    func errors() async throws {
        ModuleRegistry.registerBuiltIns()
        func make(_ options: [String: JSONValue], format: String? = nil) throws {
            _ = try ModuleRegistry.make("cpu", context: ModuleContext(item: "cpu", config: .object(options),
                                                                      format: format, store: StateStore()))
        }
        #expect(throws: ModuleError.self) { try make(["preset": "graph"], format: "{load}") }
        let unknown = #expect(throws: ModuleError.self) { try make(["preset": "pie"]) }
        #expect(unknown?.description.contains("stacked") == true, "the error lists the presets there are")
        #expect(throws: ModuleError.self) { try make(["preset": "graph", "kind": "pie"]) }
        #expect(throws: ModuleError.self) { try make(["preset": "graph", "scroll": "fast"]) }
    }

    @Test("a stats item's own content block renders from its state")
    func ownContent() async throws {
        let template = try ContentTemplate(.object(["text": "{load}/{load-1s}"]))
        let store = StateStore()
        let module = try CPUModule(context: ModuleContext(item: "cpu", config: .object(["windows": "1s"]),
                                                          template: template, interval: .seconds(1),
                                                          store: store))
        if let patch = await module.poll().patch { await store.merge(patch, at: "cpu") }
        let result = try await module.render(await store.reader(for: "cpu"))
        #expect(result.content == .text("0/0"))
    }

    @Test("net counts the primary interface unless told otherwise")
    func primary() async throws {
        let (_, state) = try await run("net", [:])
        if let name = NetModule.primaryInterface() {
            #expect(state["interface"]?.stringValue == name)
        } else {
            #expect(state["interface"] == nil, "offline, there is nothing to count")
        }
        let (_, all) = try await run("net", ["interface": "all"])
        #expect(all["interface"] == nil)
    }
}

@Suite("Graphs")
@MainActor
struct GraphTests {
    @Test("graph values may have gaps, and kind, floor and scroll round trip")
    func decoding() throws {
        let json = #"{"graph": {"values": [null, 1, 2], "kind": "bars", "floor": 10, "scroll": "smooth"}}"#
        let node = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        let graph = Graph(values: [nil, 1, 2], floor: 10, kind: .bars, scroll: .smooth)
        #expect(node == Node(.graph(graph)))
        #expect(try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(node)) == node)
        #expect(try JSONDecoder().decode(Node.self, from: Data(#"{"graph": [1, null]}"#.utf8))
                == Node(.graph(Graph(values: [1, nil]))))

        let bad = #"{"graph": {"values": [], "kind": "pie"}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Node.self, from: Data(bad.utf8)) }
    }

    @Test("the top of a graph is its max, else its peak, but never below its floor")
    func ceiling() {
        #expect(Graph(values: [1, 3, nil]).ceiling == 3)
        #expect(Graph(values: [1, 3], floor: 10).ceiling == 10)
        #expect(Graph(values: [1, 30], floor: 10).ceiling == 30)
        #expect(Graph(values: [1, 30], max: 5, floor: 10).ceiling == 5)
        #expect(Graph(values: [nil, nil]).ceiling == 0)
    }

    @Test("a step spans the frame; bars are a step wide; smooth hides the newest past the edge")
    func steps() {
        let five: [Double?] = [1, 2, 3, 4, 5]
        #expect(NodeRasterizer.graphStep(Graph(values: five), width: 40) == 10)
        #expect(NodeRasterizer.graphStep(Graph(values: five, kind: .bars), width: 40) == 8)
        #expect(NodeRasterizer.graphStep(Graph(values: five, scroll: .smooth), width: 30) == 10)
        #expect(NodeRasterizer.graphStep(Graph(values: [1]), width: 40) == 0)
    }

    /// Ink in the lower and upper halves of a 40×20 graph of a constant half-height value.
    func ink(_ kind: GraphKind) throws -> (low: Double, high: Double) {
        let rasterizer = NodeRasterizer(resolver: ColorResolver(dark: false), scale: 1)
        var style = Style()
        style.fill = .rgba(RGBA(r: 1, g: 0, b: 0))
        let frame = CGRect(x: 0, y: 0, width: 40, height: 20)
        let image = try #require(rasterizer.image(covering: frame) { ctx in
            rasterizer.drawGraph(Graph(values: Array(repeating: 0.5, count: 5), max: 1, kind: kind),
                                 in: frame, style: style, colors: ColorResolver(dark: false), ctx: ctx)
        })
        let data = try #require(image.dataProvider?.data) as Data
        let middle = image.height / 2
        var low = 0.0, high = 0.0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let alpha = Double(data[y * image.bytesPerRow + x * 4 + 3]) / 255
                // Rows run top-down in memory; the graph's baseline is at the bottom.
                if y >= middle + 2 { low += alpha } else if y < middle - 2 { high += alpha }
            }
        }
        return (low, high)
    }

    @Test("an area and bars fill under the values, a line does not")
    func kinds() throws {
        for kind in [GraphKind.area, .bars] {
            let ink = try ink(kind)
            #expect(ink.low > 200, "\(kind) fills below its values: \(ink)")
            #expect(ink.high < 1, "\(kind) leaves the space above them empty")
        }
        let line = try ink(.line)
        #expect(line.low < 1 && line.high < 1, "a line at half height stays at half height")
    }
}

@Suite("Smooth graphs")
@MainActor
struct SmoothGraphTests {
    let host = CALayer()
    let compositor: Compositor

    init() { compositor = Compositor(host: host) }

    func commit(_ values: [Double?]) throws {
        let config = try ConfigLoader.parse(#"bar { item "g" module="text" }"#)
        let sheet = try Stylesheet.parse("bar { padding: 0 } item { padding: 0; background: none }")
        let display = DisplayInfo(displayID: 1, name: "T", frame: CGRect(x: 0, y: 0, width: 200, height: 900),
                                  scale: 2, stripHeight: 24)
        let graph = Node(.graph(Graph(values: values, width: 40, max: 1, kind: .area, scroll: .smooth)))
        let states = ["g": ModuleHost.ItemState(result: RenderResult(content: graph), rendered: true)]
        let scene = SceneBuilder(cascade: Cascade(stylesheet: sheet), metrics: FixedMetrics())
            .build(bar: config.bars[0], display: display, items: config.bars[0].items, states: states)
        compositor.commit(Presentation(scene: scene, hole: Hole(), isMoving: false),
                          inputs: Compositor.Inputs(backdrop: BackdropImage(), resolver: ColorResolver(dark: false),
                                                    scale: 2),
                          sceneChanged: true)
    }

    @Test("a smooth graph is a strip one step wider than a clip, and slides from its second change")
    func slides() throws {
        try commit([nil, nil, 0.2, 0.4, 0.6])
        let record = try #require(compositor.node(.node(item: "g", key: .path([]))))
        #expect(record.role == .scroller)
        let clip = try #require(record.leaf)
        let strip = try #require(record.inner)
        #expect(clip.masksToBounds)
        #expect(strip.superlayer === clip)
        // 5 values, 3 visible spans across 40pt: the strip reaches one 13⅓pt step further, and
        // its stroke's overhang past that.
        let reach = Double(strip.frame.maxX - clip.frame.maxX)
        #expect(reach >= 40.0 / 3 && reach < 40.0 / 3 + 4)
        #expect(strip.animation(forKey: "bario.scroll") == nil, "one set of values has no period yet")

        try commit([nil, 0.2, 0.4, 0.6, 0.8])
        let slide = try #require(strip.animation(forKey: "bario.scroll") as? CABasicAnimation)
        #expect(slide.keyPath == "transform.translation.x")
        #expect((slide.toValue as? Double).map { abs($0 + 40.0 / 3) < 0.01 } == true)

        // The same values again (a style change, say) do not restart the slide.
        let slidAt = record.slidAt
        try commit([nil, 0.2, 0.4, 0.6, 0.8])
        #expect(record.slidAt == slidAt)
    }
}

@Suite("Content structure in the stylesheet")
struct ContentStructureTests {
    @Test("a content node knows its place among its siblings, as an item does")
    func structural() throws {
        let config = try ConfigLoader.parse(#"bar { item "cpu" module="text" }"#)
        let sheet = try Stylesheet.parse("""
            text { font-size: 10pt }
            .stacked text:first-child { font-size: 11pt }
            .stacked text:last-child { font-size: 9pt }
            text:only-child { font-size: 14pt }
            """)
        let content = Node.row([.column([.text("5s"), .text("1m")], classes: ["stacked"]), .row([.text("x")])])
        let states = ["cpu": ModuleHost.ItemState(result: RenderResult(content: content), rendered: true)]
        let styled = Styler(cascade: Cascade(stylesheet: sheet))
            .style(bar: config.bars[0], items: config.bars[0].items, states: states)
        let root = try #require(styled.items.first?.content)
        let lines = root.children[0].children
        #expect(lines[0].style.font.size == 11)
        #expect(lines[1].style.font.size == 9)
        #expect(root.children[1].children[0].style.font.size == 14)
    }
}
