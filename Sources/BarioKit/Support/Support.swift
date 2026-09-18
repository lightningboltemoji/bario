import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What `warn` prefixes its messages with. Each executable sets it once at startup.
public nonisolated(unsafe) var programName = "bario"

extension NSScreen {
    public var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// How much of the top of this screen the menu bar is currently eating, in points.
    /// Zero-ish when the menu bar is auto-hidden or a full screen app owns the space.
    public var menuBarInset: CGFloat { frame.maxY - visibleFrame.maxY }

    /// The inset, or a sane guess if the bar is hidden right now.
    public var menuBarHeight: CGFloat {
        let inset = menuBarInset
        return inset > 1 ? inset : max(NSStatusBar.system.thickness, 24)
    }

    public var menuBarFrame: CGRect {
        let h = menuBarHeight
        return CGRect(x: frame.minX, y: frame.maxY - h, width: frame.width, height: h)
    }

    /// The notch, in screen coordinates, or nil on a display without one. `NSScreen` says
    /// exactly where: the two auxiliary areas are the usable rects and the gap between them
    /// is the obstacle. DESIGN.md §6.
    public var notchFrame: CGRect? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let height = safeAreaInsets.top > 0 ? safeAreaInsets.top : menuBarHeight
        let x = left.maxX
        let width = right.minX - left.maxX
        guard width > 1 else { return nil }
        return CGRect(x: x, y: frame.maxY - height, width: width, height: height)
    }
}

public struct RGBA: Sendable, Hashable {
    public var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1

    public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// Everything about one display that the strip renderers need, snapshotted on the main
/// thread so the async capture path never touches AppKit off-main.
public struct DisplayInfo: Sendable, Hashable {
    public var displayID: CGDirectDisplayID
    public var name: String
    public var frame: CGRect
    public var scale: CGFloat
    public var stripHeight: CGFloat
    public var isBuiltIn: Bool
    /// In screen coordinates; nil on a display without a notch.
    public var notch: CGRect?

    public init(displayID: CGDirectDisplayID, name: String, frame: CGRect, scale: CGFloat,
                stripHeight: CGFloat, isBuiltIn: Bool = false, notch: CGRect? = nil) {
        self.displayID = displayID
        self.name = name
        self.frame = frame
        self.scale = scale
        self.stripHeight = stripHeight
        self.isBuiltIn = isBuiltIn
        self.notch = notch
    }

    public init?(screen: NSScreen) {
        guard let id = screen.displayID else { return nil }
        displayID = id
        name = screen.localizedName
        frame = screen.frame
        scale = screen.backingScaleFactor
        stripHeight = screen.menuBarHeight
        isBuiltIn = CGDisplayIsBuiltin(id) != 0
        notch = screen.notchFrame
    }

    /// The notch in the cover view's own coordinates, where x is measured from the left of
    /// the strip.
    public var notchInStrip: CGRect? {
        notch.map { CGRect(x: $0.minX - frame.minX, y: 0, width: $0.width, height: $0.height) }
    }
}

/// The desktop picture settings for one screen, as plain data.
public struct WallpaperSpec: Sendable {
    public var url: URL?
    public var scalingRaw: UInt
    public var clips: Bool
    public var fill: RGBA

    public init(screen: NSScreen) {
        let ws = NSWorkspace.shared
        url = ws.desktopImageURL(for: screen)
        let opts = ws.desktopImageOptions(for: screen) ?? [:]
        scalingRaw = (opts[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
        clips = (opts[.allowClipping] as? NSNumber)?.boolValue ?? true
        fill = RGBA((opts[.fillColor] as? NSColor) ?? .black)
    }

    public var scaling: NSImageScaling { NSImageScaling(rawValue: scalingRaw) ?? .scaleProportionallyUpOrDown }
}

public enum PNG {
    public static func write(_ image: CGImage, to path: String) {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

public func note(_ message: String) {
    print(message)
    fflush(stdout)
}

public func warn(_ message: String) {
    FileHandle.standardError.write(Data("\(programName): \(message)\n".utf8))
}

/// One instance of a given name at a time. Two covers fight over the same strip of screen,
/// and — worse — ScreenCaptureKit disconnects the second client and then never resumes its
/// async calls.
public enum SingleInstance {
    private nonisolated(unsafe) static var held: Int32 = -1

    /// Returns nil if we now hold the lock, or the pid of whoever already does.
    public static func claim(name: String) -> pid_t? {
        let path = NSTemporaryDirectory() + "\(name).lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }          // can't lock: don't stand in the way

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            var buf = [CChar](repeating: 0, count: 32)
            let n = read(fd, &buf, 31)
            close(fd)
            guard n > 0 else { return 0 }
            return pid_t(String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        ftruncate(fd, 0)
        _ = "\(getpid())\n".withCString { write(fd, $0, strlen($0)) }
        held = fd                                   // stays open for the life of the process
        return nil
    }
}
