import Foundation

/// The key/value tree modules and external processes write into. One `JSONValue` object,
/// addressed by the same dotted paths the socket uses (`battery`, `battery.pct`).
///
/// The store also remembers which paths each item's last render read, so a write invalidates
/// exactly the items that depend on it. That is what makes "renders are cached" true, and
/// what keeps hover, animation and the hole from ever calling a module. DESIGN.md §3.
public actor StateStore {
    private var root: JSONValue = .object([:])
    /// item name → the absolute paths its last render touched.
    private var dependencies: [String: Set<String>] = [:]
    private var pending: Set<String> = []
    /// Bumped by every write, so a render can tell whether what it read changed while it ran.
    private var version = 0
    /// The most recent writes, oldest first, each with the paths it changed, for exactly that
    /// question.
    private var recentWrites: [(version: Int, paths: [String])] = []
    private static let writeHistory = 256
    private var dirtyHandler: (@Sendable (Set<String>) -> Void)?
    private var watchers: [UUID: Watcher] = [:]
    private var valueWatchers: [UUID: ValueWatcher] = [:]

    private struct Watcher {
        var pattern: TopicPattern
        var continuation: AsyncStream<StateChange>.Continuation
    }

    private struct ValueWatcher {
        var paths: [String]
        var last: [JSONValue?]
        var continuation: AsyncStream<[JSONValue?]>.Continuation
    }

    public init() {}

    // MARK: - Reading

    public func snapshot() -> JSONValue { root }

    public func value(at path: String) -> JSONValue? {
        path.isEmpty ? root : root.value(at: path)
    }

    /// A snapshot that records what a render reads.
    public func reader(for item: String) -> StateReader {
        StateReader(root: root, item: item, version: version)
    }

    // MARK: - Writing

    /// Deep merge, the socket's `set` semantics. Returns the items whose render is now stale.
    ///
    /// Under an item's key, `content` is a content tree, and is replaced whole: two trees merged
    /// key by key are neither, and a row followed by a text would hold two kinds.
    @discardableResult
    public func merge(_ patch: JSONValue, at path: String = "") -> Set<String> {
        var next = path.isEmpty ? root.merging(patch) : root.merging(patch, at: path)
        if JSONValue.split(path).count == 1, let tree = patch["content"], !tree.isNull {
            next = next.setting("\(path).content", to: tree)
        }
        return write(next, at: path, value: patch)
    }

    /// Replace a subtree wholesale, the socket's `content` semantics.
    @discardableResult
    public func replace(_ value: JSONValue, at path: String) -> Set<String> {
        write(root.setting(path, to: value), at: path, value: value)
    }

    /// A write is what it changed: one that leaves every value as it was invalidates nothing,
    /// notifies nobody and is not remembered, so a script printing the same line every second
    /// costs no render.
    private func write(_ next: JSONValue, at path: String, value: JSONValue) -> Set<String> {
        let paths = JSONValue.differences(from: root.value(at: path), to: next.value(at: path), at: path)
        guard !paths.isEmpty else { return [] }
        root = next
        return changed(paths, written: path, value: value)
    }

    private func changed(_ paths: [String], written path: String, value: JSONValue) -> Set<String> {
        version += 1
        recentWrites.append((version, paths))
        if recentWrites.count > StateStore.writeHistory {
            recentWrites.removeFirst(recentWrites.count - StateStore.writeHistory)
        }

        var dirty: Set<String> = []
        for (item, reads) in dependencies
        where reads.contains(where: { read in paths.contains { overlaps(read, $0) } }) {
            dirty.insert(item)
        }
        // An item always depends on its own subtree, even before its first render.
        for changed in paths {
            if let owner = changed.split(separator: ".").first.map(String.init) { dirty.insert(owner) }
        }

        notify(path: path, value: value)
        notifyValues()
        if !dirty.isEmpty {
            pending.formUnion(dirty)
            if let handler = dirtyHandler {
                let snapshot = pending
                pending = []
                handler(snapshot)
            }
        }
        return dirty
    }

    /// Two paths overlap when either is a prefix of the other: a write to `battery` dirties
    /// a render that read `battery.pct`, and vice versa.
    private func overlaps(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return true }
        if a == b { return true }
        return a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }

    // MARK: - Render bookkeeping

    /// Remember what a render read, so a later write to any of it invalidates the render.
    ///
    /// A write can also land *while* the render runs, after its snapshot was taken and before
    /// its reads are known here — and a render reading something for the first time is not yet
    /// a dependency of anything. So given the snapshot's version, this returns true when a
    /// write since then touched what was read: the render is out of date already and has to
    /// run again. `replacing: false` adds to what was recorded before, for a render that was
    /// abandoned partway through.
    @discardableResult
    public func recordReads(_ paths: Set<String>, for item: String, since snapshot: Int? = nil,
                            replacing: Bool = true) -> Bool {
        dependencies[item] = replacing ? paths : (dependencies[item] ?? []).union(paths)
        guard let snapshot, snapshot < version else { return false }
        // Writes older than the history kept cannot be checked, so assume the worst.
        guard let oldest = recentWrites.first, oldest.version <= snapshot + 1 else { return true }
        return recentWrites.contains { write in
            write.version > snapshot && paths.contains { read in write.paths.contains { overlaps(read, $0) } }
        }
    }

    public func forget(_ item: String) {
        dependencies.removeValue(forKey: item)
    }

    public func forgetAll() {
        dependencies = [:]
    }

    /// Items marked stale since the last drain, for a host that was not listening.
    public func takeDirty() -> Set<String> {
        defer { pending = [] }
        return pending
    }

    /// Called whenever a write invalidates something. The host hops to the main actor and
    /// re-renders exactly those items.
    public func onDirty(_ handler: @escaping @Sendable (Set<String>) -> Void) {
        dirtyHandler = handler
        if !pending.isEmpty {
            let snapshot = pending
            pending = []
            handler(snapshot)
        }
    }

    // MARK: - Subscriptions

    /// `state:battery.*`-style watching, the same mechanism the socket's `subscribe` and a
    /// WASM module's `subscribe` use.
    public func changes(matching pattern: String) -> AsyncStream<StateChange> {
        let topic = TopicPattern(pattern)
        let id = UUID()
        return AsyncStream { continuation in
            watchers[id] = Watcher(pattern: topic, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeWatcher(id) }
            }
        }
    }

    private func removeWatcher(_ id: UUID) {
        watchers.removeValue(forKey: id)
    }

    /// The values at `paths` now, and again after every write that changes any of them. Every
    /// value they pass through is yielded in order, so a change and its undoing are two
    /// changes rather than none; what modes are decided from.
    public func values(of paths: [String]) -> AsyncStream<[JSONValue?]> {
        let id = UUID()
        let now = paths.map { root.value(at: $0) }
        return AsyncStream { continuation in
            continuation.yield(now)
            valueWatchers[id] = ValueWatcher(paths: paths, last: now, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeValueWatcher(id) }
            }
        }
    }

    private func removeValueWatcher(_ id: UUID) {
        valueWatchers.removeValue(forKey: id)
    }

    private func notifyValues() {
        for (id, var watcher) in valueWatchers {
            let now = watcher.paths.map { root.value(at: $0) }
            guard now != watcher.last else { continue }
            watcher.last = now
            valueWatchers[id] = watcher
            watcher.continuation.yield(now)
        }
    }

    private func notify(path: String, value: JSONValue) {
        guard !watchers.isEmpty else { return }
        let change = StateChange(path: path, value: value)
        for watcher in watchers.values where watcher.pattern.matches(path) {
            watcher.continuation.yield(change)
        }
    }
}

