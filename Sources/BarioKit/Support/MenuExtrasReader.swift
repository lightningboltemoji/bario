import AppKit
import ApplicationServices
import ImageIO
import ScreenCaptureKit
import Synchronization
import UniformTypeIdentifiers

/// Every app's items in the menu bar, through Accessibility, and their pictures, photographed
/// from the menu bar under the cover.
///
/// Measured on macOS 27: each app's items are its `AXExtrasMenuBar`'s children; the system's own
/// (Wi‑Fi, Battery, Control Center, Clock) are `MenuBarAgent`'s, each an `AXHostingView` group
/// around the item. Asking all 70-odd running apps takes ~130 ms the first time, the messages
/// to each app being set up then, and ~3 ms after. No item has a window of its own any more:
/// the window server draws them all into one window per display, layer 24, titled "Menubar",
/// which ScreenCaptureKit photographs whatever covers it, in ~30 ms with its listing.
enum MenuExtrasReader {
    /// Each message to an app, which is waited on.
    static let timeout: Float = 0.1
    static let menuBarTitle = "Menubar"

    /// A running app, as read on the main actor.
    struct App: Sendable {
        var pid: pid_t
        var bundleID: String?
        var name: String
        var bundlePath: String?
    }

    @MainActor
    static func runningApps() -> [App] {
        NSWorkspace.shared.runningApplications.map { app in
            let path = app.bundleURL?.path
            let outer = path.flatMap(MenuExtras.outermostApp)
            let name = outer.map { FileManager.default.displayName(atPath: $0) }
                .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
            return App(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                       name: name ?? app.localizedName ?? "", bundlePath: outer)
        }
    }

    /// Every item of every other app, asked of all of them at once. Not bario's own: see `ownItems`.
    static func read(_ apps: [App]) -> [MenuExtra] {
        let others = apps.filter { $0.pid != getpid() }
        let found = Mutex<[MenuExtra]>([])
        DispatchQueue.concurrentPerform(iterations: others.count) { i in
            let extras = items(of: others[i])
            guard !extras.isEmpty else { return }
            found.withLock { $0 += extras }
        }
        return found.withLock { $0 }
    }

    /// bario's own item. Accessibility asked of this process is not a message but a call, made
    /// on the asking thread into AppKit, which is the main thread's alone: pressing the item from
    /// any other traps in AppKit.
    @MainActor
    static func ownItems(_ apps: [App]) -> [MenuExtra] {
        apps.first { $0.pid == getpid() }.map(items(of:)) ?? []
    }

    private static func items(of app: App) -> [MenuExtra] {
        elements(pid: app.pid).enumerated().compactMap { index, element in extra(element, app: app, index: index) }
    }

    /// Press one, waiting no longer than `wait` for the app to say it has: one whose menu opens
    /// answers only when the menu closes. bario's own is pressed on the main thread, later, as
    /// its menu then runs there until it closes.
    static func press(pid: pid_t, index: Int, wait: Float = 1) -> AXError {
        guard pid != getpid() else {
            DispatchQueue.main.async {
                let items = elements(pid: pid)
                guard items.indices.contains(index) else { return }
                AXUIElementPerformAction(items[index], kAXPressAction as CFString)
            }
            return .success
        }
        let items = elements(pid: pid)
        guard items.indices.contains(index) else { return .invalidUIElement }
        AXUIElementSetMessagingTimeout(items[index], wait)
        return AXUIElementPerformAction(items[index], kAXPressAction as CFString)
    }

    /// An app's items: the `AXMenuBarItem`s, a hosting group's taken from inside it.
    private static func elements(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let bar = value(of: app, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return [] }
        return children(of: bar as! AXUIElement).map { element in
            guard value(of: element, kAXRoleAttribute) as? String == kAXGroupRole else { return element }
            return children(of: element).first {
                value(of: $0, kAXRoleAttribute) as? String == kAXMenuBarItemRole
            } ?? element
        }
    }

    private static let attributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                                     kAXPositionAttribute, kAXSizeAttribute, kAXIdentifierAttribute]

    private static func extra(_ element: AXUIElement, app: App, index: Int) -> MenuExtra? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values) == .success,
              let list = values as? [AnyObject], list.count == attributes.count else { return nil }
        // A missing attribute comes back as an error value in its place.
        func text(_ i: Int) -> String? {
            (list[i] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func axValue(_ i: Int, _ type: AXValueType) -> AXValue? {
            guard CFGetTypeID(list[i]) == AXValueGetTypeID(), AXValueGetType(list[i] as! AXValue) == type
            else { return nil }
            return (list[i] as! AXValue)
        }
        var origin = CGPoint.zero, size = CGSize.zero
        if let value = axValue(3, .cgPoint) { AXValueGetValue(value, .cgPoint, &origin) }
        if let value = axValue(4, .cgSize) { AXValueGetValue(value, .cgSize, &size) }
        return MenuExtra(pid: app.pid, index: index, frame: CGRect(origin: origin, size: size),
                         title: text(0), description: text(1), help: text(2), identifier: text(5),
                         bundleID: app.bundleID, appName: app.name, appPath: app.bundlePath)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        value(of: element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> AnyObject? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    // MARK: - Pictures

    /// Every display's menu bar window, photographed: an empty list without permission to, or
    /// if macOS has renamed the window.
    static func photograph() async throws -> [MenuBarPicture] {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let layer = Int(CGWindowLevelForKey(.mainMenuWindow))
        var pictures: [MenuBarPicture] = []
        for window in content.windows where window.title == menuBarTitle && window.windowLayer == layer {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
            let config = SCStreamConfiguration()
            config.width = Int((window.frame.width * scale).rounded())
            config.height = Int((window.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if let picture = picture(of: image, frame: window.frame, scale: scale) { pictures.append(picture) }
        }
        return pictures
    }

    /// The image's pixels as `MenuBarPicture` reads them, whatever format it came in.
    private static func picture(of image: CGImage, frame: CGRect, scale: CGFloat) -> MenuBarPicture? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? MenuBarPicture(width: width, height: height, bytes: bytes, frame: frame, scale: scale) : nil
    }

    /// A cut of a picture as a PNG, with its pixels to the point recorded so it reads back at
    /// its size in points.
    static func png(_ cut: CGRect, of picture: MenuBarPicture) -> Data? {
        let width = Int(cut.width), height = Int(cut.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let from = ((Int(cut.minY) + row) * picture.width + Int(cut.minX)) * 4
            bytes.replaceSubrange(row * width * 4..<(row + 1) * width * 4,
                                  with: picture.bytes[from..<from + width * 4])
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        let dpi = 72 * picture.scale
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi,
                                                        kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
