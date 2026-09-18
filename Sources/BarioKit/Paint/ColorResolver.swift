import AppKit

/// Turns the cascade's symbolic colours into pixels. Kept out of the cascade so that
/// `currentColor` can mean what it says inside a renderer's display list, and so a `system()`
/// colour follows the appearance without re-parsing anything. DESIGN.md §7.
public struct ColorResolver: Sendable {
    public var dark: Bool
    public var accent: RGBA
    /// What `currentColor` means here: the style's resolved `color`.
    public var current: RGBA

    public init(dark: Bool = false,
                accent: RGBA = RGBA(r: 0, g: 0.48, b: 1),
                current: RGBA = RGBA(r: 0, g: 0, b: 0)) {
        self.dark = dark
        self.accent = accent
        self.current = current
    }

    @MainActor
    public static func system(dark: Bool) -> ColorResolver {
        ColorResolver(dark: dark, accent: RGBA(NSColor.controlAccentColor))
    }

    public func with(current: RGBA) -> ColorResolver {
        var copy = self
        copy.current = current
        return copy
    }

    public func resolve(_ color: Color) -> RGBA {
        switch color {
        case .rgba(let rgba): return rgba
        case .none: return RGBA(r: 0, g: 0, b: 0, a: 0)
        case .accent: return accent
        case .current: return current
        case .system(let name): return ColorResolver.named(name, dark: dark)
        case .mix(let a, let b, let t):
            let x = resolve(a), y = resolve(b)
            return RGBA(r: lerp(x.r, y.r, t), g: lerp(x.g, y.g, t),
                        b: lerp(x.b, y.b, t), a: lerp(x.a, y.a, t))
        }
    }

    public func cgColor(_ color: Color) -> CGColor { resolve(color).cgColor }

    /// Any `NSColor` class property by name, resolved in the right appearance.
    static func named(_ name: String, dark: Bool) -> RGBA {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var color: NSColor?
        let selector = NSSelectorFromString(name)
        if NSColor.responds(to: selector) {
            color = NSColor.perform(selector)?.takeUnretainedValue() as? NSColor
        }
        guard let color else {
            // A name that is not an NSColor is a visible mistake, not an invisible one.
            return RGBA(r: 1, g: 0, b: 1, a: 1)
        }
        var out = RGBA(r: 0, g: 0, b: 0)
        if let appearance {
            appearance.performAsCurrentDrawingAppearance { out = RGBA(color) }
        } else {
            out = RGBA(color)
        }
        return out
    }
}
