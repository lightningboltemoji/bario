import AppKit
import CoreImage

/// The probe's photograph, plus whatever blurred and saturated variants the stylesheet asks
/// for. Filtering happens once per capture, never per frame. DESIGN.md §7.
public final class BackdropImage {
    public private(set) var image: CGImage?
    /// Counts new photographs, so a raster that shows the backdrop can key on which one.
    public private(set) var generation = 0
    private var variants: [Key: CGImage] = [:]
    private var luminance: [Key2: Double] = [:]
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private struct Key: Hashable {
        var blur: Double
        var saturate: Double
    }

    private struct Key2: Hashable {
        var x: Int, y: Int, w: Int, h: Int
    }

    public init(image: CGImage? = nil) {
        self.image = image
    }

    /// Returns false for a photograph identical to the last one, which is not new: most are,
    /// since the periodic refresh re-photographs an unchanged desktop, and a change is only
    /// known to be over when a photograph comes back the same.
    @discardableResult
    public func set(_ image: CGImage?) -> Bool {
        guard !BackdropImage.same(self.image, image) else { return false }
        self.image = image
        generation += 1
        variants = [:]
        luminance = [:]
        return true
    }

    static func same(_ a: CGImage?, _ b: CGImage?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if a === b { return true }
        guard a.width == b.width, a.height == b.height, a.bitsPerPixel == b.bitsPerPixel,
              a.bytesPerRow == b.bytesPerRow, a.bitmapInfo == b.bitmapInfo,
              let x = a.dataProvider?.data, let y = b.dataProvider?.data else { return false }
        return CFEqual(x, y)
    }

    public func image(blur: Double?, saturate: Double?) -> CGImage? {
        guard let image else { return nil }
        guard blur != nil || saturate != nil else { return image }
        let key = Key(blur: blur ?? 0, saturate: saturate ?? 1)
        if let cached = variants[key] { return cached }

        var ciImage = CIImage(cgImage: image)
        if let saturate, saturate != 1 {
            let filter = CIFilter(name: "CIColorControls")!
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            filter.setValue(saturate, forKey: kCIInputSaturationKey)
            ciImage = filter.outputImage ?? ciImage
        }
        if let blur, blur > 0 {
            // Clamp first, or the blur eats the edges of the strip.
            let clamped = ciImage.clampedToExtent()
            let filter = CIFilter(name: "CIGaussianBlur")!
            filter.setValue(clamped, forKey: kCIInputImageKey)
            filter.setValue(blur, forKey: kCIInputRadiusKey)
            ciImage = (filter.outputImage ?? ciImage).cropped(to: CIImage(cgImage: image).extent)
        }
        guard let output = context.createCGImage(ciImage, from: CIImage(cgImage: image).extent) else {
            return image
        }
        variants[key] = output
        return output
    }

    /// Mean luminance of the backdrop under a rect in bar coordinates, which is what
    /// `contrast: auto` decides on. Cached, because it is asked once per item per capture.
    public func meanLuminance(in rect: CGRect, barSize: CGSize) -> Double? {
        guard let image, barSize.width > 0, barSize.height > 0 else { return nil }
        let scaleX = Double(image.width) / barSize.width
        let scaleY = Double(image.height) / barSize.height
        // CGImage rows run top-down; bar coordinates run bottom-up.
        let pixel = CGRect(x: rect.minX * scaleX,
                           y: (barSize.height - rect.maxY) * scaleY,
                           width: max(1, rect.width * scaleX),
                           height: max(1, rect.height * scaleY)).integral
        let clipped = pixel.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }

        let key = Key2(x: Int(clipped.minX), y: Int(clipped.minY),
                       w: Int(clipped.width), h: Int(clipped.height))
        if let cached = luminance[key] { return cached }
        guard let cropped = image.cropping(to: clipped) else { return nil }

        // One byte per channel into a tiny context: averaging 1×1 would be cheaper but the
        // shading under the bar is a gradient, and a single sample lies about it.
        let width = min(cropped.width, 16)
        let height = min(cropped.height, 4)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let mean = total / Double(width * height)
        luminance[key] = mean
        return mean
    }
}
