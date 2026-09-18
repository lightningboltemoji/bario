import AppKit
import Testing
@testable import BarioKit

/// The measurement the shadow was fitted to, on macOS 27: a real window moved to a known place
/// and the screen photographed with it there and with it away, the two divided in encoded sRGB —
/// the space a shadow is composited in. Distance from the edge in points, against the shadow's
/// alpha there.
///
/// Taken **over a light background** (a wallpaper at 0.85–0.91), and that is the point rather
/// than an incidental detail. The numbers these replaced were measured over a dark one, where a
/// shadow's tail falls under the 8-bit floor and reads as zero: they had the focused shadow
/// finished by 14pt when it actually carries to 40, which is most of the strip. A sample here
/// that reads 0.000 is a real zero, because at this background a thousandth of alpha is still a
/// quarter of a level.
///
/// Sampled at half-point offsets because that is where a 2× display's pixel centres are. The
/// first quarter-point is left out of every profile: that pixel is the window's own edge, not
/// its shadow.
enum Measured {
    /// Above a window's top edge — the profile that lands in the menu bar.
    static let focusedUp: [(Double, Double)] = [
        (0.75, 0.138), (1.75, 0.113), (2.75, 0.103), (3.75, 0.096), (4.75, 0.088),
        (5.75, 0.081), (7.75, 0.068), (9.75, 0.057), (11.75, 0.046), (13.75, 0.038),
        (15.75, 0.031), (17.75, 0.025), (19.75, 0.020), (21.75, 0.016), (25.75, 0.010),
        (29.75, 0.004), (34.75, 0.001), (39.75, 0.000),
    ]
    static let unfocusedUp: [(Double, Double)] = [
        (0.75, 0.091), (1.75, 0.061), (2.75, 0.049), (3.75, 0.039), (4.75, 0.031),
        (5.75, 0.024), (7.75, 0.014), (9.75, 0.008), (11.75, 0.004), (13.75, 0.000),
        (15.75, 0.000), (17.75, 0.000), (19.75, 0.000), (21.75, 0.000), (25.75, 0.000),
    ]
    /// Beside a window's left edge, where the drop plays no part and so σ stands alone. This is
    /// what makes the fit well posed: the profile above the edge alone cannot separate a wide
    /// shadow that has fallen far from a narrow one that has not.
    static let focusedSide: [(Double, Double)] = [
        (0.75, 0.333), (1.75, 0.319), (2.75, 0.306), (3.75, 0.292), (4.75, 0.279),
        (5.75, 0.265), (7.75, 0.239), (9.75, 0.213), (11.75, 0.190), (13.75, 0.167),
        (15.75, 0.145), (17.75, 0.126), (19.75, 0.109), (21.75, 0.092), (25.75, 0.064),
        (29.75, 0.044), (34.75, 0.026), (39.75, 0.015), (49.75, 0.002),
    ]
    static let unfocusedSide: [(Double, Double)] = [
        (0.75, 0.197), (1.75, 0.175), (2.75, 0.154), (3.75, 0.134), (4.75, 0.115),
        (5.75, 0.098), (7.75, 0.068), (9.75, 0.044), (11.75, 0.027), (13.75, 0.016),
        (15.75, 0.009), (17.75, 0.004), (19.75, 0.001), (21.75, 0.000), (25.75, 0.000),
    ]
}

@Suite("Window shadows")
struct WindowShadowTests {
    /// A caster big enough that a point near one edge is deep inside every other.
    let window = CGRect(x: 0, y: -800, width: 1400, height: 800)

    func field(_ shadow: WindowShadow) -> ShadowField {
        ShadowField(casters: [ShadowCaster(rect: window, cornerRadius: 0, shadow: shadow)])
    }

