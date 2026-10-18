import CoreGraphics
import Foundation

/// One display's wallpaper, measured (PLAN.md W8–W11): the colours it is made of, the slots
/// a stylesheet names, and the seeds a scheme grows from. Slots and seeds promise nothing about
/// contrast with each other (W16); when two come out alike, that is true of the image.
public struct Palette: Sendable, Hashable {
    /// The k-means clusters, largest first.
    public var clusters: [Cluster]
    /// Every slot, always: what nothing in the image fits is made up.
    public var slots: [Slot.Name: Slot]
    /// The image's main hues, strongest first. Empty when the image is all but grey.
    public var seeds: [Seed]
    /// What made-up vibrant slots took their hue from when there was no seed.
    public var accent: RGBA

    /// macOS's default blue, for a palette measured with no accent at hand.
    public static let defaultAccent = RGBA(r: 0, g: 0.48, b: 1)
    /// The store's top-level key that bario writes every display's palette under (W14).
    public static let storeKey = "wallpaper"

    /// Measure an image. `previous` is the last palette of the same display, which a slot keeps
    /// its cluster from through a near-tie (W11). `accent` is what a vibrant slot made up for an
    /// image with no seed takes its hue from.
    public static func extract(_ image: CGImage, previous: Palette? = nil,
                               accent: RGBA = Palette.defaultAccent) -> Palette {
        let quantizer = Quantizer(image: image)
        let total = quantizer.total
        let clusters = total > 0
            ? quantizer.clusters().map { Cluster(color: $0.color, population: $0.weight / total) }
            : []
        return Palette(clusters: clusters, seeds: Seed.find(in: quantizer), previous: previous, accent: accent)
    }

    /// Slots chosen from what was measured.
    init(clusters: [Cluster], seeds: [Seed], previous: Palette?, accent: RGBA) {
        self.clusters = clusters
        self.seeds = seeds
        self.accent = accent
        slots = Slot.choose(from: clusters, seeds: seeds, previous: previous, accent: accent)
    }

    /// What there is with no image at all: every slot made up, vibrant ones from the accent and
    /// muted ones grey, and no seed. What `wallpaper()` gives before a display has a palette,
    /// or where it cannot have one.
    public static func nothing(accent: RGBA) -> Palette {
        Palette(clusters: [], seeds: [], previous: nil, accent: accent)
    }

    /// The same measurement with another accent, which only made-up vibrant slots of an image
    /// with no seed depend on.
    public func with(accent: RGBA) -> Palette {
        guard accent != self.accent else { return self }
        return Palette(clusters: clusters, seeds: seeds, previous: self, accent: accent)
    }

    public subscript(_ name: Slot.Name) -> Slot { slots[name]! }

    /// The slot `dominant` shares its cluster with, if any: it is measured apart from the
    /// slots, so it is often one of them.
    public var dominantSameAs: Slot.Name? {
        guard let cluster = slots[.dominant]?.cluster else { return nil }
        return Slot.Name.chosen.first { slots[$0]?.cluster == cluster }
    }
}

/// One colour the image is made of: a k-means centre, and how much of the image is nearest it.
public struct Cluster: Sendable, Hashable {
    /// May lie outside sRGB, as a P3 wallpaper's colours do.
    public var color: Oklab
    /// 0…1 of the image.
    public var population: Double

    public init(color: Oklab, population: Double) {
        self.color = color
        self.population = population
    }

    public var lch: OKLCH { color.lch }
    public var rgba: RGBA { color.rgba() }

    /// Chroma as a fraction of the most sRGB holds at this lightness and hue: saturation,
    /// measured perceptually. Above 1 for a colour beyond sRGB.
    public var relativeChroma: Double {
        let lch = self.lch
        let most = OKLCH.maxChroma(l: lch.l, h: lch.h)
        return most > 0 ? lch.c / most : 0
    }
}

/// What fills one named slot: a cluster's colour, or one made up because nothing fit.
public struct Slot: Sendable, Hashable {
    public enum Name: String, Sendable, Hashable, CaseIterable {
        case dominant
        case vibrant
        case vibrantDark = "vibrant-dark"
        case vibrantLight = "vibrant-light"
        case muted
        case mutedDark = "muted-dark"
        case mutedLight = "muted-light"

