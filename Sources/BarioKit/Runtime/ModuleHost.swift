import Foundation

/// Gives up on `work` after `seconds` and throws. The abandoned task keeps running — that is
/// the point: a slow module must not stall paint, and for WASM the instance is torn down
/// separately (DESIGN.md §5).
public struct BudgetExceeded: Error, CustomStringConvertible {
    public var seconds: Double
    public var description: String { String(format: "over its %.0fms budget", seconds * 1000) }
}

public func withBudget<T: Sendable>(_ seconds: Double,
                                    _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let box = OnceFlag()
    return try await withCheckedThrowingContinuation { continuation in
        let task = Task.detached {
            do {
                let value = try await work()
                if box.claim() { continuation.resume(returning: value) }
            } catch {
                if box.claim() { continuation.resume(throwing: error) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if box.claim() {
                task.cancel()
                continuation.resume(throwing: BudgetExceeded(seconds: seconds))
            }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// Owns every module instance, runs their poll timers, and keeps the last good render of
/// each. A module that throws or overruns keeps its last content and gains `.stale`; it never
/// takes the bar down. DESIGN.md §3, §5.
///
/// This is the render stage of DESIGN.md §10, and the only asynchronous one: a frame starts
/// renders and never waits for them, and a render that changed something says so, which
/// invalidates style for its item.
@MainActor
public final class ModuleHost {
    public let store: StateStore
    /// Where `emit` and `subscribe` meet, for modules and socket clients alike.
    public let events = EventBus()

    /// What one item looks like right now, from the style stage's point of view.
    public struct ItemState: Sendable, Equatable {
        public init() {}

        public init(result: RenderResult, stale: Bool = false, error: String? = nil,
                    rendered: Bool = false) {
            self.result = result
            self.stale = stale
            self.error = error
            self.rendered = rendered
        }

        public var result = RenderResult()
        public var stale = false
        public var error: String?
        /// Whether the item has rendered at least once, including a render that failed or ran
        /// out of budget. An item that has not has nothing to show yet.
        public var rendered = false
    }

    final class Instance {
        let name: String
        let moduleName: String
        let module: any Module
        let interval: Interval?
        let fingerprint: JSONValue
        /// Set when the item could not be built at all; survives every render.
        let permanentError: String?
        var state = ItemState()
        var needsRender = true
        /// A new module's first render waits until it has state to show: its first poll has
        /// landed, something wrote under its key, or the host stopped waiting.
        var held = true
        var renderTask: Task<Void, Never>?
        var pollTask: Task<Void, Never>?
        var startTask: Task<Void, Never>?

        init(name: String, moduleName: String, module: any Module, interval: Interval?,
             fingerprint: JSONValue, permanentError: String? = nil) {
            self.name = name
            self.moduleName = moduleName
            self.module = module
            self.interval = interval
            self.fingerprint = fingerprint
            self.permanentError = permanentError
            self.state.error = permanentError
        }

        var canRender: Bool { needsRender && !held && renderTask == nil }
    }

    private var instances: [String: Instance] = [:]
    private var order: [String] = []
    private var loading: Task<Void, Never>?
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// A render has become due: something wrote state an item reads, or an item that was held
    /// or busy can now go. The frame loop answers with a frame, which starts it.
    public var onNeedsRender: (@MainActor () -> Void)?
    /// A render finished and the item looks different: new content, classes, visibility, or
    /// staleness. The frame loop answers by invalidating style for that item.
    public var onRendered: (@MainActor (String) -> Void)?

    public static let renderBudget = 0.050
    public static let pollBudget = 2.0
    /// How long a new module's first render waits for state before rendering without it.
    public let firstStateDeadline: Double

    public init(store: StateStore = StateStore(), firstStateDeadline: Double = 0.25) {
        self.store = store
        self.firstStateDeadline = firstStateDeadline
        Task { [store, weak self] in
            await store.onDirty { [weak self] names in
                Task { @MainActor in self?.markDirty(names) }
            }
        }
    }

    // MARK: - Lifecycle

    /// Build instances to match the config, reusing any whose module and options are
    /// unchanged so a stylesheet-only reload never restarts a module. Items are unique by name
    /// across bars: the first definition of a name is the one that runs.
    public func load(_ items: [ItemConfig]) async {
        // One load at a time, or two quick reloads would interleave their retirements.
        let previous = loading
        let task = Task { @MainActor in
            await previous?.value
            await self.apply(items)
        }
        loading = task
        await task.value
    }

    private func apply(_ items: [ItemConfig]) async {
        var next: [String: Instance] = [:]
        var nextOrder: [String] = []
        var fresh: [Instance] = []

        for item in items.flatMap(\.flattened) {
            guard let moduleName = item.moduleName, next[item.name] == nil else { continue }
            nextOrder.append(item.name)
            if let existing = instances[item.name],
               existing.moduleName == moduleName,
               existing.fingerprint == item.options {
                next[item.name] = existing
                instances.removeValue(forKey: item.name)
                continue
            }
            let instance = make(item, moduleName: moduleName, fingerprint: item.options)
            // A restarted item keeps showing what it showed until its new module renders,
            // rather than vanishing and coming back.
            if let replaced = instances[item.name] {
                instance.state.result = replaced.state.result
                instance.state.rendered = replaced.state.rendered
            }
            next[item.name] = instance
            fresh.append(instance)
        }

        let retired = Array(instances.values)
        instances = next
        order = nextOrder
        settle()
        // The first-state deadline runs from now, not from whenever the slowest module has
        // finished starting.
        let deadline = firstStateDeadline
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            for instance in fresh { self?.release(instance) }
        }
        // Retired before anything new starts, so a replacement's subscriptions are its own.
        for instance in retired { await retire(instance) }

        // Each module starts on its own: one that takes its time, or never finishes (a WASM
        // `init` that loops), holds up nothing but itself, and never the next reload.
        for instance in fresh {
            instance.startTask = Task { [weak self] in
                await instance.module.start()
                guard let self, self.instances[instance.name] === instance else { return }
                self.startPolling(instance)
            }
        }
    }

    private func make(_ item: ItemConfig, moduleName: String, fingerprint: JSONValue) -> Instance {
        let context = ModuleContext(item: item.name, config: item.options, format: item.format,
                                    content: item.content, interval: item.interval, store: store,
                                    events: events)
        do {
            let module = try ModuleRegistry.make(moduleName, context: context)
            return Instance(name: item.name, moduleName: moduleName, module: module,
                            interval: item.interval, fingerprint: fingerprint)
        } catch {
            // A bad module name is a bubble with the message in it, not a dead bar.
            let message = "\(error)"
            return Instance(name: item.name, moduleName: moduleName,
                            module: ErrorModule(message: message),
                            interval: nil, fingerprint: fingerprint, permanentError: message)
        }
    }

    private func retire(_ instance: Instance) async {
        instance.startTask?.cancel()
        instance.pollTask?.cancel()
        instance.pollTask = nil
        await store.forget(instance.name)
        events.forget(instance.name)
        // A module's `stop` tidies only its own state, and waits on its actor, which a module
        // stuck in `start` never frees. So it is not waited on.
        let module = instance.module
        Task { await module.stop() }
    }

    public func shutdown() async {
        let all = Array(instances.values)
        instances = [:]
        order = []
        for instance in all { await retire(instance) }
    }

    // MARK: - Polling

    private func startPolling(_ instance: Instance) {
        // `watch` modules drive themselves from start(); everything else is polled here, with
        // the module free to say when it wants to be woken next.
        if case .watch = instance.interval { return }

        instance.pollTask = Task { [weak self, weak instance] in
            guard let instance else { return }
            var delay: Double? = 0
            while !Task.isCancelled, let wait = delay {
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                let result = await instance.module.poll()
                if let patch = result.patch {
                    await self?.store.merge(patch, at: instance.name)
                }
                self?.release(instance)
                if let next = result.nextIn {
                    delay = next
                } else if case .seconds(let seconds)? = instance.interval {
                    delay = seconds
                } else {
                    delay = nil                     // event-driven from here on
                }
            }
        }
    }

    private func release(_ instance: Instance) {
        guard instance.held else { return }
        instance.held = false
        settle()
        if instance.canRender, instances[instance.name] === instance { onNeedsRender?() }
    }

    /// Wait until no module is still waiting for its first state, or `seconds`, whichever is
    /// first. For one-shot renders (`--shot`, tests); the running bar never waits.
    public func firstPolls(within seconds: Double? = nil) async {
        guard instances.values.contains(where: \.held) else { return }
        let seconds = seconds ?? firstStateDeadline
        _ = try? await withBudget(seconds) { [weak self] in
            await self?.waitForReleases()
        }
    }

    /// Wake whoever is waiting for first states, once nothing is held any more.
    private func settle() {
        guard !instances.values.contains(where: \.held) else { return }
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func waitForReleases() async {
        guard instances.values.contains(where: \.held) else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    // MARK: - Rendering

    /// Invalidate render for these items: something they read was written. An item that is
    /// rendering right now stays dirty and renders again when it finishes.
    public func markDirty(_ names: Set<String>) {
        var due = false
        var released = false
        for name in names {
            guard let instance = instances[name] else { continue }
            instance.needsRender = true
            // A write under the item's key is state to show.
            if instance.held {
                instance.held = false
                released = true
            }
            if instance.canRender { due = true }
        }
        if released { settle() }
        if due { onNeedsRender?() }
    }

    /// Whether anything is dirty, including renders that cannot start yet.
    public var needsRender: Bool { instances.values.contains { $0.needsRender } }

    /// Start a render for every item that is dirty, has state to show, and is not already
    /// rendering. Returns at once; each render reports back when it finishes.
    public func startRenders() {
        for name in order {
            guard let instance = instances[name], instance.canRender else { continue }
            instance.needsRender = false
            instance.renderTask = Task { [weak self] in
                await self?.render(instance)
            }
        }
    }

    private func render(_ instance: Instance) async {
        let reader = await store.reader(for: instance.name)
        let module = instance.module
        var next = instance.state
        do {
            next.result = try await withBudget(ModuleHost.renderBudget) {
                try await module.render(reader)
            }
            // A write that landed mid-render, to something the render read, means it is
            // already out of date.
            if await store.recordReads(reader.paths, for: instance.name, since: reader.version) {
                instance.needsRender = true
            }
            next.stale = false
            next.error = instance.permanentError
        } catch {
            // Keep the last content, wear `.stale`, say why once. What it read before it was
            // abandoned still counts as a reason to try again.
            if !instance.state.stale { warn("\(instance.name): \(error)") }
            if await store.recordReads(reader.paths, for: instance.name, since: reader.version,
                                       replacing: false) {
                instance.needsRender = true
            }
            next.stale = true
            next.error = "\(error)"
        }
        next.rendered = true

        instance.renderTask = nil
        guard instances[instance.name] === instance else { return }
        let changed = next != instance.state
        instance.state = next
        if changed { onRendered?(instance.name) }
        if instance.canRender { onNeedsRender?() }
    }

    /// Render everything that is due and wait for it, including renders that were held for
    /// their first state. For one-shot renders (`--shot`, tests); the running bar never waits.
    public func renderPending() async {
        await firstPolls()
        // A render can dirty another item; a few rounds settle any sane configuration.
        for _ in 0..<8 {
            startRenders()
            guard instances.values.contains(where: { $0.renderTask != nil }) else { return }
            await finishRenders()
        }
    }

    /// Wait for the renders already running, without starting any.
    func finishRenders() async {
        for task in instances.values.compactMap(\.renderTask) { await task.value }
    }

    public func state(for item: String) -> ItemState? {
        instances[item]?.state
    }

    /// Every item's state, which is what the style stage reads.
    public var states: [String: ItemState] {
        instances.mapValues(\.state)
    }

    public var itemNames: [String] { order }

    // MARK: - Events

    public func deliver(_ event: ModuleEvent, to item: String) async {
        guard let instance = instances[item] else { return }
        if let patch = await instance.module.onEvent(event) {
            await store.merge(patch, at: item)
        }
    }

    public func broadcast(_ event: ModuleEvent) async {
        for name in order { await deliver(event, to: name) }
    }

    /// Deliver an event only to the items that subscribed to its topic. A state change is
    /// `state:battery.pct`; an emitted event is `event:refresh`.
    public func deliver(_ event: ModuleEvent, topic: String, except origin: String? = nil) async {
        for name in events.subscribers(of: topic) where name != origin {
            await deliver(event, to: name)
        }
    }
}

/// The bubble a broken item becomes. DESIGN.md §11: the last good config stays live and the
/// error is visible on the bar.
public actor ErrorModule: Module {
    private let message: String

    public init(message: String) { self.message = message }

    public func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: .row(gap: 4, align: .center, [
            .icon("exclamationmark.triangle.fill", classes: ["icon"]),
            .text(message, classes: ["message"]),
        ]), classes: ["error"], tooltip: message)
    }
}
