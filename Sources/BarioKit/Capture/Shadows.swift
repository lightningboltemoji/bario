import CoreGraphics
import Foundation

/// The shadow macOS casts around a window, as the numbers Core Animation takes for one.
///
/// **One Gaussian, not two.** Measured on macOS 27: a window was moved to a known place and the
/// screen photographed with it there and with it away, and the two divided, which leaves the
/// shadow's alpha and nothing else. A single blurred, dropped silhouette fits the result to an
/// rms of 0.0013 over 395 samples, taken both above a window's top edge — the profile that
/// reaches the bar — and beside it, where the drop plays no part and so `sigma` stands alone.
/// An optimiser given room for a second lobe spends it on a σ 0.3 sliver at the very edge,
/// which is the window's own antialiasing rather than any part of its shadow.
///
/// This replaced a two-lobe fit, and the reason that fit existed is worth keeping: it was
/// measured over a **dark** wallpaper. A shadow's tail there falls under the 8-bit floor — over
/// a 0.05 background an alpha of 0.09 moves the pixel by a single level — so the tail read as
/// zero, the fit chased a decay that was far too fast, and a second tight lobe was needed to
/// carry the near-edge ink the first one had given up. Over a light wallpaper that same tail is
/// thirteen levels and plainly visible, which is why the bar looked right on one desktop and
/// wrong on the next. **Measure shadows over a light background**; a dark one cannot hold them.
///
/// **Divided in encoded sRGB, not in linear light**, because that is the space a layer's shadow
/// is composited in, and that is checked rather than assumed: the same shadow was recovered over
/// backgrounds from 0.45 to 0.99 and the encoded alpha held at 0.0436…0.0441 while the
/// linearised one drifted from 0.0907 to 0.0973. A model fitted in the space that stays put is a
/// model that does not care what the wallpaper is.
///
/// **There are two shadows**, because macOS draws two, and the key window's is not a tweak
/// apart: σ 19.5 against σ 7.6, and it reaches about 40pt where the other stops at 14. Which
/// window is focused changes the strip more than a window moving does.
public struct WindowShadow: Sendable, Hashable {
    /// Peak alpha under the silhouette — `CALayer.shadowOpacity`.
    public var opacity: Double
    /// σ of the Gaussian, in points, which is exactly what `CALayer.shadowRadius` is.
    public var sigma: Double
    /// How far the silhouette falls before it is blurred. Down is positive; the layer property
    /// is y-up and negates it.
    public var drop: Double

    public init(opacity: Double, sigma: Double, drop: Double) {
        self.opacity = opacity
        self.sigma = sigma
        self.drop = drop
    }

    public static let focused = WindowShadow(opacity: 0.693, sigma: 19.46, drop: 17.31)
    public static let unfocused = WindowShadow(opacity: 0.436, sigma: 7.57, drop: 6.23)

    /// The one macOS would draw for a window in this state — the only way either constant is
    /// chosen.
    public static func of(focused: Bool) -> WindowShadow { focused ? .focused : .unfocused }

    /// Three σ, where a Gaussian's tail ends: past it the shadow is under a level of 8-bit
    /// grey even at the focused opacity, so nothing is lost by stopping there.
    var reach: Double { sigma * 3 }

    /// How far past the silhouette the shadow reaches, in points. The drop moves it down, so it
    /// reaches further below a window than above it. What culling has to leave room for.
    public var reachUp: Double { max(0, reach - drop) }
    public var reachDown: Double { reach + drop }
    public var reachSide: Double { reach }
}

/// A window that casts into a bar: its silhouette in the bar's coordinates, and the shadow it
/// casts. Bar coordinates all the way down (PLAN.md D2), so a caster's rectangle is already in
/// the space the layers live in — the origin is the bar's bottom left and y runs up, which puts
/// every ordinary window at a negative `y`.
public struct ShadowCaster: Sendable, Hashable {
    public var rect: CGRect
    public var cornerRadius: Double
    public var shadow: WindowShadow