public struct StateChange: Sendable, Hashable {
    public var path: String
    public var value: JSONValue
}

/// A glob over dotted paths: `battery`, `battery.*`, `*`. Used by state subscriptions and,
/// from increment 10, by the socket's topics.
public struct TopicPattern: Sendable, Hashable {
    public var pattern: String

    public init(_ pattern: String) {
        // `state:battery.*` and `battery.*` both mean the same thing to the store.
        self.pattern = pattern.hasPrefix("state:") ? String(pattern.dropFirst(6)) : pattern
    }

    public func matches(_ path: String) -> Bool {
        if pattern == "*" || pattern.isEmpty { return true }
        if pattern.hasSuffix(".*") {
            let prefix = String(pattern.dropLast(2))
            return path == prefix || path.hasPrefix(prefix + ".")
        }
        return pattern == path
    }
}

// MARK: - StateReader

/// A snapshot of the store that records what was read, so the cache knows what a render
/// depends on. Paths are recorded absolute; the convenience accessors are relative to the
/// item being rendered.
public final class StateReader: @unchecked Sendable {
    public let item: String
    /// The store's version when the snapshot was taken.
    public let version: Int
    private let root: JSONValue
    private let lock = NSLock()
    private var read: Set<String> = []

    public init(root: JSONValue, item: String, version: Int = 0) {
        self.root = root
        self.item = item
        self.version = version
    }

    /// This item's own subtree.
    public var own: JSONValue {
        record(item)
        return root.value(at: item) ?? .object([:])
    }

    /// A path inside this item's subtree: `reader["pct"]`.
    public subscript(path: String) -> JSONValue? {
        value(path)
    }

    public func value(_ path: String) -> JSONValue? {
        let absolute = path.isEmpty ? item : "\(item).\(path)"
        record(absolute)
        return root.value(at: absolute)
    }

    /// Anywhere in the store: `reader.global("wifi.ssid")`.
    public func global(_ path: String) -> JSONValue? {
        record(path)
        return root.value(at: path)
    }

    public var paths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return read
    }

    private func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        read.insert(path)
    }
}
