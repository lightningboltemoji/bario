import CoreGraphics

/// A rounded rectangle with independent corners, because `border-radius: 8pt 0 0 8pt` is in
/// the design's own stylesheet — the group-of-bubbles look depends on it.
public enum RoundedRect {
    public static func path(in rect: CGRect, corners: Corners) -> CGPath {
        guard !corners.isZero else { return CGPath(rect: rect, transform: nil) }
        let limit = min(rect.width, rect.height) / 2
        let tl = min(max(0, corners.topLeft), limit)
        let tr = min(max(0, corners.topRight), limit)
        let br = min(max(0, corners.bottomRight), limit)
        let bl = min(max(0, corners.bottomLeft), limit)

        let path = CGMutablePath()
        // Bottom-left origin, so "top" is maxY.
        path.move(to: CGPoint(x: rect.minX + bl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - br, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + br), radius: br)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - tr))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - tr, y: rect.maxY), radius: tr)
        path.addLine(to: CGPoint(x: rect.minX + tl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - tl), radius: tl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + bl, y: rect.minY), radius: bl)
        path.closeSubpath()
        return path
    }
}
