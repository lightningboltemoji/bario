import AppKit
import CBarioShim

/// Finished pixels from a module: the expensive escape hatch, and opt-in for that reason.
/// DESIGN.md §9.3. The host says the size in points; the module returns premultiplied BGRA,
/// or names an image bario can decode.
public final class RasterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: CGImage] = [:]

    public init() {}

    /// `instance` is only needed for a `{ptr, len}` source, which points into WASM memory.
    public func image(for source: JSONValue, width: Double, height: Double,
                      instance: (any WasmInstance)? = nil) -> CGImage? {
        // A memory source changes every frame by definition, so it is never cached.
        if let ptr = source["ptr"]?.intValue, let len = source["len"]?.intValue {
            guard let instance,
                  let bytes = try? instance.read(ptr: Int32(ptr), len: Int32(len)) else { return nil }
            return RasterCache.bgra(bytes, width: Int(width), height: Int(height))
        }
        if let name = source["shm"]?.stringValue {
            return RasterCache.sharedMemory(name: name, width: Int(width), height: Int(height))
        }

        let key = source.jsonText
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        var image: CGImage?
        if let base64 = source["png"]?.stringValue, let data = Data(base64Encoded: base64) {
            image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else if let path = source["path"]?.stringValue ?? source.stringValue {
            image = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let image else { return nil }
        lock.lock()
        cache[key] = image
        if cache.count > 64 { cache.removeAll(keepingCapacity: true) }
        lock.unlock()
        return image
    }

    public func clear() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    /// Premultiplied BGRA, which is what a module drawing with Metal or its own rasterizer
    /// already has.
    static func bgra(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, bytes.count >= width * height * 4 else { return nil }
        let data = Data(bytes.prefix(width * height * 4))
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue:
                        CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// A buffer another process opened with `shm_open` and reuses frame to frame.
    static func sharedMemory(name: String, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let size = width * height * 4
        let fd = name.withCString { bario_shm_open_readonly($0) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let mapped = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0),
              mapped != MAP_FAILED else { return nil }
        defer { munmap(mapped, size) }
        let bytes = [UInt8](UnsafeRawBufferPointer(start: mapped, count: size))
        return bgra(bytes, width: width, height: height)
    }
}