    public init(rect: CGRect, cornerRadius: Double = ShadowCaster.windowCorner,
                shadow: WindowShadow) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    /// macOS 27's window corner, measured off the same capture the shadow was fitted to: the
    /// curve leaves the top edge about 12pt in. It is a continuous curve rather than an arc,
    /// but the shadow blurs it at σ 19 and it only moves things within a corner's width of a
    /// window's ends, so a plain rounded rectangle stands in for it.
    public static let windowCorner = 12.0
}

/// The shadows the windows behind a bar cast into it.
///
/// bario's cover is opaque over a strip the system draws as transparent, so everything the
/// window server puts there from below is erased, and a window shadow is the common case. It
/// cannot be photographed back either: ScreenCaptureKit renders no window shadows at all in a
/// display filter, whatever `capturesShadowsOnly` and `ignoreShadowsDisplay` are set to — the
/// capture is byte-identical with a window near the top and with it away, which is checked
/// against the real screen and not merely believed. So the bar casts them itself, and this is
/// what it casts. DESIGN.md §7.
public struct ShadowField: Sendable, Hashable {
    public var casters: [ShadowCaster]

    public static let empty = ShadowField()

    public init(casters: [ShadowCaster] = []) { self.casters = casters }

    public var isEmpty: Bool { casters.isEmpty }

    /// The alpha the casters put at a point in bar coordinates.
    ///
    /// Analytic rather than read back from pixels, because the same number has to reach
    /// `contrast: auto` — which runs before anything is drawn — and because a field that
    /// tracks a window being dragged must not cost a raster per frame.
    public func alpha(at point: CGPoint) -> Double {
        guard !casters.isEmpty else { return 0 }
        var clear = 1.0
        for caster in casters {
            let coverage = ShadowField.coverage(of: caster.rect, at: point, shadow: caster.shadow)
            guard coverage > 0 else { continue }
            clear *= 1 - caster.shadow.opacity * coverage
        }
        return 1 - clear
    }

    /// Mean alpha over a rect in bar coordinates: what `contrast: auto` dims the backdrop's
    /// luminance by before it picks an ink. Sampled on a grid, like the luminance it corrects,
    /// because the shading under a bar is a gradient and one sample lies about it.
    public func meanAlpha(in rect: CGRect) -> Double {
        guard !casters.isEmpty, rect.width > 0, rect.height > 0 else { return 0 }
        let columns = 16, rows = 4
        var total = 0.0
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(
                    x: rect.minX + rect.width * (Double(column) + 0.5) / Double(columns),
                    y: rect.minY + rect.height * (Double(row) + 0.5) / Double(rows))
                total += alpha(at: point)
            }
        }
        return total / Double(columns * rows)
    }

    /// How much of the blurred silhouette covers a point.
    ///
    /// A Gaussian blur is separable and a rectangle is the product of two intervals, so a
    /// blurred rectangle is exactly the product of two blurred steps. That is also what Core
    /// Animation draws, corners aside, so the sampler and the layers agree by construction
    /// rather than by being tuned against each other.
    private static func coverage(of rect: CGRect, at point: CGPoint,
                                 shadow: WindowShadow) -> Double {
        let sigma = max(shadow.sigma, 0.001)
        let across = phi((point.x - rect.minX) / sigma) - phi((point.x - rect.maxX) / sigma)
        guard across > 0 else { return 0 }
        // The silhouette falls by `drop`, which is the same as sampling it that much higher.
        let y = point.y + shadow.drop
        let along = phi((y - rect.minY) / sigma) - phi((y - rect.maxY) / sigma)
        return max(0, across * along)
    }

    /// The standard normal's cumulative distribution.
    static func phi(_ z: Double) -> Double { 0.5 * erfc(-z / 2.0.squareRoot()) }
}
