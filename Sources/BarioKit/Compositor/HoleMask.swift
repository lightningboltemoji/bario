import AppKit

/// The hole, as the bar's mask (DESIGN.md §10): a lens centred on the pointer, opaque but for a
/// clear circle with the feather at its edge; four opaque bands filling the bar around it; and
/// one opaque layer over everything at `1 − strength`. Where the lens is clear by `h`, the
/// mask's alpha is `(1 − s) + (1 − h)·s = 1 − s·h`, which is what the painter's
/// `destinationOut` pass cut. Moving the hole sets properties and draws nothing.
@MainActor
final class HoleMask {
    let layer: CALayer
    let lens: CALayer
    let bands: [CALayer]
    let strength: CALayer

    private struct LensKey: Hashable {
        var radius: Double
        var feather: Double
        var scale: CGFloat
    }

    /// Lens images by radius, feather and scale. A config has one hole, and a machine a
    /// couple of scales, so this never grows past a handful.
    private static var lenses: [LensKey: CGImage] = [:]

    init(factory: inout LayerFactory) {
        layer = factory.make()
        lens = factory.make()
        bands = (0..<4).map { _ in factory.make() }
        strength = factory.make()
        let opaque = CGColor(gray: 0, alpha: 1)
        for band in bands { band.backgroundColor = opaque }
        strength.backgroundColor = opaque
        layer.sublayers = [lens] + bands + [strength]
    }

    func update(_ hole: Hole, in bounds: CGRect, scale: CGFloat) {
        layer.place(bounds)
        let radius = max(hole.radius, 0.5)
        lens.updateContents(HoleMask.lens(radius: radius, feather: hole.feather, scale: scale))
        let circle = CGRect(x: hole.center.x - radius, y: hole.center.y - radius,
                            width: radius * 2, height: radius * 2)
        lens.place(circle)

        let left = max(bounds.minX, min(circle.minX, bounds.maxX))
        let right = min(bounds.maxX, max(circle.maxX, bounds.minX))
        let bottom = max(bounds.minY, min(circle.minY, bounds.maxY))
        let top = min(bounds.maxY, max(circle.maxY, bounds.minY))
        bands[0].place(CGRect(x: bounds.minX, y: bounds.minY, width: left - bounds.minX, height: bounds.height))
        bands[1].place(CGRect(x: right, y: bounds.minY, width: bounds.maxX - right, height: bounds.height))
        bands[2].place(CGRect(x: left, y: bounds.minY, width: max(0, right - left), height: bottom - bounds.minY))
        bands[3].place(CGRect(x: left, y: top, width: max(0, right - left), height: bounds.maxY - top))
        strength.place(bounds)
        assign(strength, \.opacity, Float(1 - min(max(hole.strength, 0), 1)))
    }

    /// Opaque, with a clear disc two radii across whose edge fades over the feather: the
    /// painter's radial `destinationOut` gradient at full strength.
    static func lens(radius: Double, feather: Double, scale: CGFloat) -> CGImage? {
        let key = LensKey(radius: radius, feather: feather, scale: scale)
        if let cached = lenses[key] { return cached }
        let side = max(1, Int((radius * 2 * scale).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let points = CGFloat(side) / scale
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: points, height: points))

        let center = CGPoint(x: points / 2, y: points / 2)
        let end = radius
        let start = max(end - max(feather, 0), 0)
        ctx.setBlendMode(.destinationOut)
        if feather > 0.01 {
            let gray = CGColorSpaceCreateDeviceGray()
            if let inner = CGColor(colorSpace: gray, components: [0, 1]),
               let outer = CGColor(colorSpace: gray, components: [0, 0]),
               let gradient = CGGradient(colorsSpace: gray, colors: [inner, outer] as CFArray,
                                         locations: [0, 1]) {
                ctx.drawRadialGradient(gradient, startCenter: center, startRadius: start,
                                       endCenter: center, endRadius: end,
                                       options: [.drawsBeforeStartLocation])
            }
        } else {
            ctx.fillEllipse(in: CGRect(x: center.x - end, y: center.y - end, width: end * 2, height: end * 2))
        }
        let image = ctx.makeImage()
        if lenses.count > 16 { lenses.removeAll() }
        lenses[key] = image
        return image
    }
}
