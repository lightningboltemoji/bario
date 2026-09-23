import CoreGraphics

/// Edge insets in points, in CSS order: the stylesheet's `padding: 2pt 9pt`.
public struct Insets: Sendable, Hashable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public static let zero = Insets(0)

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top; self.right = right; self.bottom = bottom; self.left = left
    }

    public init(_ all: Double) { self.init(top: all, right: all, bottom: all, left: all) }

    /// The CSS shorthand: 1, 2, 3 or 4 values.
    public init?(values: [Double]) {
        switch values.count {
        case 1: self.init(values[0])
        case 2: self.init(top: values[0], right: values[1], bottom: values[0], left: values[1])
        case 3: self.init(top: values[0], right: values[1], bottom: values[2], left: values[1])
        case 4: self.init(top: values[0], right: values[1], bottom: values[2], left: values[3])
        default: return nil
        }
    }

    public var horizontal: Double { left + right }
    public var vertical: Double { top + bottom }

    public func inset(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + left, y: rect.minY + bottom,
               width: Swift.max(0, rect.width - horizontal),
               height: Swift.max(0, rect.height - vertical))
    }
}