        /// The slots that choose, in the order they choose: each base before its variants.
        static let chosen: [Name] = [.vibrant, .vibrantDark, .vibrantLight, .muted, .mutedDark, .mutedLight]
    }

    public var color: Oklab
    /// The cluster it was taken from, or nil when it was made up.
    public var cluster: Int?

    public var found: Bool { cluster != nil }
    public var rgba: RGBA { color.rgba() }
}

// MARK: - Choosing slots

extension Slot {
    /// What a slot asks for (W9). Starting numbers, tuned on the prototype's corpus, and free
    /// to move.
    struct Spec {
        var l: Double
        var lightness: ClosedRange<Double>
        var chroma: Double
        var relativeChroma: ClosedRange<Double>
        var leastChroma: Double
        /// For a variant: its base, and whether it is darker or lighter than it.
        var base: (name: Name, darker: Bool)?

        var isVibrant: Bool { chroma == 1 }
    }

    static let specs: [Name: Spec] = [
        .vibrant: Spec(l: 0.64, lightness: 0.45...0.82, chroma: 1, relativeChroma: 0.45...1, leastChroma: 0.05),
        .vibrantDark: Spec(l: 0.38, lightness: 0.15...0.52, chroma: 1, relativeChroma: 0.40...1,
                           leastChroma: 0.04, base: (.vibrant, true)),
        .vibrantLight: Spec(l: 0.84, lightness: 0.72...0.96, chroma: 1, relativeChroma: 0.35...1,
                            leastChroma: 0.04, base: (.vibrant, false)),
        .muted: Spec(l: 0.60, lightness: 0.40...0.78, chroma: 0.22, relativeChroma: 0.06...0.45,
                     leastChroma: 0.012),
        .mutedDark: Spec(l: 0.32, lightness: 0.10...0.48, chroma: 0.22, relativeChroma: 0.06...0.45,
                         leastChroma: 0.012, base: (.muted, true)),
        .mutedLight: Spec(l: 0.86, lightness: 0.72...0.97, chroma: 0.22, relativeChroma: 0.06...0.45,
                          leastChroma: 0.012, base: (.muted, false)),
    ]

    /// How far a variant stays from its base, in L: enough to tell two fills apart, about
    /// 1.6–1.9:1, and not enough for text (W9, W16).
    static let gap = 0.15
    /// Clusters smaller than this share of the image are noise to a slot.
    static let least = 0.002
    /// A made-up vibrant base's relative chroma follows its source's, held to this: at least
    /// what a vibrant slot accepts, and at most the plan's 85%. At a flat 85%, a pale image
    /// with a faint seed got a vibrant slot far louder than anything in the picture.
    static let madeUpChroma = 0.45...0.85

    static func choose(from clusters: [Cluster], seeds: [Seed], previous: Palette?,
                       accent: RGBA) -> [Name: Slot] {
        var slots: [Name: Slot] = [:]
        if !clusters.isEmpty { slots[.dominant] = Slot(color: clusters[0].color, cluster: 0) }

        let largest = clusters.first?.population ?? 1
        let measured = clusters.map { (lch: $0.lch, relative: min(1, $0.relativeChroma)) }
        var taken: Set<Int> = []
        for name in Name.chosen {
            let spec = specs[name]!
            let base = spec.base.flatMap { slots[$0.name] }.map(\.color.lch)

            var scored: [(index: Int, score: Double)] = []
            for (index, cluster) in clusters.enumerated() where !taken.contains(index) {
                let (lch, relative) = measured[index]
                guard cluster.population >= least, lch.c >= spec.leastChroma,
                      spec.lightness.contains(lch.l), spec.relativeChroma.contains(relative) else { continue }
                if let base, let darker = spec.base?.darker {
                    guard darker ? lch.l <= base.l - gap : lch.l >= base.l + gap else { continue }
                }
                scored.append((index, score(lch: lch, relative: relative, population: cluster.population / largest,
                                            spec: spec)))
            }

            if let best = scored.max(by: { $0.score < $1.score }) {
                var pick = best.index
                // A near-tie goes the way it went last time (W11).
                if let last = previous?.slots[name], last.found {
                    let near = scored.filter { clusters[$0.index].color.distance(to: last.color) <= 0.06
                                               && $0.score >= best.score * 0.95 }
                    if let kept = near.min(by: { clusters[$0.index].color.distance(to: last.color)
                                                 < clusters[$1.index].color.distance(to: last.color) }) {
                        pick = kept.index
                    }
                }
                taken.insert(pick)
                slots[name] = Slot(color: clusters[pick].color, cluster: pick)
            } else {
                slots[name] = Slot(color: madeUp(name, spec: spec, base: base, clusters: clusters,
                                                 seeds: seeds, accent: accent).lab, cluster: nil)
            }
        }
        if slots[.dominant] == nil { slots[.dominant] = slots[.muted].map { Slot(color: $0.color, cluster: nil) } }
        return slots
    }

