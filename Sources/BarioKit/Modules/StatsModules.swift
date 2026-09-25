import Darwin
import Foundation
import SystemConfiguration

// `net`, `cpu` and `mem`: the three genuinely sampled modules. Each keeps a ring of raw
// snapshots as deep as its longest window, so a window is the newest snapshot against one that
// many samples back, exactly, and a per-sample history for graphs. How often, which windows and
// how much history are all the item's config ([20-stats-widgets.md]).

/// Interface byte counters from `getifaddrs`, sampled on an interval. Genuinely polled: there
/// is no notification for "more bytes arrived".
public actor NetModule: Module {
    public enum Selection: Sendable, Equatable {
        /// The interface the system routes through, followed as it changes.
        case primary
        /// Every interface but loopback.
        case all
        case named(String)
    }

    struct Snapshot: Sendable {
        var rx: Double
        var tx: Double
        var at: Double
    }

    private let context: ModuleContext
    private let view: StatsRenderer
    private let sampling: Sampling
    private let selection: Selection
    private var snapshots: Ring<Snapshot>
    private var counter = ByteCounter()
    private var rxHistory: History
    private var txHistory: History
    private var primary: (name: String?, checkedAt: Double)?

    /// How long a primary interface is trusted before the dynamic store is asked again.
    static let primaryRecheck: Double = 5

    public init(context: ModuleContext) throws {
        self.context = context
        let sampling = try Sampling(context: context, defaultInterval: 2)
        self.sampling = sampling
        self.view = try StatsRenderer(context, module: "net", format: "↓{rx-human} ↑{tx-human}",
                                      fallback: "rx-human", presets: [
            "stacked": """
                column class="stacked" align="end" {
                  text "↑{tx:rate}"
                  text "↓{rx:rate}"
                }
                """,
            "graph": """
                row class="graph" align="center" {
                  graph values="{rx-history}" floor=100000 \(try StatsRenderer.graph(context))
                  text "↓{rx:rate}"
                }
                """,
        ])
        switch context.string("interface") {
        case nil, "primary"?: selection = .primary
        case "all"?: selection = .all
        case let name?: selection = .named(name)
        }
        self.snapshots = Ring(capacity: sampling.depth)
        self.rxHistory = History(capacity: sampling.history)
        self.txHistory = History(capacity: sampling.history)
    }

    public func poll() async -> PollResult {
        let now = ProcessInfo.processInfo.systemUptime
        let raw = NetModule.rawCounters()
        let interfaces = counted(raw, at: now)
        let totals = counter.read(raw, counting: interfaces)
        snapshots.append(Snapshot(rx: totals.rx, tx: totals.tx, at: now))

        var patch: [String: JSONValue] = [
            "rx-total": .number(raw.filter { interfaces.contains($0.key) }.values.reduce(0) { $0 + Double($1.rx) }),
            "tx-total": .number(raw.filter { interfaces.contains($0.key) }.values.reduce(0) { $0 + Double($1.tx) }),
            "icon": .string("network"),
        ]
        if case .primary = selection { patch["interface"] = primary?.name.map(JSONValue.string) ?? .null }

        // One snapshot is only a baseline: a rate is a difference.
        let rate: (rx: Double, tx: Double)
        if let latest = snapshots.latest, snapshots.count >= 2, let previous = snapshots.back(1) {
            rate = NetModule.rate(previous, latest)
            rxHistory.append(rate.rx)
            txHistory.append(rate.tx)
        } else {
            rate = (0, 0)
        }
        patch["rx"] = .number(rate.rx.rounded())
        patch["tx"] = .number(rate.tx.rounded())
        patch["rx-human"] = .string(Humanise.bytes(rate.rx, perSecond: true))
        patch["tx-human"] = .string(Humanise.bytes(rate.tx, perSecond: true))
        patch["rx-history"] = rxHistory.padded
        patch["tx-history"] = txHistory.padded
        for window in sampling.windows {
            var over = (rx: 0.0, tx: 0.0)
            if let latest = snapshots.latest, let start = snapshots.back(window.samples) {
                over = NetModule.rate(start, latest)
            }
            patch["rx-\(window.name)"] = .number(over.rx.rounded())
            patch["tx-\(window.name)"] = .number(over.tx.rounded())
        }
        return PollResult(patch: .object(patch), every: sampling.interval)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        var tooltip = "↓ \(state.value("rx-human")?.stringValue ?? "") ↑ \(state.value("tx-human")?.stringValue ?? "")"
        if let interface = state.value("interface")?.stringValue { tooltip = "\(interface)  " + tooltip }
        for window in sampling.windows {
            let rx = Humanise.bytes(state.value("rx-\(window.name)")?.doubleValue ?? 0, perSecond: true)
            let tx = Humanise.bytes(state.value("tx-\(window.name)")?.doubleValue ?? 0, perSecond: true)
            tooltip += "\n\(window.name): ↓ \(rx) ↑ \(tx)"
        }
        return RenderResult(content: try view.render(state), tooltip: tooltip)
    }

    /// Bytes per second between two snapshots. Counters only grow here, since `ByteCounter`
    /// has already folded wraps and vanished interfaces away.
    static func rate(_ a: Snapshot, _ b: Snapshot) -> (rx: Double, tx: Double) {
        let elapsed = b.at - a.at
        guard elapsed > 0 else { return (0, 0) }
        return (max(0, b.rx - a.rx) / elapsed, max(0, b.tx - a.tx) / elapsed)
    }

    /// The interfaces this sample counts.
    private func counted(_ raw: [String: (rx: UInt32, tx: UInt32)], at now: Double) -> Set<String> {
        switch selection {
        case .named(let name):
            return [name]
        case .all:
            return Set(raw.keys.filter { !$0.hasPrefix("lo") })
        case .primary:
            if primary == nil || now - primary!.checkedAt >= NetModule.primaryRecheck {
                primary = (NetModule.primaryInterface(), now)
            }
            return primary?.name.map { [$0] } ?? []
        }
    }

    /// The interface the system routes through, from the dynamic store: a VPN's tunnel while
    /// one is up, which is the traffic the user is making. Summing every interface instead
    /// counts a VPN's traffic twice, once inside the tunnel and once on the wire.
    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "bario" as CFString, nil, nil) else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = value["PrimaryInterface"] as? String {
                return name
            }
        }
        return nil
    }

    /// Each link-layer interface's byte counters as the kernel keeps them: 32 bits, so they wrap
    /// every 4 GB.
    static func rawCounters() -> [String: (rx: UInt32, tx: UInt32)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(head) }

        var counters: [String: (rx: UInt32, tx: UInt32)] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = current.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            counters[String(cString: current.pointee.ifa_name)] = (data.pointee.ifi_ibytes, data.pointee.ifi_obytes)
        }
        return counters
    }

    /// Bytes in and out, summed over every interface or just the named one. Loopback is
    /// excluded because counting your own traffic twice is never what anyone means.
    static func counters(interface: String?) -> (rx: Double, tx: Double) {
        rawCounters().filter { name, _ in interface.map { name == $0 } ?? !name.hasPrefix("lo") }
            .values.reduce((0, 0)) { ($0.rx + Double($1.rx), $0.tx + Double($1.tx)) }
    }
}

