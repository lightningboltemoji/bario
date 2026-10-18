import CoreGraphics
import Foundation

/// The measuring half of extraction (PLAN.md W8): an image's pixels in Oklab, gathered into a
/// histogram, and weighted k-means over the histogram's bins. Deterministic throughout, so the
/// same image always gives the same palette.
struct Quantizer {
    /// One occupied cell of the 32³ grid: how much of the image fell in it, and the mean of
    /// what did, not the cell's centre.
    struct Bin: Hashable {
        var color: Oklab
        /// Pixels, or their alpha where they are translucent.
        var weight: Double
    }

    static let grid = 32
    /// The widest an image is read at. The capture is taken this wide and a file thumbnailed to
    /// it; anything wider is scaled down first, so a palette does not depend on where its image
    /// came from.
    static let width = 320

    /// The occupied cells, in grid order.
    private(set) var bins: [Bin]
    private(set) var total: Double

    init(bins: [Bin]) {
        self.bins = bins
        total = bins.reduce(0) { $0 + $1.weight }
    }

    /// Read through extended linear sRGB, so a Display P3 capture's colours outside sRGB are
    /// measured as they are (PLAN.md W4).
    init(image: CGImage) {
        let width = max(1, min(image.width, Quantizer.width))
        let height = max(1, Int((Double(image.height) * Double(width) / Double(max(1, image.width))).rounded()))
        var cells = [Double](repeating: 0, count: Quantizer.grid * Quantizer.grid * Quantizer.grid * 4)

        if let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
           let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 32,
                                   bytesPerRow: width * 16, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                       | CGBitmapInfo.floatComponents.rawValue
                                       | CGBitmapInfo.byteOrder32Little.rawValue),
           let data = context.data {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = data.bindMemory(to: Float.self, capacity: width * height * 4)
            for index in 0..<(width * height) {
                let alpha = Double(pixels[index * 4 + 3])
                guard alpha > 0 else { continue }
                let color = Oklab(linearRed: Double(pixels[index * 4]) / alpha,
                                  green: Double(pixels[index * 4 + 1]) / alpha,
                                  blue: Double(pixels[index * 4 + 2]) / alpha)
                let cell = Quantizer.cell(of: color) * 4
                cells[cell] += alpha
                cells[cell + 1] += color.l * alpha
                cells[cell + 2] += color.a * alpha
                cells[cell + 3] += color.b * alpha
            }
        }

        var bins: [Bin] = []
        for cell in stride(from: 0, to: cells.count, by: 4) where cells[cell] > 0 {
            let weight = cells[cell]
            bins.append(Bin(color: Oklab(l: cells[cell + 1] / weight, a: cells[cell + 2] / weight,
                                         b: cells[cell + 3] / weight),
                            weight: weight))
        }
        self.init(bins: bins)
    }

    /// L over 0…1 and a and b over ±0.4, 32 steps each; anything beyond goes in the edge cell.
    static func cell(of color: Oklab) -> Int {
        func step(_ value: Double, from low: Double, to high: Double) -> Int {
            let t = (value - low) / (high - low)
            return t.isNaN ? 0 : min(grid - 1, max(0, Int(t * Double(grid))))
        }
        return (step(color.l, from: 0, to: 1) * grid + step(color.a, from: -0.4, to: 0.4)) * grid
            + step(color.b, from: -0.4, to: 0.4)
    }

    /// Weighted k-means over the bins. Seeded with the heaviest bin, then each time with the bin
    /// furthest from every centre so far, by √weight × distance², so a small vivid patch can
    /// claim a centre of its own. Runs until no centre moves by 10⁻⁵. Returns the clusters'
    /// centres and weights, heaviest first, without empty ones.
    func clusters(k: Int = 16) -> [(color: Oklab, weight: Double)] {
        guard let heaviest = bins.indices.max(by: { bins[$0].weight < bins[$1].weight }) else { return [] }
        func distance2(_ x: Oklab, _ y: Oklab) -> Double {
            let (dl, da, db) = (x.l - y.l, x.a - y.a, x.b - y.b)
            return dl * dl + da * da + db * db
        }

        var centres = [bins[heaviest].color]
        var nearest = bins.map { distance2($0.color, centres[0]) }
        while centres.count < k {
            var best = -1, reach = 0.0
            for index in bins.indices {
                let score = bins[index].weight.squareRoot() * nearest[index]
                if score > reach { (best, reach) = (index, score) }
            }
            guard best >= 0 else { break }          // every bin is a centre already
            centres.append(bins[best].color)
            for index in bins.indices {
                nearest[index] = min(nearest[index], distance2(bins[index].color, bins[best].color))
            }
        }

        var members = [Int](repeating: 0, count: bins.count)
        var weights = [Double](repeating: 0, count: centres.count)
        for _ in 0..<100 {
            var sums = [(l: Double, a: Double, b: Double)](repeating: (0, 0, 0), count: centres.count)
            weights = [Double](repeating: 0, count: centres.count)
            for (index, bin) in bins.enumerated() {
                var closest = 0, least = Double.infinity
                for (c, centre) in centres.enumerated() {
                    let d = distance2(bin.color, centre)
                    if d < least { (closest, least) = (c, d) }
                }
                members[index] = closest
                weights[closest] += bin.weight
                sums[closest].l += bin.color.l * bin.weight
                sums[closest].a += bin.color.a * bin.weight
                sums[closest].b += bin.color.b * bin.weight
            }
            var moved = 0.0
            for c in centres.indices where weights[c] > 0 {
                let next = Oklab(l: sums[c].l / weights[c], a: sums[c].a / weights[c], b: sums[c].b / weights[c])
                moved = max(moved, next.distance(to: centres[c]))
                centres[c] = next
            }
            if moved < 1e-5 { break }
        }

        return centres.indices
            .filter { weights[$0] > 0 }
            .map { (color: centres[$0], weight: weights[$0]) }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.color.l > $1.color.l }
    }
}
