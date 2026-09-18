import AppKit
import Metal

/// Renders a bar to a bitmap with no window and no menu bar in sight: the same layer tree the
/// screen shows, composited by `CARenderer` into a Metal texture. This is how the compositor
/// is verified in a session that cannot look at a screen, and it makes a visual regression a
/// diff of two files. DESIGN.md §10, PLAN.md D13.
@MainActor
public enum Offscreen {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    /// Where offscreen time starts. Any fixed value will do: animations added offscreen begin
    /// at it, so a shot is the same every time it is taken.
    static let epoch: CFTimeInterval = 1_000

    /// Renders in sRGB, so a test can compare the colours it wrote. `time` is how far into its
    /// animations the bar is shown: 0, the default, shows each at its start.
    public static func render(_ scene: Scene, backdrop: BackdropImage,
                              shadows: ShadowField = .empty, resolver: ColorResolver,
                              hole: Hole = Hole(), reveal: Double = 0, scale: CGFloat = 2,
                              at time: CFTimeInterval = 0, renderers: RendererHost? = nil,
                              rasters: RasterCache = RasterCache(),
                              surfaces: SharedSurfaces? = nil) -> CGImage? {
        render(size: scene.bounds.size, scale: scale, at: time) { host in
            let compositor = Compositor(host: host)
            compositor.commit(Presentation(scene: scene, hole: hole, reveal: reveal),
                              inputs: Compositor.Inputs(backdrop: backdrop, shadows: shadows,
                                                        resolver: resolver,
                                                        scale: scale, animationTime: epoch,
                                                        renderers: renderers, rasters: rasters,
                                                        surfaces: surfaces),
                              sceneChanged: true)
        }
    }

    /// Composites whatever `build` hangs from the host layer, which is `size` points at
    /// `scale`.
    static func render(size: CGSize, scale: CGFloat, at time: CFTimeInterval,
                       build: (CALayer) -> Void) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let device, let queue else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // CARenderer composites over whatever the texture already holds.
        let region = MTLRegionMake2D(0, 0, width, height)
        let rowBytes = width * 4
        texture.replace(region: region, mipmapLevel: 0,
                        withBytes: [UInt8](repeating: 0, count: rowBytes * height),
                        bytesPerRow: rowBytes)

        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            kCARendererMetalCommandQueue: queue,
        ])
        let host = CALayer()
        host.delegate = InertLayerDelegate.shared
        host.anchorPoint = .zero
        host.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        host.position = .zero
        host.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
        // The tree has to be the renderer's before it is committed, or its animations are
        // dropped rather than run.
        renderer.layer = host
        renderer.bounds = host.bounds
        build(host)
        CATransaction.flush()

        renderer.beginFrame(atTime: epoch + time, timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        guard let buffer = queue.makeCommandBuffer() else { return nil }
        buffer.commit()
        buffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
        // The texture's first row is the bottom of the bar; an image's is the top.
        var rows = [UInt8](repeating: 0, count: bytes.count)
        for row in 0..<height {
            let source = (height - 1 - row) * rowBytes
            rows.replaceSubrange(row * rowBytes..<(row + 1) * rowBytes,
                                 with: bytes[source..<source + rowBytes])
        }
        guard let provider = CGDataProvider(data: Data(rows) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// One pixel of a rendered image, for tests and for eyeballing a colour.
    public struct Pixel: Sendable, Hashable, CustomStringConvertible {
        public var r: Double, g: Double, b: Double, a: Double
        public var description: String {
            String(format: "rgba(%.3f, %.3f, %.3f, %.3f)", r, g, b, a)
        }

        public func isClose(to other: Pixel, tolerance: Double = 0.02) -> Bool {
            abs(r - other.r) < tolerance && abs(g - other.g) < tolerance
                && abs(b - other.b) < tolerance && abs(a - other.a) < tolerance
        }
    }

    /// Reads a pixel in *point* coordinates with a bottom-left origin, the same space the
    /// scene's frames are in.
    public nonisolated static func pixel(_ image: CGImage, atPoint point: CGPoint, size: CGSize) -> Pixel? {
        let scaleX = Double(image.width) / size.width
        let scaleY = Double(image.height) / size.height
        let x = Int(point.x * scaleX)
        let y = Int((size.height - point.y) * scaleY)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }

        var pixels = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixels, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y),
                                   width: image.width, height: image.height))
        let a = Double(pixels[3]) / 255
        guard a > 0 else { return Pixel(r: 0, g: 0, b: 0, a: 0) }
        // Undo the premultiplication so the assertions can name the colour they wrote.
        return Pixel(r: Double(pixels[0]) / 255 / a,
                     g: Double(pixels[1]) / 255 / a,
                     b: Double(pixels[2]) / 255 / a,
                     a: a)
    }
}
