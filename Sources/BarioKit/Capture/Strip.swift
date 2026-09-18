import AppKit
import ScreenCaptureKit

public enum SourceMode: String, Sendable {
    /// Try a real screen capture of the desktop, fall back to rendering the wallpaper file.
    case auto
    /// Only use ScreenCaptureKit (exact, needs Screen Recording permission).
    case capture
    /// Only render the wallpaper image file (no permission needed, approximate).
    case wallpaper
}

public struct StripImage {
    public let image: CGImage
    /// Human readable description of where the pixels came from.
    public let source: String
}

public enum StripError: Error, CustomStringConvertible {
    case noSharableDisplay(CGDirectDisplayID)
    case cropFailed
    case message(String)

    public var description: String {
        switch self {
        case .noSharableDisplay(let id): return "display \(id) is not shareable"
        case .cropFailed: return "could not crop the capture to the menu bar strip"
        case .message(let m): return m
        }
    }
}

/// CGImage isn't Sendable, and we only ever hand it straight back to the main actor.
private struct Box<T>: @unchecked Sendable { let value: T }

private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// Give up on `work` after `seconds` and return nil.
///
/// Deliberately not a task group: a group awaits every child on the way out, so a child
/// wedged inside ScreenCaptureKit would hang the timeout too. ScreenCaptureKit really does
/// wedge — if replayd drops the client (`SCStreamManager serverDidDisconnect`) the async call
/// neither returns nor throws. We abandon that task instead of waiting for it.
private func withDeadline<T>(_ seconds: Double, _ work: @escaping @Sendable () async -> Box<T>) async -> Box<T>? {
    let once = OnceBox()
    return await withCheckedContinuation { (cont: CheckedContinuation<Box<T>?, Never>) in
        let task = Task.detached {
            let result = await work()
            if once.claim() { cont.resume(returning: result) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if once.claim() {
                task.cancel()
                cont.resume(returning: nil)
            }
        }
    }
}

public enum StripSource {
    /// Called once at startup. Returns whether ScreenCaptureKit is usable this run.
    public static func ensureCaptureAccess(mode: SourceMode) -> Bool {
        guard mode != .wallpaper else { return false }
        if CGPreflightScreenCaptureAccess() { return true }
        note("""
        \(programName) needs Screen Recording permission to photograph the desktop behind the
        menu bar. Approving the prompt applies to the app that launched this (your terminal);
        you'll need to run \(programName) again afterwards. Falling back to rendering the
        wallpaper file directly for now.
        """)
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    /// Produce the image that covers the menu bar on one display.
    public static func strip(info: DisplayInfo, spec: WallpaperSpec, mode: SourceMode,
                             captureAllowed: Bool) async -> StripImage? {
        if mode != .wallpaper && captureAllowed {
            let outcome: Box<Result<CGImage, Error>>? = await withDeadline(6) {
                do { return Box(value: .success(try await captured(info: info))) }
                catch { return Box(value: .failure(error)) }
            }
            switch outcome {
            case .none:
                warn("screen capture wedged on \(info.name) — ScreenCaptureKit stopped answering."
                     + " That happens when a second client of the same binary connects;"
                     + " check with `pgrep -l \(programName)`. Falling back to the wallpaper file.")
            case .some(let box):
                switch box.value {
                case .success(let image): return StripImage(image: image, source: "screen capture")
                case .failure(let error): warn("screen capture failed on \(info.name): \(error)")
                }
            }
            if mode == .capture { return nil }
        }
        if mode == .capture { return nil }
        if let image = fromWallpaperFile(info: info, spec: spec) {
            let name = spec.url?.lastPathComponent ?? "wallpaper"
            return StripImage(image: image, source: "wallpaper file (\(name))")
        }
        return nil
    }

    // MARK: - ScreenCaptureKit

    /// The desktop behind the menu bar is every window below normal window level: the wallpaper,
    /// and the "underbelly" shading macOS lays under the bar, which a wallpaper-only capture
    /// misses. Nothing an app opens is in it, bario's covers included, so the photograph can
    /// never show the bar it sits under.
    ///
    /// Built fresh for every capture, since captures are rare and a space can bring its own
    /// wallpaper window.
    private static func filter(for info: DisplayInfo) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == info.displayID }) else {
            throw StripError.noSharableDisplay(info.displayID)
        }
        let normal = Int(CGWindowLevelForKey(.normalWindow))
        return SCContentFilter(display: display, including: content.windows.filter { $0.windowLayer < normal })
    }

    /// Photograph what is behind the menu bar. The shadows windows cast up into the strip are
    /// left out: they reach it only from windows within ~25pt of the bar and change it by a few
    /// levels, mostly a 1pt line at the window's edge, and following them would mean
    /// photographing continuously.
    public static func captured(info: DisplayInfo) async throws -> CGImage {
        let filter = try await filter(for: info)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: 0, y: 0, width: info.frame.width, height: info.stripHeight)
        config.width = Int((info.frame.width * info.scale).rounded())
        config.height = Int((info.stripHeight * info.scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false
        config.colorSpaceName = CGColorSpace.displayP3
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Wallpaper file

    /// Re-create the top strip of the desktop by drawing the wallpaper file the way the
    /// system would. No permission required, but it can't see anything the system layers
    /// on top (dynamic desktops resolve to their primary image, aerials won't match).
    public static func fromWallpaperFile(info: DisplayInfo, spec: WallpaperSpec) -> CGImage? {
        let screenPx = CGSize(width: (info.frame.width * info.scale).rounded(),
                              height: (info.frame.height * info.scale).rounded())
        let stripPx = max(1, (info.stripHeight * info.scale).rounded())

        guard let ctx = CGContext(data: nil,
                                  width: Int(screenPx.width),
                                  height: Int(stripPx),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.setFillColor(spec.fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: screenPx.width, height: stripPx))
        ctx.interpolationQuality = .high

        if let url = spec.url,
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(src, CGImageSourceGetPrimaryImageIndex(src), nil) {
            let dest = fitRect(image: CGSize(width: image.width, height: image.height),
                               into: screenPx, scaling: spec.scaling, clips: spec.clips)
            // The strip is the top of the screen; slide the whole screen down so that the
            // top lands inside this short context.
            ctx.translateBy(x: 0, y: -(screenPx.height - stripPx))
            ctx.draw(image, in: dest)
        }
        return ctx.makeImage()
    }

    /// Where the system would draw an image of `image` size on a screen of `screen` size,
    /// in bottom-left origin pixels.
    public static func fitRect(image: CGSize, into screen: CGSize, scaling: NSImageScaling, clips: Bool) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: screen) }
        let sx = screen.width / image.width
        let sy = screen.height / image.height
        let size: CGSize
        switch scaling {
        case .scaleAxesIndependently:
            return CGRect(origin: .zero, size: screen)
        case .scaleNone:
            size = image
        default:
            let s = clips ? max(sx, sy) : min(sx, sy)
            size = CGSize(width: image.width * s, height: image.height * s)
        }
        return CGRect(x: (screen.width - size.width) / 2,
                      y: (screen.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
