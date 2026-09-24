import Foundation

/// One protocol, three backends: built-ins implement it in Swift, `exec` implements it by
/// running a process, WASM implements it by exporting functions. DESIGN.md §3.
public protocol Module: Actor {
    /// Anything the module needs to set up: notification observers, a process, an instance.
    func start() async

    /// Called on the item's interval. Returns a state patch to merge under the item's key,
    /// and optionally when to be polled next — the Swift equivalent of `set_timer`.
    func poll() async -> PollResult

    /// A store change the module subscribed to, a click, or a system event.
    func onEvent(_ event: ModuleEvent) async -> JSONValue?

    /// The only required method. Pure: state in, content out.
    func render(_ state: StateReader) async throws -> RenderResult

    func stop() async
}

extension Module {
    public func start() async {}
    public func poll() async -> PollResult { PollResult() }
    public func onEvent(_ event: ModuleEvent) async -> JSONValue? { nil }
    public func stop() async {}
}

public struct PollResult: Sendable {
    /// Merged into the store under this item's key.
    public var patch: JSONValue?
    /// Seconds until the next poll, exactly, overriding `every` and the configured interval.
    public var nextIn: Double?
    /// Poll again on the next tick of this period, overriding the configured interval: see
    /// `Tick`.
    public var every: Double?

    public init(patch: JSONValue? = nil, nextIn: Double? = nil, every: Double? = nil) {
        self.patch = patch
        self.nextIn = nextIn
        self.every = every
    }
}

/// The clock every periodic poll keeps: whole multiples of its period on the wall clock, the
/// same for every item. Items that sample at one rate sample at the same moment, so what they
/// change reaches the screen in one frame rather than one each (the frame loop styles renders
/// that finish within a refresh of each other together). No item waits for another; a slow
/// one lands in a later frame. A clock showing seconds is one more item on the 1s tick.
public enum Tick {
    /// Seconds from `date` to the next tick of `period`, landing a hair after it rather than
    /// a hair before, so a clock polled on it reads the new second.
    public static func wait(every period: Double, after date: Date) -> Double {
        guard period > 0 else { return 0 }
        let remainder = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        let wait = period - remainder
        return wait < 0.02 ? wait + period : wait + 0.005
    }
}

public struct ModuleEvent: Sendable, Hashable {
    /// `click`, `right-click`, `scroll`, `hover`, `state`, `wake`, or anything `emit` names.
    public var name: String
    public var payload: JSONValue

    public init(name: String, payload: JSONValue = .object([:])) {
        self.name = name
        self.payload = payload
    }
}

/// What a module is handed when it is built. `config` is the item's whole config node as
/// JSON — the same bytes a WASM module receives from `init(ptr, len)`.
public struct ModuleContext: Sendable {
    public var item: String
    public var config: JSONValue
    public var format: String?
    /// A content tree written in the config (`ItemConfig.content`).
    public var content: Node?
    /// A content block with slots in it, filled from this item's state on every render.
    public var template: ContentTemplate?
    public var interval: Interval?
    public var store: StateStore
    /// Where this module's `emit` goes, and what its `subscribe` registers with.
    public var events: EventBus

    public init(item: String, config: JSONValue = .object([:]), format: String? = nil,
                content: Node? = nil, template: ContentTemplate? = nil, interval: Interval? = nil,
                store: StateStore, events: EventBus = EventBus()) {
        self.item = item
        self.config = config
        self.format = format
        self.content = content
        self.template = template
        self.interval = interval
        self.store = store
        self.events = events
    }

    public func option(_ name: String) -> JSONValue? { config[name] }

    public func string(_ name: String, default fallback: String? = nil) -> String? {
        config[name]?.stringValue ?? fallback
    }

    public func double(_ name: String, default fallback: Double? = nil) -> Double? {
        config[name]?.doubleValue ?? fallback
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        config[name]?.boolValue ?? fallback
    }
}

public struct ModuleError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Name → factory. A module that is not here is a config error naming the ones that are.
public enum ModuleRegistry {
    public typealias Factory = @Sendable (ModuleContext) throws -> any Module

    private nonisolated(unsafe) static var factories: [String: Factory] = [:]
    private nonisolated(unsafe) static var builtInsRegistered = false
    private static let lock = NSLock()

    public static func register(_ name: String, _ factory: @escaping Factory) {
        lock.lock(); defer { lock.unlock() }
        factories[name] = factory
    }

    public static func make(_ name: String, context: ModuleContext) throws -> any Module {
        lock.lock()
        let factory = factories[name]
        let known = factories.keys.sorted().joined(separator: ", ")
        lock.unlock()
        guard let factory else {
            throw ModuleError("there is no module called '\(name)'; the ones that exist are \(known)")
        }
        return try factory(context)
    }

    public static var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return factories.keys.sorted()
    }

    /// Called once at startup. Idempotent, and registered under one lock: a concurrent caller
    /// must either see none of the built-ins or all of them.
    public static func registerBuiltIns() {
        let builtIns: [String: Factory] = [
            "text": { TextModule(context: $0) },
            "clock": { ClockModule(context: $0) },
            "data": { DataModule(context: $0) },
            "front-app": { FrontAppModule(context: $0) },
            "battery": { BatteryModule(context: $0) },
            "volume": { VolumeModule(context: $0) },
            "wifi": { WifiModule(context: $0) },
            "net": { try NetModule(context: $0) },
            "cpu": { try CPUModule(context: $0) },
            "mem": { try MemModule(context: $0) },
            "exec": { try ExecModule(context: $0) },
            "wasm": { try WasmModule(context: $0) },
        ]
        lock.lock()
        defer { lock.unlock() }
        guard !builtInsRegistered else { return }
        builtInsRegistered = true
        factories.merge(builtIns) { _, new in new }
    }
}