    @Test("the fitted shadow still matches the screen it was measured from")
    func matchesMeasurement() {
        let focused = field(.focused)
        let unfocused = field(.unfocused)
        let middle = window.midX

        // Above the top edge is what reaches the bar. The numbers this replaced were out by
        // 0.05 through the whole 2…20pt band — three times too light at 8pt — which is what a
        // shadow measured over a dark wallpaper looks like once it is put on a light one.
        for (distance, alpha) in Measured.focusedUp {
            let modelled = focused.alpha(at: CGPoint(x: middle, y: window.maxY + distance))
            #expect(abs(modelled - alpha) < 0.02,
                    "focused \(distance)pt above: \(modelled) against \(alpha)")
        }
        for (distance, alpha) in Measured.unfocusedUp {
            let modelled = unfocused.alpha(at: CGPoint(x: middle, y: window.maxY + distance))
            #expect(abs(modelled - alpha) < 0.02,
                    "unfocused \(distance)pt above: \(modelled) against \(alpha)")
        }
        // Beside the edge the drop contributes nothing, so this is the only place σ is pinned
        // down on its own. One shadow has to satisfy both profiles at once or it is the wrong
        // shape, whatever it does to the one that happens to land in the bar.
        for (distance, alpha) in Measured.focusedSide {
            let modelled = focused.alpha(at: CGPoint(x: window.minX - distance, y: window.midY))
            #expect(abs(modelled - alpha) < 0.02,
                    "focused \(distance)pt beside: \(modelled) against \(alpha)")
        }
        for (distance, alpha) in Measured.unfocusedSide {
            let modelled = unfocused.alpha(at: CGPoint(x: window.minX - distance, y: window.midY))
            #expect(abs(modelled - alpha) < 0.02,
                    "unfocused \(distance)pt beside: \(modelled) against \(alpha)")
        }
    }

    @Test("the shadow is one Gaussian, so the side profile predicts the top one")
    func oneGaussian() {
        // With no drop the two profiles would be identical; the drop is the whole difference
        // between them, and it is a shift rather than a reshaping. Reading the side profile
        // `drop` points further out reproduces the profile above the edge — which is what it
        // means for this to be a single blurred silhouette that has fallen, and what a second
        // lobe would break.
        let focused = field(.focused)
        let drop = WindowShadow.focused.drop
        for distance in stride(from: 0.5, through: 30, by: 0.5) {
            let above = focused.alpha(at: CGPoint(x: window.midX, y: window.maxY + distance))
            let beside = focused.alpha(at: CGPoint(x: window.minX - (distance + drop),
                                                   y: window.midY))
            #expect(abs(above - beside) < 0.002,
                    "at \(distance)pt: above \(above), beside-plus-drop \(beside)")
        }
    }

    @Test("the key window's shadow is the larger one, everywhere it differs")
    func focusMatters() {
        let middle = window.midX
        for distance in stride(from: 1.0, through: 20, by: 1) {
            let point = CGPoint(x: middle, y: window.maxY + distance)
            #expect(field(.focused).alpha(at: point) >= field(.unfocused).alpha(at: point))
        }
        // Far enough up that only the focused window still reaches.
        let far = CGPoint(x: middle, y: window.maxY + 14)
        #expect(field(.focused).alpha(at: far) > 0.01)
        #expect(field(.unfocused).alpha(at: far) < 0.005)
    }

    @Test("alpha falls off monotonically and dies inside the stated reach")
    func falloff() {
        let focused = field(.focused)
        var last = 1.0
        for distance in stride(from: 0.0, through: WindowShadow.focused.reachUp, by: 0.5) {
            let alpha = focused.alpha(at: CGPoint(x: window.midX, y: window.maxY + distance))
            #expect(alpha <= last + 1e-9, "rose again at \(distance)pt")
            last = alpha
        }
        let past = focused.alpha(at: CGPoint(x: window.midX,
                                             y: window.maxY + WindowShadow.focused.reachUp + 1))
        #expect(past < 1.0 / 255)
    }

    @Test("an empty field costs nothing and shades nothing")
    func empty() {
        #expect(ShadowField.empty.isEmpty)
        #expect(ShadowField.empty.alpha(at: .zero) == 0)
        #expect(ShadowField.empty.meanAlpha(in: CGRect(x: 0, y: 0, width: 10, height: 10)) == 0)
    }

    @Test("two windows compound, because both shadows fall on the same desktop")
    func compounding() {
        let one = ShadowCaster(rect: window, cornerRadius: 0, shadow: .unfocused)
        let two = ShadowCaster(rect: window.offsetBy(dx: 40, dy: 0), cornerRadius: 0,
                               shadow: .unfocused)
        let point = CGPoint(x: window.midX + 20, y: window.maxY + 2)
        let single = ShadowField(casters: [one]).alpha(at: point)
        let both = ShadowField(casters: [one, two]).alpha(at: point)
        #expect(both > single)
        // Source-over, not addition: it can never reach opaque.
        #expect(both < 1)
        #expect(abs(both - (1 - pow(1 - single, 2))) < 1e-9)
    }

    @Test("mean alpha over a rect sits between its corners")
    func meanAlpha() {
        let focused = field(.focused)
        let rect = CGRect(x: 100, y: 2, width: 60, height: 10)
        let mean = focused.meanAlpha(in: rect)
        let top = focused.alpha(at: CGPoint(x: rect.midX, y: rect.maxY))
        let bottom = focused.alpha(at: CGPoint(x: rect.midX, y: rect.minY))
        #expect(mean > top && mean < bottom)
    }
}