/// Totals that only grow, from counters that wrap: each sample adds what each counted interface
/// moved since the last, modulo 2³², so a wrap between samples costs nothing, and an interface
/// that appears, disappears or stops being counted adds nothing rather than a jump.
struct ByteCounter: Sendable {
    private var last: [String: (rx: UInt32, tx: UInt32)] = [:]
    private(set) var rx: Double = 0
    private(set) var tx: Double = 0

    mutating func read(_ raw: [String: (rx: UInt32, tx: UInt32)],
                       counting interfaces: Set<String>) -> (rx: Double, tx: Double) {
        for name in interfaces {
            guard let now = raw[name] else { continue }
            if let before = last[name] {
                rx += Double(now.rx &- before.rx)
                tx += Double(now.tx &- before.tx)
            }
        }
        last = raw
        return (rx, tx)
    }
}

/// `host_statistics` tick deltas. The first sample is only a baseline: CPU load is a
/// difference, so one reading means nothing.
public actor CPUModule: Module {
    private let context: ModuleContext
    private let view: StatsRenderer
    private let sampling: Sampling
    private let thresholds: Thresholds
    private var ticks: Ring<Ticks>
    private var history: History

    struct Ticks: Sendable {
        var user: Double = 0
        var system: Double = 0
        var idle: Double = 0
        var nice: Double = 0
        var total: Double { user + system + idle + nice }
    }

    public init(context: ModuleContext) throws {
        self.context = context
        // `stacked` is a line per window, so it needs some to show.
        let sampling = try Sampling(context: context, defaultInterval: 2,
                                    defaultWindows: context.string("preset") == "stacked" ? ["5s", "1m"] : [])
        self.sampling = sampling
        let lines = sampling.windows.map { "  text \"{load-\($0.name):%3.0f}%\"" }.joined(separator: "\n")
        self.view = try StatsRenderer(context, module: "cpu", format: "{load}%", fallback: "load", presets: [
            "stacked": "column class=\"stacked\" align=\"end\" {\n\(lines)\n}",
            "graph": """
                row class="graph" align="center" {
                  graph values="{history}" max=1 \(try StatsRenderer.graph(context))
                  text "{load:%3.0f}%"
                }
                """,
        ])
        self.thresholds = Thresholds(context)
        self.ticks = Ring(capacity: sampling.depth)
        self.history = History(capacity: sampling.history)
    }

    public func poll() async -> PollResult {
        let now = CPUModule.ticks()
        ticks.append(now)
        var patch: [String: JSONValue] = ["icon": .string("cpu")]

        var load = (load: 0.0, user: 0.0, system: 0.0)
        if ticks.count >= 2, let previous = ticks.back(1) {
            load = CPUModule.delta(previous, now)
            history.append(load.load)
        }
        patch["load"] = .number((load.load * 100).rounded())
        patch["fraction"] = .number((load.load * 1000).rounded() / 1000)
        patch["user"] = .number((load.user * 100).rounded())
        patch["system"] = .number((load.system * 100).rounded())
        patch["history"] = history.padded
        for window in sampling.windows {
            let over = ticks.back(window.samples).map { CPUModule.delta($0, now).load } ?? 0
            patch["load-\(window.name)"] = .number((over * 100).rounded())
        }
        return PollResult(patch: .object(patch), every: sampling.interval)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        func percent(_ key: String) -> String { "\(state.value(key)?.intValue ?? 0)%" }
        var tooltip = "CPU \(percent("load"))  user \(percent("user"))  system \(percent("system"))"
        for window in sampling.windows { tooltip += "\n\(window.name): \(percent("load-\(window.name)"))" }
        return RenderResult(content: try view.render(state),
                            classes: thresholds.classes(state.value("load")?.doubleValue),
                            tooltip: tooltip)
    }

    static func delta(_ a: Ticks, _ b: Ticks) -> (load: Double, user: Double, system: Double) {
        let total = b.total - a.total
        guard total > 0 else { return (0, 0, 0) }
        let idle = b.idle - a.idle
        let user = (b.user - a.user) + (b.nice - a.nice)
        let system = b.system - a.system
        return (max(0, min(1, (total - idle) / total)), user / total, system / total)
    }

    static func ticks() -> Ticks {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return Ticks() }
        return Ticks(user: Double(info.cpu_ticks.0), system: Double(info.cpu_ticks.1),
                     idle: Double(info.cpu_ticks.2), nice: Double(info.cpu_ticks.3))
    }
}

