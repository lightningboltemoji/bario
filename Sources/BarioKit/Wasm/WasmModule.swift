import Foundation

/// A WASM module as a bario module: one instance on its own actor, with the host imports
/// wired to this item's subtree of the store. DESIGN.md §5.
public actor WasmModule: Module {
    private let context: ModuleContext
    private let path: String
    private let permissions: WasmPermissions
    private let engine: any WasmEngine
    private let memoryLimit: Int
    private let renderBudget: Double
    private let pollBudget: Double
    private let interval: Double?

    private var instance: (any WasmInstance)?
    private var wasm: [UInt8]?
    private var failure: String?
    private var backoff: Double = 1
    private var nextTimer: Double?
    private var subscriptions: [String] = []
    private var wantsFrame = false
    /// Bytes a host import produced, waiting for the guest to `read` them.
    private let pending = PendingBytes()

    public init(context: ModuleContext, engine: (any WasmEngine)? = nil) throws {
        self.context = context
        guard let raw = context.string("path") else {
            throw ModuleError("a wasm item needs path=\"…/module.wasm\"")
        }
        self.path = (raw as NSString).expandingTildeInPath
        self.permissions = try WasmPermissions.parse(context.config)
        self.engine = engine ?? WasmKitEngine()
        self.memoryLimit = context.config["memory-limit"]?.intValue ?? 16 * 1024 * 1024
        self.renderBudget = context.double("render-budget", default: 0.050) ?? 0.050
        self.pollBudget = context.double("poll-budget", default: 2.0) ?? 2.0
        if case .seconds(let seconds)? = context.interval { interval = seconds } else { interval = nil }
    }

    // MARK: - Lifecycle

    public func start() async {
        _ = try? load()
    }

    public func stop() async {
        instance = nil
    }

    @discardableResult
    private func load() throws -> any WasmInstance {
        if let instance { return instance }
        let bytes: [UInt8]
        if let wasm {
            bytes = wasm
        } else {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw WasmError("no module at \(path)")
            }
            bytes = [UInt8](data)
            wasm = bytes
        }
        let fresh = try engine.instantiate(wasm: bytes, imports: hostFunctions(),
                                           memoryLimitBytes: memoryLimit)
        instance = fresh
        if fresh.hasExport("init") {
            _ = try fresh.callJSON("init", context.config["config"] ?? context.config)
        }
        backoff = 1
        return fresh
    }

    /// A call that overran or trapped costs the instance: it is dropped and rebuilt, with
    /// backoff, rather than left in whatever state it stopped in.
    private func discard(_ reason: String) {
        instance = nil
        failure = reason
        backoff = min(30, backoff * 2)
    }

    // MARK: - Module

    public func poll() async -> PollResult {
        guard let instance = try? load(), instance.hasExport("poll") else {
            return PollResult(nextIn: interval)
        }
        let state = await context.store.value(at: context.item) ?? .object([:])
        do {
            let patch = try await run(instance, "poll", state, budget: pollBudget)
            let next = nextTimer ?? interval
            nextTimer = nil
            return PollResult(patch: patch, nextIn: next)
        } catch {
            warn("\(context.item): \(error)")
            discard("\(error)")
            return PollResult(nextIn: max(interval ?? 0, backoff))
        }
    }

    public func onEvent(_ event: ModuleEvent) async -> JSONValue? {
        guard let instance = try? load(), instance.hasExport("on_event") else { return nil }
        // A module only hears what it subscribed to, plus its own clicks.
        let interested = subscriptions.isEmpty
            || subscriptions.contains { SocketTopic($0).matches("\(event.name):\(context.item)") }
            || subscriptions.contains { SocketTopic($0).kind == event.name }
        guard interested else { return nil }

        let payload = JSONValue.object(["name": .string(event.name), "payload": event.payload])
        do {
            return try await run(instance, "on_event", payload, budget: renderBudget)
        } catch {
            warn("\(context.item): \(error)")
            discard("\(error)")
            return nil
        }
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        if let failure, instance == nil, wasm == nil {
            throw ModuleError(failure)
        }
        let instance = try load()
        let own = state.own
        do {
            let value = try await run(instance, "render", own, budget: renderBudget)
            guard let value else { return RenderResult() }
            return try JSONDecoder().decode(RenderResult.self, from: value.encoded())
        } catch {
            discard("\(error)")
            throw error
        }
    }

    /// Runs one guest call under a budget. The budget is enforced by abandoning the wait, not
    /// by interrupting the guest — see .agents/knowledge/13-wasm.md for why that is honest
    /// rather than ideal.
    private func run(_ instance: any WasmInstance, _ name: String, _ payload: JSONValue,
                     budget: Double) async throws -> JSONValue? {
        let box = UncheckedBox(instance)
        defer { drainControl() }
        return try await withBudget(budget) {
            try box.value.callJSON(name, payload)
        }
    }

    /// Everything the guest asked for while it was running: a new poll interval, topics it
    /// wants to hear about, events it emitted, a frame it wants drawn.
    private func drainControl() {
        guard let control else { return }
        if let timer = control.timer {
            nextTimer = timer
            control.timer = nil
        }
        if control.wantsFrame {
            wantsFrame = true
            control.wantsFrame = false
        }
        let topics = control.drainSubscriptions()
        if !topics.isEmpty { subscriptions.append(contentsOf: topics) }

    }

    /// Whether the module asked to be drawn again on the next display link tick (§9).
    public func takeFrameRequest() -> Bool {
        defer { wantsFrame = false }
        return wantsFrame
    }

    // MARK: - Host imports

    private func hostFunctions() -> [WasmHostFunction] {
        let control = Control()
        self.control = control
        return WasmHost.imports(store: context.store, item: context.item,
                                permissions: permissions, pending: pending, control: control,
                                events: context.events)
    }

    private var control: Control?

    /// What the guest asked for during a call, collected out of the host functions.
    public final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var _timer: Double?
        private var _wantsFrame = false
        private var _subscriptions: [String] = []
        private var _emitted: [ModuleEvent] = []

        var timer: Double? {
            get { lock.lock(); defer { lock.unlock() }; return _timer }
            set { lock.lock(); _timer = newValue; lock.unlock() }
        }
        var wantsFrame: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _wantsFrame }
            set { lock.lock(); _wantsFrame = newValue; lock.unlock() }
        }
        var subscriptions: Appender { Appender(lock: lock) { self._subscriptions.append(contentsOf: $0) } }
        var emitted: EventAppender { EventAppender(lock: lock) { self._emitted.append(contentsOf: $0) } }

        func drainSubscriptions() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let out = _subscriptions
            _subscriptions = []
            return out
        }
        func drainEvents() -> [ModuleEvent] {
            lock.lock(); defer { lock.unlock() }
            let out = _emitted
            _emitted = []
            return out
        }

        struct Appender {
            let lock: NSLock
            let add: ([String]) -> Void
            func append(_ value: String) { lock.lock(); add([value]); lock.unlock() }
            func append(contentsOf values: [String]) { lock.lock(); add(values); lock.unlock() }
        }
        struct EventAppender {
            let lock: NSLock
            let add: ([ModuleEvent]) -> Void
            func append(_ value: ModuleEvent) { lock.lock(); add([value]); lock.unlock() }
        }
    }

    public static func denied(_ permission: String, detail: String? = nil) -> JSONValue {
        let extra = detail.map { " for \($0)" } ?? ""
        return .object(["error": .string("this module was not granted the '\(permission)' permission\(extra);"
                                         + " add `permissions \"\(permission)\"` to its config")])
    }

    /// The gated `http` import. Synchronous on purpose: it runs inside a guest call, under the
    /// module's own budget, on the module's own actor.
    public static func http(_ request: JSONValue) -> JSONValue {
        guard let urlString = request["url"]?.stringValue ?? request.stringValue,
              let url = URL(string: urlString) else {
            return .object(["error": .string("http needs a url")])
        }
        var http = URLRequest(url: url)
        http.httpMethod = request["method"]?.stringValue ?? "GET"
        http.timeoutInterval = request["timeout"]?.doubleValue ?? 10
        if let headers = request["headers"]?.objectValue {
            for (key, value) in headers {
                http.setValue(value.stringValue ?? "", forHTTPHeaderField: key)
            }
        }
        if let body = request["body"]?.stringValue {
            http.httpBody = Data(body.utf8)
        }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer = JSONValue.object(["error": .string("no response")])
        URLSession.shared.dataTask(with: http) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                answer = .object(["error": .string(error.localizedDescription)])
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            answer = .object([
                "status": .number(Double(status)),
                "body": .string(String(decoding: data ?? Data(), as: UTF8.self)),
            ])
        }.resume()
        _ = semaphore.wait(timeout: .now() + http.timeoutInterval + 1)
        return answer
    }
}

/// The bytes a host import produced, waiting for the guest to copy them out.
final class PendingBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    func set(_ value: [UInt8]) { lock.lock(); bytes = value; lock.unlock() }

    func take() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        let out = bytes
        bytes = []
        return out
    }

    /// A host import runs inside a synchronous guest call, so reading the actor-isolated store
    /// has to be done by waiting rather than awaiting.
    func syncGet(store: StateStore, path: String) -> JSONValue {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var answer = JSONValue.null
        Task {
            answer = await store.value(at: path) ?? .null
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
        return answer
    }
}

/// Carries a non-Sendable instance into a detached budgeted call. Safe because the module
/// actor is the only thing that ever touches it, one call at a time.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
