import AppKit
import CoreGraphics

/// A vector display list: the `canvas` node's payload, and from increment 16 also what a
/// renderer module returns. Parsed once when the scene is built. DESIGN.md §9.1.
public struct DisplayList: Sendable {
    public var ops: [CanvasOp]
    /// Ops that could not be parsed, by index and reason. Reported, never fatal.
    public var problems: [String]
    /// The JSON it was parsed from, which is what a raster key compares: two lists from the
    /// same JSON draw the same pixels.
    public var source: [JSONValue]

    public init(ops: [CanvasOp] = [], problems: [String] = [], source: [JSONValue] = []) {
        self.ops = ops
        self.problems = problems
        self.source = source
    }

    /// One bad op is dropped with a reason; the rest of the drawing still happens.
    public static func parse(_ raw: [JSONValue]) -> DisplayList {
        var list = DisplayList(source: raw)
        for (index, value) in raw.enumerated() {
            do {
                if let op = try CanvasOp.parse(value) { list.ops.append(op) }
            } catch let error as CanvasError {
                list.problems.append("op \(index): \(error.description)")
            } catch {
                list.problems.append("op \(index): \(error)")
            }
        }
        return list
    }
}

public struct CanvasError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum CanvasOp: Sendable {
    case fill(CanvasPaint, CanvasPath)
    case stroke(CanvasPaint, CanvasPath)
    case text(CanvasText)
    case image(CanvasImage)
    case clip(CanvasPath)
    case transform(CGAffineTransform)
    case opacity(Double)
    case group(DisplayList)

    static func parse(_ value: JSONValue) throws -> CanvasOp? {
        guard let fields = value.objectValue else {
            throw CanvasError("an op is a JSON object, not \(value.jsonText.prefix(30))")
        }
        if let group = fields["group"]?.arrayValue {
            return .group(DisplayList.parse(group))
        }
        if let paint = fields["fill"] {
            return .fill(try CanvasPaint.parse(paint), try CanvasPath.parse(fields["path"]))
        }
        if let paint = fields["stroke"] {
            return .stroke(try CanvasPaint.parse(paint), try CanvasPath.parse(fields["path"]))
        }
        if let text = fields["text"]?.stringValue {
            return .text(try CanvasText.parse(text: text, fields: fields))
        }
        if let image = fields["image"] {
            return .image(try CanvasImage.parse(image: image, fields: fields))
        }
        if let clip = fields["clip"] {
            return .clip(try CanvasPath.parse(clip))
        }
        if let opacity = fields["opacity"]?.doubleValue {
            return .opacity(opacity)
        }
        if fields["transform"] != nil || fields["translate"] != nil
            || fields["rotate"] != nil || fields["scale"] != nil {
            return .transform(try CanvasOp.transform(fields))
        }
        throw CanvasError("no op in \(value.jsonText.prefix(40)); expected fill, stroke, text, "
                          + "image, clip, transform, opacity or group")
    }

    private static func transform(_ fields: [String: JSONValue]) throws -> CGAffineTransform {
        if let matrix = fields["transform"]?.arrayValue {
            let numbers = matrix.compactMap(\.doubleValue)
            guard numbers.count == 6 else {
                throw CanvasError("a transform matrix is six numbers [a b c d tx ty]")
            }
            return CGAffineTransform(a: numbers[0], b: numbers[1], c: numbers[2],
                                     d: numbers[3], tx: numbers[4], ty: numbers[5])
        }
        var transform = CGAffineTransform.identity
        if let translate = fields["translate"]?.arrayValue, translate.count == 2 {
            transform = transform.translatedBy(x: translate[0].doubleValue ?? 0,
                                               y: translate[1].doubleValue ?? 0)
        }
        if let rotate = fields["rotate"]?.doubleValue {
            transform = transform.rotated(by: rotate * .pi / 180)
        }
        if let scale = fields["scale"] {
            if let both = scale.doubleValue {
                transform = transform.scaledBy(x: both, y: both)
            } else if let pair = scale.arrayValue, pair.count == 2 {
                transform = transform.scaledBy(x: pair[0].doubleValue ?? 1, y: pair[1].doubleValue ?? 1)
            }
        }
        return transform
    }
}

/// How a path is painted. A bare string is a colour.
public struct CanvasPaint: Sendable {
    public var color: String = "currentColor"
    public var width: Double?
    public var cap: LineCap?
    public var join: String?
    public var dash: [Double]?

    static func parse(_ value: JSONValue) throws -> CanvasPaint {
        var paint = CanvasPaint()
        if let color = value.stringValue {
            paint.color = color
            return paint
        }
        guard let fields = value.objectValue else {
            throw CanvasError("a paint is a colour string or an object with \"color\"")
        }
        if let color = fields["color"]?.stringValue { paint.color = color }
        paint.width = fields["width"]?.doubleValue
        if let cap = fields["cap"]?.stringValue {
            guard let parsed = LineCap(rawValue: cap) else {
                throw CanvasError("cap is butt, round or square; got '\(cap)'")
            }
            paint.cap = parsed
        }
        paint.join = fields["join"]?.stringValue
        paint.dash = fields["dash"]?.arrayValue?.compactMap(\.doubleValue)
        return paint
    }
}

/// Coordinates are points with the origin at the node's top left, as DESIGN.md §9.1 says.
public struct CanvasPath: Sendable {
    public enum Command: Sendable {
        case move(Double, Double)
        case line(Double, Double)
        case quad(Double, Double, Double, Double)
        case curve(Double, Double, Double, Double, Double, Double)
        /// Centre, radius, and degrees with 0 at three o'clock, increasing clockwise.
        case arc(Double, Double, Double, Double, Double)
        case rect(Double, Double, Double, Double)
        case roundRect(Double, Double, Double, Double, Double)
        case close
    }