    /// 0.40 for lightness, 0.35 for chroma and 0.25 for √(population ÷ the largest cluster's).
    /// Lightness and chroma score 1 at the slot's target and 0 at the far end of its range.
    static func score(lch: OKLCH, relative: Double, population: Double, spec: Spec) -> Double {
        func closeness(_ value: Double, to target: Double, in range: ClosedRange<Double>) -> Double {
            let reach = max(target - range.lowerBound, range.upperBound - target)
            return reach > 0 ? 1 - abs(value - target) / reach : 1
        }
        return 0.40 * closeness(lch.l, to: spec.l, in: spec.lightness)
            + 0.35 * closeness(relative, to: spec.chroma, in: spec.relativeChroma)
            + 0.25 * population.squareRoot()
    }

    /// A slot nothing in the image fits (W9). A vibrant base takes the strongest seed's hue, or
    /// the accent's without one, at its own lightness and that colour's relative chroma, kept
    /// between what a vibrant slot accepts and 85% of the most sRGB holds.
    /// A muted base is the cluster nearest its lightness, moved there and kept muted. A variant
    /// is its base's hue and relative chroma at its own lightness, or further, so the gap holds.
    static func madeUp(_ name: Name, spec: Spec, base: OKLCH?, clusters: [Cluster], seeds: [Seed],
                       accent: RGBA) -> OKLCH {
        func at(_ l: Double, hue: Double, relative: Double) -> OKLCH {
            OKLCH(l: l, c: relative * OKLCH.maxChroma(l: l, h: hue), h: hue)
        }
        if let base, let darker = spec.base?.darker {
            let l = darker ? min(spec.l, base.l - gap) : max(spec.l, base.l + gap)
            let most = OKLCH.maxChroma(l: base.l, h: base.h)
            return at(min(1, max(0, l)), hue: base.h, relative: most > 0 ? min(1, base.c / most) : 0)
        }
        if spec.isVibrant {
            let source = seeds.first.map(\.color.lch) ?? OKLCH(accent)
            let most = OKLCH.maxChroma(l: source.l, h: source.h)
            let relative = most > 0 ? source.c / most : 0
            return at(spec.l, hue: source.h,
                      relative: min(madeUpChroma.upperBound, max(madeUpChroma.lowerBound, relative)))
        }
        let candidates = clusters.filter { $0.population >= least }
        guard let nearest = (candidates.isEmpty ? clusters : candidates)
            .min(by: { abs($0.lch.l - spec.l) < abs($1.lch.l - spec.l) }) else {
            return OKLCH(l: spec.l, c: 0, h: 0)
        }
        return at(spec.l, hue: nearest.lch.h, relative: min(nearest.relativeChroma, spec.relativeChroma.upperBound))
    }
}

// MARK: - Seeds

/// One of the image's main hues (W10): a peak in the histogram of hue, weighted towards
/// colour that covers ground, so a broad wash outweighs a small vivid patch.
public struct Seed: Sendable, Hashable {
    /// The image's colour around this hue, weighted by C².
    public var color: Oklab
    /// The peak's height, as a share of all the colour in the image.
    public var mass: Double

    public var rgba: RGBA { color.rgba() }

