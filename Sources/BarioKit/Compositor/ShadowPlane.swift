import QuartzCore

/// The window shadows that fall on the desktop a bar is showing, as layers.
///
/// One layer per caster, with a `shadowPath` and no contents — which is how `Chrome` draws a
/// bubble's shadow too. Core Animation blurs it on the GPU, so a window being dragged costs a
/// `position` and a path per frame and nothing else: no raster, no capture, and nothing keyed on
/// the backdrop is invalidated.
///
/// The plane hangs under whatever is showing the backdrop and is clipped by it, so a shadow
/// only darkens desktop that is actually visible. Its layers take a caster's rectangle as it
/// is, because bar coordinates go all the way down (PLAN.md D2) and that is the space a caster
/// is already in.
@MainActor
final class ShadowPlane {
    private(set) var layers: [CALayer] = []

    /// Bring the plane up to `field`, reusing the layers it has. A caster keeps its place in the
    /// list, so a window that moves updates one layer rather than replacing it.
    func apply(_ field: ShadowField, factory: inout LayerFactory) {
        while layers.count > field.casters.count {
            layers.removeLast().removeFromSuperlayer()
        }
        while layers.count < field.casters.count {
            layers.append(factory.make())
        }
        for (index, caster) in field.casters.enumerated() {
            let layer = layers[index]
            let shadow = caster.shadow
            // The layer is sized to the shadow, not to the window, and the path stays on the
            // window. Core Animation culls a layer whose *bounds* miss the clip, growing them
            // by `shadowRadius` and the offset and no further — which is one σ, where the
            // shadow is still visible out to three. A caster sits entirely below the bar, so
            // culled by that estimate is exactly what every one of them would be. Bounds carry
            // their origin (PLAN.md D2), so growing them leaves bar coordinates alone and the
            // path lands where it did.
            let spread = shadow.reach + abs(shadow.drop) + 1
            layer.place(caster.rect.insetBy(dx: -spread, dy: -spread))
            let path = RoundedRect.path(in: caster.rect, corners: Corners(caster.cornerRadius))
            if layer.shadowPath != path { layer.shadowPath = path }
            if layer.shadowColor != ShadowPlane.ink { layer.shadowColor = ShadowPlane.ink }
            assign(layer, \.shadowOpacity, Float(shadow.opacity))
            assign(layer, \.shadowRadius, shadow.sigma)
            // A layer's offset is y-up, and a drop is down.
            assign(layer, \.shadowOffset, CGSize(width: 0, height: -shadow.drop))
        }
    }

    /// macOS's window shadow is black at an opacity; the shadow carries the alpha.
    private static let ink = CGColor(gray: 0, alpha: 1)
}