/// `host_statistics64` page counts, plus the memory pressure the system itself reports.
///
/// Pressure is the headline, not used: the compressor keeps used memory under the RAM there
/// is however far past it demand goes, so used barely moves as a Mac runs out
/// ([20-stats-widgets.md]).
public actor MemModule: Module {
    private let context: ModuleContext
    private let view: StatsRenderer
    private let sampling: Sampling
    private let thresholds: Thresholds
    /// Memory is a gauge, not a counter, so a window is the mean of the samples in it.
    private var samples: Ring<Sample>
    private var history: History
    private var pressureHistory: History

    struct Sample: Sendable {
        var used: Double
        var pressure: Double
    }

    public init(context: ModuleContext) throws {
        self.context = context
        let sampling = try Sampling(context: context, defaultInterval: 5)
        self.sampling = sampling
        self.view = try StatsRenderer(context, module: "mem", format: "{used-human}", fallback: "used-human",
                                      presets: [
            "stacked": """
                column class="stacked" align="end" {
                  text "{used:bytes}"
                  text "{pressure}"
                }
                """,
            "meter": """
                row class="meter" align="center" {
                  meter value="{pressure-fraction}"
                  text "{pressure-pct:%3.0f}%"
                }
                """,
            "graph": """
                row class="graph" align="center" {
                  graph values="{pressure-history}" max=1 \(try StatsRenderer.graph(context))
                  text "{pressure-pct:%3.0f}%"
                }
                """,
        ])
        self.thresholds = Thresholds(context)
        self.samples = Ring(capacity: sampling.depth)
        self.history = History(capacity: sampling.history)
        self.pressureHistory = History(capacity: sampling.history)
    }

    public func poll() async -> PollResult {
        let usage = MemModule.read()
        let pressure = MemModule.pressureFraction()
        samples.append(Sample(used: usage.fraction, pressure: pressure))
        history.append(usage.fraction)
        pressureHistory.append(pressure)
        var patch: [String: JSONValue] = [
            "used": .number(usage.used),
            "total": .number(usage.total),
            "fraction": .number((usage.fraction * 1000).rounded() / 1000),
            "pct": .number((usage.fraction * 100).rounded()),
            "used-human": .string(Humanise.bytes(usage.used)),
            "total-human": .string(Humanise.bytes(usage.total)),
            "history": history.padded,
            "pressure": .string(MemModule.pressure().rawValue),
            "pressure-fraction": .number((pressure * 1000).rounded() / 1000),
            "pressure-pct": .number((pressure * 100).rounded()),
            "pressure-history": pressureHistory.padded,
            "swap-used": .number(MemModule.swapUsed()),
            "icon": .string("memorychip"),
        ]
        for window in sampling.windows {
            let recent = samples.suffix(window.samples)
            patch["pct-\(window.name)"] = .number((MemModule.mean(recent.map(\.used)) * 100).rounded())
            patch["pressure-pct-\(window.name)"] = .number((MemModule.mean(recent.map(\.pressure)) * 100).rounded())
        }
        return PollResult(patch: .object(patch), every: sampling.interval)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        var classes = thresholds.classes(state.value("pressure-pct")?.doubleValue)
        let pressure = state.value("pressure")?.stringValue ?? Pressure.normal.rawValue
        if pressure != Pressure.normal.rawValue { classes.append("pressure-\(pressure)") }
        var tooltip = "\(state.value("used-human")?.stringValue ?? "") of "
            + "\(state.value("total-human")?.stringValue ?? "") used  "
            + "pressure \(state.value("pressure-pct")?.intValue ?? 0)% \(pressure)  "
            + "swap \(Humanise.bytes(state.value("swap-used")?.doubleValue ?? 0))"
        for window in sampling.windows {
            tooltip += "\n\(window.name): pressure \(state.value("pressure-pct-\(window.name)")?.intValue ?? 0)%"
                + "  used \(state.value("pct-\(window.name)")?.intValue ?? 0)%"
        }
        return RenderResult(content: try view.render(state), classes: classes, tooltip: tooltip)
    }

    static func mean(_ values: some Collection<Double>) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func read() -> (used: Double, total: Double, fraction: Double) {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64()
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, total, 0) }
        var pageSize = vm_size_t(0)
        host_page_size(mach_host_self(), &pageSize)
        let used = MemModule.used(stats, pageSize: Double(pageSize))
        return (used, total, total > 0 ? min(1, used / total) : 0)
    }

    /// What Activity Monitor calls Memory Used: App Memory (anonymous pages, less those their
    /// owner marked purgeable), wired, and what the compressor occupies. Not `active`, which
    /// counts file cache that is free for the taking and misses app pages waiting, inactive,
    /// to be compressed.
    static func used(_ stats: vm_statistics64, pageSize: Double) -> Double {
        let app = max(0, Double(stats.internal_page_count) - Double(stats.purgeable_count))
        return (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize
    }

    /// The share of memory the kernel counts as spoken for, 0…1: the complement of
    /// `kern.memorystatus_level`, the free percentage `memory_pressure` prints. It tracks what
    /// wired and compressed memory take, which is what runs out, so unlike used it keeps
    /// climbing as demand passes RAM.
    static func pressureFraction() -> Double {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return 0 }
        return pressureFraction(freePercent: level)
    }

    static func pressureFraction(freePercent: Int32) -> Double {
        max(0, min(1, Double(100 - freePercent) / 100))
    }

    public enum Pressure: String, Sendable {
        case normal, warn, critical
    }

    /// The kernel's own verdict, which is what decides whether the machine is short of memory:
    /// a Mac using most of its memory is working as intended.
    static func pressure() -> Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        switch level {
        case 4...: return .critical
        case 2...: return .warn
        default: return .normal
        }
    }

    static func swapUsed() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Double(usage.xsu_used)
    }
}