    public var commands: [Command]

    static func parse(_ value: JSONValue?) throws -> CanvasPath {
        guard let value else { throw CanvasError("this op needs a \"path\"") }
        // `{"path": {"commands": [...]}}` is accepted as well as the bare array.
        let raw = value.arrayValue ?? value["commands"]?.arrayValue
        guard let raw else { throw CanvasError("a path is an array of commands") }

        var commands: [Command] = []
        for entry in raw {
            guard let parts = entry.arrayValue, let name = parts.first?.stringValue else {
                throw CanvasError("a path command is [\"move\", x, y]-shaped")
            }
            let numbers = parts.dropFirst().compactMap(\.doubleValue)
            func need(_ count: Int) throws -> [Double] {
                guard numbers.count >= count else {
                    throw CanvasError("'\(name)' needs \(count) numbers, got \(numbers.count)")
                }
                return numbers
            }
            switch name {
            case "move": let n = try need(2); commands.append(.move(n[0], n[1]))
            case "line": let n = try need(2); commands.append(.line(n[0], n[1]))
            case "quad": let n = try need(4); commands.append(.quad(n[0], n[1], n[2], n[3]))
            case "curve": let n = try need(6); commands.append(.curve(n[0], n[1], n[2], n[3], n[4], n[5]))
            case "arc": let n = try need(5); commands.append(.arc(n[0], n[1], n[2], n[3], n[4]))
            case "rect": let n = try need(4); commands.append(.rect(n[0], n[1], n[2], n[3]))
            case "round-rect": let n = try need(5); commands.append(.roundRect(n[0], n[1], n[2], n[3], n[4]))
            case "close": commands.append(.close)
            default:
                throw CanvasError("'\(name)' is not a path command; they are move, line, quad, "
                                  + "curve, arc, rect, round-rect and close")
            }
        }
        return CanvasPath(commands: commands)
    }

    public func cgPath() -> CGPath {
        let path = CGMutablePath()
        for command in commands {
            switch command {
            case .move(let x, let y): path.move(to: CGPoint(x: x, y: y))
            case .line(let x, let y): path.addLine(to: CGPoint(x: x, y: y))
            case .quad(let cx, let cy, let x, let y):
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case .curve(let c1x, let c1y, let c2x, let c2y, let x, let y):
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
            case .arc(let cx, let cy, let radius, let from, let to):
                // The CTM is y-down here, so CoreGraphics' "counterclockwise" is what reads as
                // clockwise on screen. Going backwards is the caller writing to < from.
                path.addArc(center: CGPoint(x: cx, y: cy), radius: radius,
                            startAngle: from * .pi / 180, endAngle: to * .pi / 180,
                            clockwise: to < from)
            case .rect(let x, let y, let w, let h):
                path.addRect(CGRect(x: x, y: y, width: w, height: h))
            case .roundRect(let x, let y, let w, let h, let r):
                path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h),
                                    cornerWidth: r, cornerHeight: r)
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

public struct CanvasText: Sendable {
    public var text: String
    public var at: CGPoint
    public var align: Align = .start
    public var valign: String = "middle"
    public var font: String?
    public var color: String?

    static func parse(text: String, fields: [String: JSONValue]) throws -> CanvasText {
        guard let at = fields["at"]?.arrayValue, at.count == 2 else {
            throw CanvasError("a text op needs \"at\": [x, y]")
        }
        var op = CanvasText(text: text,
                            at: CGPoint(x: at[0].doubleValue ?? 0, y: at[1].doubleValue ?? 0))
        if let align = fields["align"]?.stringValue {
            switch align {
            case "start", "left": op.align = .start
            case "center", "middle": op.align = .center
            case "end", "right": op.align = .end
            default: throw CanvasError("text align is start, center or end; got '\(align)'")
            }
        }
        if let valign = fields["valign"]?.stringValue {
            guard ["top", "middle", "bottom", "baseline"].contains(valign) else {
                throw CanvasError("text valign is top, middle, bottom or baseline; got '\(valign)'")
            }
            op.valign = valign
        }
        op.font = fields["font"]?.stringValue
        op.color = fields["color"]?.stringValue
        return op
    }
}

public struct CanvasImage: Sendable {
    public var icon: IconSpec
    public var rect: CGRect

    static func parse(image: JSONValue, fields: [String: JSONValue]) throws -> CanvasImage {
        let icon: IconSpec
        if let name = image.stringValue {
            icon = name.contains("/") || name.hasPrefix("~") ? .file(name) : .symbol(name)
        } else if let file = image["file"]?.stringValue {
            icon = .file(file)
        } else if let symbol = image["symbol"]?.stringValue {
            icon = .symbol(symbol)
        } else {
            throw CanvasError("an image op takes an SF Symbol name or {\"file\": …}")
        }

        if let rect = fields["rect"]?.arrayValue, rect.count == 4 {
            return CanvasImage(icon: icon, rect: CGRect(x: rect[0].doubleValue ?? 0,
                                                        y: rect[1].doubleValue ?? 0,
                                                        width: rect[2].doubleValue ?? 0,
                                                        height: rect[3].doubleValue ?? 0))
        }
        guard let at = fields["at"]?.arrayValue, at.count == 2,
              let size = fields["size"]?.arrayValue, size.count == 2 else {
            throw CanvasError("an image op needs \"rect\": [x, y, w, h], or \"at\" and \"size\"")
        }
        return CanvasImage(icon: icon, rect: CGRect(x: at[0].doubleValue ?? 0,
                                                    y: at[1].doubleValue ?? 0,
                                                    width: size[0].doubleValue ?? 0,
                                                    height: size[1].doubleValue ?? 0))
    }
}
