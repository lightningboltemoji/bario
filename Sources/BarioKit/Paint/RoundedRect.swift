import CoreGraphics
import Foundation

/// A rounded rectangle with independent corners, because `border-radius: 8pt 0 0 8pt` is in
/// the design's own stylesheet — the group-of-bubbles look depends on it.
public enum RoundedRect {
    public static func path(in rect: CGRect, corners: Corners, shapes: CornerShapes = .round) -> CGPath {
        guard !corners.isZero else { return CGPath(rect: rect, transform: nil) }
        let limit = min(rect.width, rect.height) / 2
        let tl = min(max(0, corners.topLeft), limit)
        let tr = min(max(0, corners.topRight), limit)
        let br = min(max(0, corners.bottomRight), limit)
        let bl = min(max(0, corners.bottomLeft), limit)

        let path = CGMutablePath()
        // Bottom-left origin, so "top" is maxY. Each corner runs from where it leaves one edge
        // to where it meets the next, bulging toward the rectangle's own corner.
        path.move(to: CGPoint(x: rect.minX + bl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - br, y: rect.minY))
        corner(path, at: CGPoint(x: rect.maxX, y: rect.minY), from: CGVector(dx: -1, dy: 0),
               to: CGVector(dx: 0, dy: 1), radius: br, shape: shapes.bottomRight)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tr))
        corner(path, at: CGPoint(x: rect.maxX, y: rect.maxY), from: CGVector(dx: 0, dy: -1),
               to: CGVector(dx: -1, dy: 0), radius: tr, shape: shapes.topRight)
        path.addLine(to: CGPoint(x: rect.minX + tl, y: rect.maxY))
        corner(path, at: CGPoint(x: rect.minX, y: rect.maxY), from: CGVector(dx: 1, dy: 0),
               to: CGVector(dx: 0, dy: -1), radius: tl, shape: shapes.topLeft)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bl))
        corner(path, at: CGPoint(x: rect.minX, y: rect.minY), from: CGVector(dx: 0, dy: 1),
               to: CGVector(dx: 1, dy: 0), radius: bl, shape: shapes.bottomLeft)
        path.closeSubpath()
        return path
    }

    /// Samples per corner for the shapes CoreGraphics has no primitive for. At a menu bar's
    /// radii the chords sit well under a hundredth of a point off the curve.
    static let samples = 24

    /// One corner: the path is at `c + from·r`, and ends at `c + to·r`. `from` and `to` point
    /// from the corner `c` along the edges it joins.
    private static func corner(_ path: CGMutablePath, at c: CGPoint, from: CGVector, to: CGVector,
                               radius r: Double, shape k: Double) {
        guard r > 0 else { return }
        // In the corner's own square, (1, 0) is where the curve starts, (0, 1) where it ends,
        // (1, 1) the rectangle's corner and (0, 0) the far side of the radius.
        func point(_ u: Double, _ v: Double) -> CGPoint {
            CGPoint(x: c.x + (from.dx * (1 - v) + to.dx * (1 - u)) * r,
                    y: c.y + (from.dy * (1 - v) + to.dy * (1 - u)) * r)
        }
        switch k {
        case 1:
            path.addArc(tangent1End: c, tangent2End: point(0, 1), radius: r)
        case .infinity:
            path.addLine(to: c)
            path.addLine(to: point(0, 1))
        case 0:
            path.addLine(to: point(0, 1))
        case -.infinity:
            path.addLine(to: point(0, 0))
            path.addLine(to: point(0, 1))
        default:
            // CSS Borders 4: superellipse(K) is |u|^n + |v|^n = 1 with n = 2^|K|, and a negative
            // K is the convex curve mirrored across the chord, so scoop is a concave quarter circle.
            let exponent = 2 / pow(2, abs(k))
            for step in 1...samples {
                let t = Double(step) / Double(samples) * .pi / 2
                let u = pow(cos(t), exponent)
                let v = pow(sin(t), exponent)
                path.addLine(to: k > 0 ? point(u, v) : point(1 - v, 1 - u))
            }
        }
    }
}