// MARK: - What the three share

/// What a stats item shows: its own content block or format, or one of the presets its module
/// ships, written in KDL like a user's own.
struct StatsRenderer: Sendable {
    private var renderer: FormatRenderer

    init(_ context: ModuleContext, module: String, format: String, fallback: String,
         presets: [String: String]) throws {
        renderer = FormatRenderer(context, format: format, fallback: fallback)
        guard let name = context.string("preset") else { return }
        if context.format != nil || context.content != nil || context.template != nil {
            throw ModuleError("preset=\"\(name)\" and \(context.format != nil ? "format=" : "content") "
                              + "both say what the item shows; keep one")
        }
        guard let source = presets[name] else {
            throw ModuleError("\(module) has no preset '\(name)'; its presets are "
                              + presets.keys.sorted().joined(separator: ", "))
        }
        guard let node = try KDL.parse(source, source: "the \(name) preset").first else { return }
        (renderer.content, renderer.contentTemplate) = try node.contentOrTemplate()
    }

    func render(_ state: StateReader) throws -> Node? { try renderer.render(state) }

    /// The item's `kind=` and `scroll=`, for a preset's graph, checked now rather than when
    /// the first render fails to decode.
    static func graph(_ context: ModuleContext) throws -> String {
        let kind = context.string("kind") ?? GraphKind.area.rawValue
        let scroll = context.string("scroll") ?? GraphScroll.step.rawValue
        guard GraphKind(rawValue: kind) != nil else {
            throw ModuleError("kind is one of \(GraphKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard GraphScroll(rawValue: scroll) != nil else {
            throw ModuleError("scroll is one of \(GraphScroll.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return "kind=\"\(kind)\" scroll=\"\(scroll)\""
    }
}

/// `warn 70` and `critical 90`, like `battery`'s `low`: a class for the stylesheet, one or the
/// other and never both.
struct Thresholds: Sendable {
    var warn: Double?
    var critical: Double?

    init(_ context: ModuleContext) {
        warn = context.double("warn")
        critical = context.double("critical")
    }

    func classes(_ value: Double?) -> [String] {
        guard let value else { return [] }
        if let critical, value >= critical { return ["critical"] }
        if let warn, value >= warn { return ["warn"] }
        return []
    }
}
