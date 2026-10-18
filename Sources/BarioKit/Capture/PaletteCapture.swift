import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

/// The image a palette is measured from (PLAN.md W5): a small photograph of the display's
/// wallpaper window and nothing else, or the wallpaper file where that cannot be had. The
/// strip's capture takes every window below normal level, and a palette must not: a calendar
/// widget is a palette's worth of grey.
@MainActor
public final class PaletteCapture {
    /// The window WindowManager draws a display's wallpaper in, as macOS 27.2 has it. Not API:
    /// if a later macOS renames it, the file stands in and the capture says so once.
    static let owner = "com.apple.WindowManager"
    static let title = "Wallpaper"

    /// Wallpaper files, thumbnailed once each.
    private var thumbnails: [URL: CGImage] = [:]
    private var warnedNoWindow = false

    public init() {}

    /// What to measure one display's palette from, or nil when there is nothing: no wallpaper
    /// window or no permission to photograph it, and no file that can be read either.
    public func image(info: DisplayInfo, spec: WallpaperSpec, mode: SourceMode,
                      captureAllowed: Bool) async -> CGImage? {
        if mode != .wallpaper && captureAllowed {
            let outcome: Box<Result<CGImage?, Error>>? = await withDeadline(6) {
                do { return Box(value: .success(try await PaletteCapture.captured(info: info))) }
                catch { return Box(value: .failure(error)) }
            }
            switch outcome?.value {
            case .success(let image?)?:
                return image
            case .success(nil)?:
                if !warnedNoWindow {
                    warnedNoWindow = true
                    warn("no wallpaper window on \(info.name) to measure colours from, so they come from the "
                         + "wallpaper file, which misses dynamic desktops and aerials; macOS may have renamed "
                         + "the window (\(PaletteCapture.owner), \"\(PaletteCapture.title)\")")
                }
            case .failure(let error)?:
                warn("could not photograph the wallpaper on \(info.name): \(error)")
            case nil:
                warn("photographing the wallpaper on \(info.name) wedged; trying the wallpaper file")
            }
            if mode == .capture { return nil }
        }
        if mode == .capture { return nil }
        return await file(spec.url)
    }

    /// The wallpaper window alone, 320 pixels wide, or nil when there is no such window on the
    /// display. It took 23–30ms at any width from 160 to 640 pixels.
    static func captured(info: DisplayInfo) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == info.displayID }) else {
            throw StripError.noSharableDisplay(info.displayID)
        }
        let normal = Int(CGWindowLevelForKey(.normalWindow))
        func overlap(_ window: SCWindow) -> CGFloat {
            let shared = window.frame.intersection(display.frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let window = content.windows
            .filter({ $0.windowLayer < normal && $0.owningApplication?.bundleIdentifier == owner
                      && $0.title == title && overlap($0) > 0 })
            .max(by: { overlap($0) < overlap($1) }) else { return nil }

        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: 0, y: 0, width: info.frame.width, height: info.frame.height)
        config.width = Quantizer.width
        config.height = max(1, Int((CGFloat(Quantizer.width) * info.frame.height / info.frame.width).rounded()))
        config.scalesToFit = true
        config.showsCursor = false
        config.captureResolution = .nominal
        config.colorSpaceName = CGColorSpace.displayP3
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, including: [window]), configuration: config)
    }

    /// A wallpaper file, decoded off the main actor the first time it is asked for.
    private func file(_ url: URL?) async -> CGImage? {
        guard let url else { return nil }
        if let image = thumbnails[url] { return image }
        guard let image = await Task.detached(operation: { Box(value: PaletteCapture.thumbnail(of: url)) })
            .value.value else { return nil }
        if thumbnails.count >= 8 { thumbnails = [:] }      // a shuffling wallpaper, many files
        thumbnails[url] = image
        return image
    }

    /// A wallpaper file at the palette's width: ImageIO decodes it straight to a thumbnail, its
    /// primary image for a dynamic desktop, rotated as it is meant to be shown.
    public nonisolated static func thumbnail(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Quantizer.width,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source),
                                                   options as CFDictionary)
    }
}
