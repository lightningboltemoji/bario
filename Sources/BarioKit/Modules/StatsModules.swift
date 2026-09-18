import Darwin
import Foundation

/// Interface byte counters from `getifaddrs`, sampled on an interval. Genuinely polled: there
/// is no notification for "more bytes arrived".
public actor NetModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    private let interface: String?
    private let interval: Double
    private var rxHistory: History
    private var txHistory: History
    private var last: (rx: Double, tx: Double, at: Double)?

    public init(context: ModuleContext) {
        self.context = context
        self.renderer = FormatRenderer(format: context.format ?? "↓{rx-human} ↑{tx-human}",
                                       fallback: "rx-human")
        self.interface = context.string("interface")
        let history = context.config["history"]?.intValue ?? 32
        self.rxHistory = History(capacity: history)
        self.txHistory = History(capacity: history)
        if case .seconds(let seconds)? = context.interval { interval = seconds } else { interval = 2 }
    }

    public func poll() async -> PollResult {
        let now = Date().timeIntervalSince1970
        let totals = NetModule.counters(interface: interface)
        defer { last = (totals.rx, totals.tx, now) }

        guard let previous = last, now > previous.at else {
            return PollResult(patch: .object([
                "rx-total": .number(totals.rx), "tx-total": .number(totals.tx),
                "rx": .number(0), "tx": .number(0),
                "rx-human": .string(Humanise.bytes(0, perSecond: true)),
                "tx-human": .string(Humanise.bytes(0, perSecond: true)),
            ]), nextIn: interval)
        }

        let elapsed = now - previous.at
        // Counters wrap and interfaces come and go; a negative delta is noise, not traffic.
        let rx = max(0, totals.rx - previous.rx) / elapsed
        let tx = max(0, totals.tx - previous.tx) / elapsed
        rxHistory.append(rx)
        txHistory.append(tx)

        return PollResult(patch: .object([
            "rx": .number(rx.rounded()),
            "tx": .number(tx.rounded()),
            "rx-human": .string(Humanise.bytes(rx, perSecond: true)),
            "tx-human": .string(Humanise.bytes(tx, perSecond: true)),
            "rx-total": .number(totals.rx),
            "tx-total": .number(totals.tx),
            "rx-history": rxHistory.json,
            "tx-history": txHistory.json,
            "icon": .string("network"),
        ]), nextIn: interval)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: renderer.render(state))
    }

    /// Bytes in and out, summed over every interface or just the named one. Loopback is
    /// excluded because counting your own traffic twice is never what anyone means.
    static func counters(interface: String?) -> (rx: Double, tx: Double) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }

        var rx = 0.0, tx = 0.0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            guard current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            if let interface { guard name == interface else { continue } }
            else if name.hasPrefix("lo") { continue }
            guard let data = current.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            rx += Double(data.pointee.ifi_ibytes)
            tx += Double(data.pointee.ifi_obytes)
        }
        return (rx, tx)
    }
}

/// `host_processor_info` deltas. The first sample is only a baseline: CPU load is a
/// difference, so one reading means nothing.
public actor CPUModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    private let interval: Double
    private var history: History
    private var last: CPUModule.Ticks?

    struct Ticks: Sendable {
        var user: Double = 0
        var system: Double = 0
        var idle: Double = 0
        var nice: Double = 0
        var total: Double { user + system + idle + nice }
    }

    public init(context: ModuleContext) {
        self.context = context
        self.renderer = FormatRenderer(format: context.format ?? "{load}%", fallback: "load")
        self.history = History(capacity: context.config["history"]?.intValue ?? 32)
        if case .seconds(let seconds)? = context.interval { interval = seconds } else { interval = 2 }
    }

    public func poll() async -> PollResult {
        let now = CPUModule.ticks()
        defer { last = now }
        guard let previous = last else {
            return PollResult(patch: .object(["load": .number(0)]), nextIn: interval)
        }
        let deltas = CPUModule.delta(previous, now)
        history.append(deltas.load)
        return PollResult(patch: .object([
            "load": .number((deltas.load * 100).rounded()),
            "fraction": .number((deltas.load * 1000).rounded() / 1000),
            "user": .number((deltas.user * 100).rounded()),
            "system": .number((deltas.system * 100).rounded()),
            "history": history.json,
            "icon": .string("cpu"),
        ]), nextIn: interval)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: renderer.render(state))
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
public actor MemModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    private let interval: Double
    private var history: History

    public init(context: ModuleContext) {
        self.context = context
        self.renderer = FormatRenderer(format: context.format ?? "{used-human}", fallback: "used-human")
        self.history = History(capacity: context.config["history"]?.intValue ?? 32)
        if case .seconds(let seconds)? = context.interval { interval = seconds } else { interval = 5 }
    }

    public func poll() async -> PollResult {
        let usage = MemModule.read()
        history.append(usage.fraction)
        return PollResult(patch: .object([
            "used": .number(usage.used),
            "total": .number(usage.total),
            "fraction": .number((usage.fraction * 1000).rounded() / 1000),
            "pct": .number((usage.fraction * 100).rounded()),
            "used-human": .string(Humanise.bytes(usage.used)),
            "total-human": .string(Humanise.bytes(usage.total)),
            "history": history.json,
            "icon": .string("memorychip"),
        ]), nextIn: interval)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: renderer.render(state))
    }

    /// "Used" is what Activity Monitor calls App Memory plus wired plus compressed: the pages
    /// that are not available to anyone else.
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
        let page = Double(pageSize)
        let used = (Double(stats.active_count) + Double(stats.wire_count)
                    + Double(stats.compressor_page_count)) * page
        return (used, total, total > 0 ? min(1, used / total) : 0)
    }
}