@Suite("Surveying the windows behind a bar")
struct WindowSurveyTests {
    let display = DisplayInfo(displayID: 1, name: "T",
                              frame: CGRect(x: 0, y: 0, width: 1400, height: 900),
                              scale: 2, stripHeight: 34)

    func window(_ id: CGWindowID, top: CGFloat, pid: pid_t = 1) -> SurveyedWindow {
        // `top` is how far below the bar's bottom edge the window's top edge sits.
        let barBottom = display.frame.maxY - display.stripHeight
        return SurveyedWindow(id: id,
                              frame: CGRect(x: 100, y: barBottom - top - 500,
                                            width: 800, height: 500),
                              pid: pid)
    }

    @Test("a window's rectangle arrives in bar coordinates, below the origin")
    func coordinates() throws {
        let field = WindowSurvey.field(for: display, windows: [window(1, top: 20)], focused: 1)
        let caster = try #require(field.casters.first)
        #expect(caster.rect.maxY == -20)
        #expect(caster.rect.minX == 100)
        #expect(caster.rect.width == 800)
    }

    @Test("only the frontmost window of the frontmost app is the key one")
    func focus() {
        let windows = [window(1, top: 10, pid: 7), window(2, top: 10, pid: 7),
                       window(3, top: 10, pid: 9)]
        #expect(WindowSurvey.focusedWindow(in: windows, frontmost: 7) == 1)
        #expect(WindowSurvey.focusedWindow(in: windows, frontmost: 9) == 3)
        #expect(WindowSurvey.focusedWindow(in: windows, frontmost: nil) == nil)

        let field = WindowSurvey.field(for: display, windows: windows, focused: 1)
        #expect(field.casters[0].shadow == .focused)
        #expect(field.casters[1].shadow == .unfocused)
    }

    @Test("a window too far below the bar to reach it is left out")
    func culling() {
        let near = WindowSurvey.field(for: display, windows: [window(1, top: 30)], focused: 1)
        #expect(near.casters.count == 1)
        // Past the focused shadow's upward reach, which is the furthest any window carries.
        let far = WindowSurvey.field(for: display,
                                     windows: [window(1, top: WindowShadow.focused.reachUp + 5)],
                                     focused: 1)
        #expect(far.isEmpty)
        // And it is the focused reach, not the smaller one, that decides.
        let between = WindowSurvey.field(
            for: display, windows: [window(1, top: WindowShadow.unfocused.reachUp + 5)],
            focused: 1)
        #expect(between.casters.count == 1)
    }

    @Test("a window on another display casts nothing here")
    func otherDisplay() {
        let far = SurveyedWindow(id: 1, frame: CGRect(x: 4000, y: 500, width: 600, height: 400),
                                 pid: 1)
        #expect(WindowSurvey.field(for: display, windows: [far], focused: nil).isEmpty)
    }

    @Test("the watcher only reports a field that actually moved")
    @MainActor
    func watcherDeduplicates() {
        let watcher = ShadowWatcher()
        var reported: [ShadowField] = []
        var windows = [window(1, top: 20)]
        watcher.survey = { _, _ in windows }
        watcher.frontmost = { 1 }
        watcher.primaryMaxY = { 900 }
        watcher.onChange = { _, field in reported.append(field) }
        watcher.displays = [display]

        #expect(watcher.sample())
        #expect(reported.count == 1)
        // The same windows again is not news.
        #expect(!watcher.sample())
        #expect(reported.count == 1)
        // Moved, and it is.
        windows = [window(1, top: 10)]
        #expect(watcher.sample())
        #expect(reported.count == 2)
        watcher.stop()
    }
}

@Suite("Shadows on the bar")
@MainActor
struct ShadowPixelTests {
    let size = CGSize(width: 200, height: 24)

