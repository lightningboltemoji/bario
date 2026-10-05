import AppKit

/// The window server's private API, for the two things about Spaces that have no public one:
/// holding a window still while Spaces slide past, and telling which displays a native full
/// screen app has. Each call is looked up when it is first wanted, so nothing links against
/// SkyLight, and a macOS without them gets a bar that rides its Space and never thinks it is
/// over a full screen app. DESIGN.md §6.
@MainActor
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
                                        RTLD_LAZY)

    private static func symbol<T>(_ name: String, _: T.Type) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let connection = symbol("SLSMainConnectionID", MainConnection.self)?()
    private static let copyManagedDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces",
                                                         CopyManagedDisplaySpaces.self)
    private static let spaceCreate = symbol("SLSSpaceCreate", SpaceCreate.self)
    private static let spaceSetAbsoluteLevel = symbol("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self)
    private static let showSpaces = symbol("SLSShowSpaces", ShowSpaces.self)
    private static let spaceAddWindows = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", SpaceAddWindows.self)

    // MARK: - Full screen

    /// The `type` of a Space a native full screen app has made; 0 is an ordinary desktop.
    private static let fullscreenSpace = 4

    /// The displays whose current Space is a full screen app's.
    ///
    /// It changes the moment `activeSpaceDidChangeNotification` is sent, at the end of the
    /// slide. That notification does not come for every change (clicking into a full screen
    /// app on another display sends none), so this is asked on a timer too.
    static func fullscreenDisplays(among ids: [CGDirectDisplayID]) -> Set<CGDirectDisplayID> {
        guard let connection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        var fullscreen: [String: Bool] = [:]
        for display in displays {
            guard let name = display["Display Identifier"] as? String,
                  let current = display["Current Space"] as? [String: Any] else { continue }
            fullscreen[name] = current["type"] as? Int == fullscreenSpace
        }
        // With "Displays have separate Spaces" off there is one set of Spaces, called "Main",
        // and a full screen app on one display leaves the others blank.
        if let shared = fullscreen["Main"] { return shared ? Set(ids) : [] }
        return Set(ids.filter { id in uuid(of: id).flatMap { fullscreen[$0] } == true })
    }

    private static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: - Fixed windows

    /// bario's own Space, above every other, made the first time a window is fixed. It is the
    /// connection's, so the window server takes it away when bario quits.
    private static var space: Int32?

    /// Takes a window out of every Space and into bario's own, where nothing slides. Returns
    /// false where SkyLight cannot, leaving the window where it was.
    ///
    /// A cover does it again each time it orders its window in, rather than trusting that
    /// ordering in leaves the window here. What these calls return means nothing on macOS 27,
    /// so none of it is read.
    @discardableResult
    static func fix(_ window: NSWindow) -> Bool {
        guard let connection, let spaceCreate, let spaceSetAbsoluteLevel, let showSpaces,
              let spaceAddWindows, window.windowNumber > 0 else { return false }
        if space == nil {
            let id = spaceCreate(connection, 1, 0)
            guard id != 0 else { return false }
            _ = spaceSetAbsoluteLevel(connection, id, 0)
            _ = showSpaces(connection, [NSNumber(value: id)] as CFArray)
            space = id
        }
        guard let space else { return false }
        _ = spaceAddWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 0x7)
        return true
    }
}
