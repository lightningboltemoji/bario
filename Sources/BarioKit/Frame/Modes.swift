import QuartzCore

/// Which modes are on (DESIGN.md §6): a frame-loop input, decided from the values at each mode's
/// paths and from time. A mode is on while one of its `while` paths is truthy, and for `hold`
/// after the last moment it had a reason to be: one of its `changed` paths taking a new value,
/// or its `while` letting go.
///
/// A path's first value is not a change, so starting up, or a source's first line, turns
/// nothing on. The store yields every value a path passes through, so a change and its undoing
/// are two changes rather than none.
@MainActor
final class ModeTracker {
    /// The modes that are on.
    private(set) var active: Set<String> = []
    /// Called when `active` changes.
    var onChange: (() -> Void)?
    /// How many sets of values have been looked at, for tests to wait on.
    private(set) var observations = 0

    private let after: (Double, @escaping @MainActor () -> Void) -> Void
    private let now: () -> CFTimeInterval
    private var modes: [ModeConfig] = []
    private var watch: Task<Void, Never>?
    /// What each watched path last held, and whether it has held anything yet.
    private var values: [String: JSONValue] = [:]
    private var seen: Set<String> = []
    /// Per mode: whether a `while` path held, and when the mode last had a reason to be on.
    private var holding: [String: Bool] = [:]
    private var lastReason: [String: CFTimeInterval] = [:]

    init(after: @escaping (Double, @escaping @MainActor () -> Void) -> Void,
         now: @escaping () -> CFTimeInterval) {
        self.after = after
        self.now = now
    }

    /// Watch these modes' paths in `store`, forgetting everything about the last set.
    func configure(_ modes: [ModeConfig], store: StateStore) {
        guard modes != self.modes else { return }
        self.modes = modes
        watch?.cancel()
        values = [:]
        seen = []
        holding = [:]
        lastReason = [:]
        update()
        let paths = Array(Set(modes.flatMap(\.paths))).sorted()
        guard !paths.isEmpty else { return }
        watch = Task { [weak self] in
            for await values in await store.values(of: paths) {
                guard !Task.isCancelled else { return }
                self?.observe(Dictionary(uniqueKeysWithValues: zip(paths, values)))
            }
        }
    }

    private func observe(_ next: [String: JSONValue?]) {
        observations += 1
        let time = now()
        var changed: Set<String> = []
        for (path, value) in next {
            if seen.contains(path), values[path] != value { changed.insert(path) }
            if let value, !value.isNull { seen.insert(path) }
            values[path] = value
        }
        for mode in modes {
            let held = mode.whilePaths.contains { values[$0]?.isTruthy == true }
            let letGo = holding[mode.name] == true && !held
            holding[mode.name] = held
            if letGo || mode.changed.contains(where: changed.contains) {
                lastReason[mode.name] = time
                expire(mode, after: mode.hold)
            }
        }
        update()
    }

    /// Look again once `mode`'s hold has run out. A timer that fires early looks again later
    /// rather than leaving the mode on.
    private func expire(_ mode: ModeConfig, after seconds: Double) {
        guard seconds > 0 else { return }
        after(seconds) { [weak self] in
            guard let self, let since = self.lastReason[mode.name] else { return }
            let left = since + mode.hold - self.now()
            if left > 0 { self.expire(mode, after: left) }
            self.update()
        }
    }

    private func update() {
        let time = now()
        let next = Set(modes.filter { mode in
            holding[mode.name] == true
                || lastReason[mode.name].map { time < $0 + mode.hold } == true
        }.map(\.name))
        guard next != active else { return }
        active = next
        onChange?()
    }
}