    /// A bar whose background is the backdrop — the invisible bar the seam shows up on — over a
    /// flat mid-grey, with one full-width window `gap` points below it.
    func bar(gap: Double, focused: Bool = true, background: String = "backdrop") throws
        -> (image: CGImage, field: ShadowField) {
        let config = try ConfigLoader.parse(#"bar { }"#)
        let sheet = try Stylesheet.parse("bar { padding: 0; background: \(background) }")
        let display = DisplayInfo(displayID: 1, name: "T",
                                  frame: CGRect(x: 0, y: 0, width: size.width, height: 900),
                                  scale: 2, stripHeight: size.height)
        let builder = SceneBuilder(cascade: Cascade(stylesheet: sheet, dark: false),
                                   metrics: CoreTextMetrics())
        let scene = builder.build(bar: config.bars[0], display: display,
                                  items: config.bars[0].items, states: [:])

        let backdrop = BackdropImage()
        backdrop.set(ShadowPixelTests.flat(gray: 0.5, width: 400, height: 48))
        let window = CGRect(x: -100, y: -gap - 400, width: size.width + 200, height: 400)
        let field = ShadowField(casters: [ShadowCaster(rect: window, cornerRadius: 0,
                                                       shadow: .of(focused: focused))])
        guard let image = Offscreen.render(scene, backdrop: backdrop, shadows: field,
                                           resolver: ColorResolver(dark: false), scale: 2) else {
            throw ModuleError("render failed")
        }
        return (image, field)
    }

    static func flat(gray: Double, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Named in sRGB, the space the renderer composites in, so the pixel that comes back
        // really is `gray` and an alpha read off it is the shadow's and nothing else.
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    func pixel(_ image: CGImage, _ x: Double, _ y: Double) -> Offscreen.Pixel {
        Offscreen.pixel(image, atPoint: CGPoint(x: x, y: y), size: size)
            ?? Offscreen.Pixel(r: 0, g: 0, b: 0, a: 0)
    }

    /// What Core Animation drew, as an alpha over the known backdrop. Not clamped: a reading
    /// that comes back negative is a backdrop that is not the grey it was asked for, and that
    /// should fail the test rather than quietly read as no shadow at all.
    func drawnAlpha(_ image: CGImage, at y: Double) -> Double {
        1 - Double(pixel(image, size.width / 2, y).r) / 0.5
    }

    @Test("what the layers draw is what the sampler says, which is what contrast reads")
    func layersMatchTheSampler() throws {
        let (image, field) = try bar(gap: 8)
        for y in stride(from: 0.5, through: 12, by: 0.5) {
            let drawn = drawnAlpha(image, at: y)
            let modelled = field.alpha(at: CGPoint(x: size.width / 2, y: y))
            #expect(abs(drawn - modelled) < 0.02,
                    "at \(y)pt: drew \(drawn), sampler says \(modelled)")
        }
    }

    @Test("the shadow is darkest at the bar's bottom edge and fades upward")
    func gradient() throws {
        let (image, _) = try bar(gap: 8)
        let bottom = drawnAlpha(image, at: 0.5)
        let middle = drawnAlpha(image, at: 8)
        let top = drawnAlpha(image, at: 22)
        #expect(bottom > middle)
        #expect(middle > top)
        // A focused window 8pt down darkens the bar's bottom edge by about a fiftieth, and a
        // window right under it by a seventh. Small at this distance, and still the difference
        // between a gradient that carries on across the edge and one that stops dead at it.
        #expect(bottom > 0.015)
        #expect(try drawnAlpha(bar(gap: 0).image, at: 0.5) > 0.10)
    }

    @Test("the value at the bar's bottom edge continues the one just below it")
    func continuousAcrossTheEdge() throws {
        // The seam is a step at the bar's bottom edge, so the test is that there is no step:
        // half a point above the edge and half a point below differ by almost nothing.
        let (_, field) = try bar(gap: 8)
        let above = field.alpha(at: CGPoint(x: size.width / 2, y: 0.5))
        let below = field.alpha(at: CGPoint(x: size.width / 2, y: -0.5))
        #expect(abs(above - below) < 0.01)
    }

    @Test("a window further away casts less into the bar")
    func distance() throws {
        let near = drawnAlpha(try bar(gap: 2).image, at: 1)
        let far = drawnAlpha(try bar(gap: 30).image, at: 1)
        #expect(near > far)
        #expect(far < 0.02)
    }

    @Test("an unfocused window casts less than the key one")
    func focus() throws {
        let key = drawnAlpha(try bar(gap: 8, focused: true).image, at: 1)
        let other = drawnAlpha(try bar(gap: 8, focused: false).image, at: 1)
        #expect(key > other)
    }

    @Test("a bar painted a colour shows no window shadow, having no desktop to shade")
    func opaqueBarIsUntouched() throws {
        let (image, _) = try bar(gap: 4, background: "rgb(128, 128, 128)")
        for y in stride(from: 0.5, through: 12, by: 1) {
            #expect(abs(drawnAlpha(image, at: y)) < 0.02, "shaded an opaque bar at \(y)pt")
        }
    }
}