    /// At most four, at least 30° apart and at least 5% of the highest peak, strongest first.
    /// None when under 0.4% of the image carries colour.
    static func find(in quantizer: Quantizer) -> [Seed] {
        let bins = quantizer.bins
        guard quantizer.total > 0 else { return [] }
        let lchs = bins.map(\.color.lch)

        var colored = 0.0
        var hues = [Double](repeating: 0, count: 72)
        for (bin, lch) in zip(bins, lchs) {
            let weight = min(1.5, max(0, (lch.c - 0.015) / 0.085))
            guard weight > 0 else { continue }
            colored += bin.weight
            hues[min(71, Int(lch.h / 5))] += bin.weight / quantizer.total * weight
        }
        guard colored / quantizer.total >= 0.004 else { return [] }

        // A Gaussian of σ 10°, two bins, around the circle. At 15° neighbouring hues merge.
        let kernel = (-6...6).map { exp(-Double($0 * $0) / (2 * 2 * 2)) }
        let sum = kernel.reduce(0, +)
        let smooth = (0..<72).map { bin in
            (-6...6).reduce(0.0) { total, offset in
                total + hues[(bin + offset + 72) % 72] * kernel[offset + 6] / sum
            }
        }
        let peaks = (0..<72).filter { bin in
            smooth[bin] > 0 && smooth[bin] > smooth[(bin + 71) % 72] && smooth[bin] >= smooth[(bin + 1) % 72]
        }.sorted { smooth[$0] != smooth[$1] ? smooth[$0] > smooth[$1] : $0 < $1 }
        guard let highest = peaks.first.map({ smooth[$0] }) else { return [] }
        let total = hues.reduce(0, +)

        var chosen: [Int] = []
        for peak in peaks where smooth[peak] >= highest * 0.05 && chosen.count < 4 {
            let apart = chosen.allSatisfy { other in
                let d = abs(peak - other) * 5
                return min(d, 360 - d) >= 30
            }
            if apart { chosen.append(peak) }
        }

        return chosen.compactMap { peak in
            let hue = Double(peak) * 5 + 2.5
            var weight = 0.0
            var sum = (l: 0.0, a: 0.0, b: 0.0)
            for (bin, lch) in zip(bins, lchs) where lch.c >= OKLCH.achromatic {
                let d = abs(lch.h - hue)
                guard min(d, 360 - d) <= 15 else { continue }
                let w = bin.weight * lch.c * lch.c
                weight += w
                sum = (sum.l + bin.color.l * w, sum.a + bin.color.a * w, sum.b + bin.color.b * w)
            }
            guard weight > 0 else { return nil }
            return Seed(color: Oklab(l: sum.l / weight, a: sum.a / weight, b: sum.b / weight),
                        mass: smooth[peak] / total)
        }
    }
}

// MARK: - In the store

extension Palette {
    /// One display's entry under the store's `wallpaper` key (W14): measurements, rounded so
    /// that a palette that has not changed is a write that changes nothing. Colours are each
    /// given as the sRGB hex a stylesheet gets, and the OKLCH that was measured.
    public func json(display: String, id: CGDirectDisplayID, primary: Bool) -> JSONValue {
        func round(_ value: Double, _ places: Double) -> JSONValue {
            let scale = pow(10, places)
            return .number((value * scale).rounded() / scale)
        }
        func color(_ color: Oklab) -> [String: JSONValue] {
            let lch = color.lch
            return ["hex": .string(color.rgba().hex),
                    "oklch": .array([round(lch.l, 3), round(lch.c, 3), round(lch.h, 1)])]
        }
        var slots: [String: JSONValue] = [:]
        for (name, slot) in self.slots {
            var entry = color(slot.color)
            entry["found"] = .bool(slot.found)
            if name == .dominant, let same = dominantSameAs { entry["same-as"] = .string(same.rawValue) }
            slots[name.rawValue] = .object(entry)
        }
        return .object([
            "name": .string(display),
            "id": .number(Double(id)),
            "primary": .bool(primary),
            "clusters": .array(clusters.map { cluster in
                var entry = color(cluster.color)
                entry["population"] = round(cluster.population, 4)
                return .object(entry)
            }),
            "slots": .object(slots),
            "seeds": .array(seeds.map { seed in
                var entry = color(seed.color)
                entry["mass"] = round(seed.mass, 3)
                return .object(entry)
            }),
        ])
    }
}
