import CoreGraphics

/// The single flex pass, as arithmetic over sizes: no styles, no nodes, no AppKit.
/// DESIGN.md §6.
public enum Flex {
    public struct Item: Sendable, Hashable {
        public var natural: Double
        public var min: Double
        public var max: Double
        public var grow: Double
        public var shrink: Double

        public init(natural: Double, min: Double = 0, max: Double = .infinity,
                    grow: Double = 0, shrink: Double = 1) {
            self.natural = natural
            self.min = min
            self.max = max
            self.grow = grow
            self.shrink = shrink
        }
    }

    /// Final widths, in the order given.
    public static func solve(_ items: [Item], available: Double, gap: Double) -> [Double] {
        guard !items.isEmpty else { return [] }
        var widths = items.map { Swift.min(Swift.max($0.natural, $0.min), $0.max) }
        let gaps = gap * Double(items.count - 1)
        var free = available - gaps - widths.reduce(0, +)

        if free > 0 {
            distributeGrowth(&widths, items, free: &free)
        } else if free < 0 {
            distributeShrink(&widths, items, deficit: -free)
        }
        return widths
    }

    /// Hand out free space to `grow`, repeating once for anything that hit its max so the
    /// leftovers still land somewhere.
    private static func distributeGrowth(_ widths: inout [Double], _ items: [Item], free: inout Double) {
        var eligible = Set(items.indices.filter { items[$0].grow > 0 })
        while free > 0.0001, !eligible.isEmpty {
            let total = eligible.reduce(0.0) { $0 + items[$1].grow }
            guard total > 0 else { return }
            var spent = 0.0
            var saturated: Set<Int> = []
            for index in eligible.sorted() {
                let share = free * items[index].grow / total
                let room = items[index].max - widths[index]
                let take = Swift.min(share, room)
                widths[index] += take
                spent += take
                if take < share - 0.0001 { saturated.insert(index) }
            }
            free -= spent
            if spent < 0.0001 { return }
            eligible.subtract(saturated)
        }
    }

    /// Take the deficit from `shrink`, weighted by size as CSS does, floored at `min`.
    private static func distributeShrink(_ widths: inout [Double], _ items: [Item], deficit: Double) {
        var remaining = deficit
        var eligible = Set(items.indices.filter { items[$0].shrink > 0 && widths[$0] > items[$0].min })
        while remaining > 0.0001, !eligible.isEmpty {
            let total = eligible.reduce(0.0) { $0 + items[$1].shrink * widths[$1] }
            guard total > 0 else { return }
            var freed = 0.0
            var floored: Set<Int> = []
            for index in eligible.sorted() {
                let share = remaining * (items[index].shrink * widths[index]) / total
                let room = widths[index] - items[index].min
                let take = Swift.min(share, room)
                widths[index] -= take
                freed += take
                if take < share - 0.0001 { floored.insert(index) }
            }
            remaining -= freed
            if freed < 0.0001 { return }
            eligible.subtract(floored)
        }
    }
}
