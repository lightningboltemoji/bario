import IOSurface

/// Pixels a native process draws on the GPU and bario composites with no copy at all: a pair of
/// IOSurfaces handed over once under a name, and a `frame` naming the one just drawn.
/// DESIGN.md §9.3.
///
/// A pair, because a layer shows new pixels in a surface only when its contents are set to a
/// surface it is not already showing (measured; PLAN.md step 3c): new pixels in the surface a
/// layer holds never reach the screen. So a producer draws into the surface not showing, and
/// `frame` makes it the one that is.
@MainActor
public final class SharedSurfaces {
    public struct Entry {
        public var surfaces: [IOSurface]
        /// Which of `surfaces` a layer shows.
        public var current: Int
        /// The producer, while it runs. Nil for surfaces handed over in-process.
        public var owner: UInt32?
    }

    public enum Outcome: Equatable {
        case accepted
        /// Another producer that is still running holds the name.
        case taken
        case invalid
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Told the name of a surface whose pixels changed: a hand-off, a `frame`, a producer gone.
    public var onChange: (@MainActor (String) -> Void)?
    /// Names a source asked for that nothing had handed over, each said once.
    public private(set) var unknown: Set<String> = []

    public init() {}

    /// A name is one producer's for as long as it runs, and that producer may hand over new
    /// surfaces under it, at a new size, say.
    public func register(_ name: String, surfaces: [IOSurface], owner: UInt32? = nil) -> Outcome {
        guard surfaces.count == 2, !name.isEmpty else { return .invalid }
        if let held = entries[name]?.owner, held != owner { return .taken }
        entries[name] = Entry(surfaces: surfaces, current: 0, owner: owner)
        unknown.remove(name)
        onChange?(name)
        return .accepted
    }

    /// The producer has drawn into the surface at `index`, or, without one, into the one not
    /// showing.
    public func frame(_ name: String, index: Int? = nil) throws {
        guard var entry = entries[name] else {
            throw ProtocolError("no surface named '\(name)' has been handed over")
        }
        let next = index ?? (entry.current + 1) % entry.surfaces.count
        guard entry.surfaces.indices.contains(next) else {
            throw ProtocolError("surface '\(name)' is a pair; frame takes index 0 or 1")
        }
        entry.current = next
        entries[name] = entry
        onChange?(name)
    }

    /// The surface a source naming `name` shows. Nothing, for a name nothing handed over, and
    /// that is said once rather than every commit.
    public func surface(named name: String) -> IOSurface? {
        guard let entry = entries[name] else {
            if unknown.insert(name).inserted {
                warn("no surface named '\(name)' has been handed over; the node shows nothing until one is")
            }
            return nil
        }
        return entry.surfaces[entry.current]
    }

    public func holds(owner: UInt32) -> Bool {
        entries.values.contains { $0.owner == owner }
    }

    /// A producer has gone, and every surface it handed over goes with it.
    public func drop(owner: UInt32) {
        let names = entries.filter { $0.value.owner == owner }.map(\.key)
        for name in names {
            entries[name] = nil
            onChange?(name)
        }
    }
}
