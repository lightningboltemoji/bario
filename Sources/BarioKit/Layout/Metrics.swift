import AppKit
import CoreText

/// Everything layout needs to know about how big things draw. Injectable so the layout tests
/// can assert exact numbers without the machine's fonts deciding the answer.
public protocol Metrics: Sendable {
    func textSize(_ text: String, style: Style) -> CGSize
    func iconSize(_ icon: IconSpec, style: Style) -> CGSize
    func lineHeight(_ style: Style) -> Double
}

/// The real one: CoreText for text, SF Symbols for icons, both cached because a clock
/// re-measures the same six glyphs every minute.
public final class CoreTextMetrics: Metrics, @unchecked Sendable {
    private let lock = NSLock()
    private var textCache: [TextKey: CGSize] = [:]
    private var iconCache: [IconKey: CGSize] = [:]

    private struct TextKey: Hashable {
        var text: String
        var font: FontSpec
        var letterSpacing: Double
        var transform: TextTransform
    }

    private struct IconKey: Hashable {
        var name: String
        var isFile: Bool
        var size: Double
        var weight: Double
    }

    public init() {}

    public func textSize(_ text: String, style: Style) -> CGSize {
        let key = TextKey(text: text, font: style.font, letterSpacing: style.letterSpacing,
                          transform: style.textTransform)
        lock.lock()
        if let cached = textCache[key] { lock.unlock(); return cached }
        lock.unlock()

        let transformed = style.textTransform.apply(to: text)
        let font = CoreTextMetrics.font(for: style.font)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if style.letterSpacing != 0 { attributes[.kern] = style.letterSpacing }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: transformed, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let size = CGSize(width: ceil(width), height: ceil(ascent + descent))

        lock.lock()
        textCache[key] = size
        if textCache.count > 4096 { textCache.removeAll(keepingCapacity: true) }
        lock.unlock()
        return size
    }

    public func iconSize(_ icon: IconSpec, style: Style) -> CGSize {
        let key = IconKey(name: icon.name, isFile: icon.isFile,
                          size: style.effectiveIconSize, weight: style.effectiveIconWeight)
        lock.lock()
        if let cached = iconCache[key] { lock.unlock(); return cached }
        lock.unlock()

        let point = style.effectiveIconSize
        var size = CGSize(width: point, height: point)
        if let image = CoreTextMetrics.image(for: icon, style: style) {
            let natural = image.size
            if natural.height > 0 {
                size = CGSize(width: ceil(natural.width * point / natural.height), height: point)
            }
        }

        lock.lock()
        iconCache[key] = size
        lock.unlock()
        return size
    }

    public func lineHeight(_ style: Style) -> Double {
        let font = CoreTextMetrics.font(for: style.font)
        return ceil(font.ascender - font.descender)
    }

    /// SF Symbols are the reason to be on macOS: rendered at the current font size, weight
    /// and colour. DESIGN.md §2.
    public static func image(for icon: IconSpec, style: Style) -> NSImage? {
        switch icon {
        case .symbol(let name):
            let weight = NSFont.Weight(styleWeight: style.effectiveIconWeight)
            let configuration = NSImage.SymbolConfiguration(pointSize: style.effectiveIconSize,
                                                            weight: weight)
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        case .file(let path):
            return NSImage(contentsOfFile: (path as NSString).expandingTildeInPath)
        }
    }

    public static func font(for spec: FontSpec) -> NSFont {
        let weight = NSFont.Weight(styleWeight: spec.weight)
        switch spec.family {
        case .system, .systemUI:
            return NSFont.systemFont(ofSize: spec.size, weight: weight)
        case .monospace:
            return NSFont.monospacedSystemFont(ofSize: spec.size, weight: weight)
        case .named(let name):
            if let font = NSFont(name: name, size: spec.size) { return font }
            return NSFont.systemFont(ofSize: spec.size, weight: weight)
        }
    }
}

extension NSFont.Weight {
    init(styleWeight: Double) {
        switch styleWeight {
        case ..<150: self = .ultraLight
        case ..<250: self = .thin
        case ..<350: self = .light
        case ..<450: self = .regular
        case ..<550: self = .medium
        case ..<650: self = .semibold
        case ..<750: self = .bold
        case ..<850: self = .heavy
        default: self = .black
        }
    }
}

extension IconSpec {
    var isFile: Bool { if case .file = self { return true } else { return false } }
}

extension TextTransform {
    public func apply(to text: String) -> String {
        switch self {
        case .none: return text
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .capitalize: return text.capitalized
        }
    }
}

/// Deterministic metrics for tests: every character is half the font size wide.
public struct FixedMetrics: Metrics {
    public var characterWidth: Double
    public var height: Double

    public init(characterWidth: Double = 0.5, height: Double = 14) {
        self.characterWidth = characterWidth
        self.height = height
    }

    public func textSize(_ text: String, style: Style) -> CGSize {
        let transformed = style.textTransform.apply(to: text)
        let width = Double(transformed.count) * style.font.size * characterWidth
            + Double(max(0, transformed.count - 1)) * style.letterSpacing
        return CGSize(width: width, height: height)
    }

    public func iconSize(_ icon: IconSpec, style: Style) -> CGSize {
        CGSize(width: style.effectiveIconSize, height: style.effectiveIconSize)
    }

    public func lineHeight(_ style: Style) -> Double { height }
}
