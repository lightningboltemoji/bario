import QuartzCore

/// The present stage for the hole (DESIGN.md §8, §10). The pointer says where the hole is and
/// how strongly it cuts. Two things ease over time, and how far each has got is sampled at the
/// frame's timestamp like any other transition: the click reveal, and the hole closing while
/// Option is held.
public struct Lens {
    /// Below this, a fade is as good as finished.
    static let settled = 0.003

    private var reveal = Ease()
    private var closed = Ease()

    public init() {}

    /// How strongly a hole at `pointer` cuts into a bar at `frame`: 1 over the bar, easing to
    /// 0 at `reach` points away. A smoothstep, so the lens does not pop in.
    public static func proximity(of pointer: CGPoint, to frame: CGRect, reach: Double) -> Double {
        let dx = max(frame.minX - pointer.x, 0, pointer.x - frame.maxX)
        let dy = max(frame.minY - pointer.y, 0, pointer.y - frame.maxY)
        let distance = hypot(dx, dy)
        guard reach > 0 else { return distance <= 0 ? 1 : 0 }
        let t = max(0, 1 - distance / reach)
        return t * t * (3 - 2 * t)
    }

    /// The hole and the reveal for a bar at `frame`, with the pointer where it is at `now`.
    /// `latched` is the click reveal: once the bar has been clicked, everything is uncovered
    /// until the pointer leaves, so the menu you clicked is usable. `closed` is Option being
    /// held, which is when the bar takes clicks instead of cutting a hole for them.
    public mutating func present(pointer: CGPoint?, frame: CGRect, config: HoleConfig,
                                 latched: Bool, closed isClosed: Bool,
                                 at now: CFTimeInterval) -> (hole: Hole, reveal: Double) {
        var hole = Hole(radius: config.radius, feather: config.feather)
        if let pointer {
            hole.center = CGPoint(x: pointer.x - frame.minX, y: pointer.y - frame.minY)
            hole.strength = Lens.proximity(of: pointer, to: frame, reach: config.proximity)
        }
        // A hole too far away to show has nothing to ease: Option pressed anywhere else must not
        // start frames on every bar.
        if hole.strength > Lens.settled {
            closed.head(to: isClosed ? 1 : 0, at: now)
        } else {
            closed.jump(to: isClosed ? 1 : 0)
        }
        reveal.head(to: latched && hole.strength > Lens.settled ? 1 : 0, at: now)
        hole.strength *= 1 - closed.value(at: now)
        return (hole, reveal.value(at: now))
    }

    public func isMoving(at now: CFTimeInterval) -> Bool {
        reveal.isMoving(at: now) || closed.isMoving(at: now)
    }
}

/// An exponential ease toward a target, which is what the probe's reveal always felt like,
/// written as a function of time instead of a step per tick.
struct Ease {
    /// The time constant: it covers 95% of the way in three of these.
    static let time = 0.06

    private var from = 0.0
    private var target = 0.0
    private var start: CFTimeInterval = 0

    /// Head somewhere new from wherever it is now. Heading where it already is changes nothing.
    mutating func head(to target: Double, at now: CFTimeInterval) {
        guard target != self.target else { return }
        from = value(at: now)
        self.target = target
        start = now
    }

    /// Be there already.
    mutating func jump(to target: Double) {
        from = target
        self.target = target
    }

    func value(at now: CFTimeInterval) -> Double {
        let remaining = (from - target) * exp(-max(0, now - start) / Ease.time)
        return abs(remaining) < Lens.settled ? target : target + remaining
    }

    func isMoving(at now: CFTimeInterval) -> Bool {
        value(at: now) != target
    }
}
