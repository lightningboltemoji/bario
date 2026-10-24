import AppKit

/// The window server's private API, for the things about Spaces that have no public one:
/// holding a window still while Spaces slide past, telling which displays a native full screen
/// app has, and hearing one start to zoom in. Each call is looked up when it is first wanted, so
/// nothing links against SkyLight, and a macOS without them gets a bar that rides its Space and
/// never thinks it is over a full screen app. DESIGN.md §6.
@MainActor
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private typealias RegisterNotifyProc = @convention(c) (NotifyProc, UInt32, UnsafeMutableRawPointer?) -> Int32

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
    private static let registerNotifyProc = symbol("SLSRegisterNotifyProc", RegisterNotifyProc.self)

    // MARK: - Full screen

    /// The `type` of a Space a native full screen app has made; 0 is an ordinary desktop.
    private static let fullscreenSpace = 4

    /// The displays whose current Space is a full screen app's.
    ///
    /// It changes the moment `activeSpaceDidChangeNotification` is sent, at the end of the
    /// slide. That notification does not come for every change (clicking into a full screen
    /// app on another display sends none), so this is asked on a timer too.
    static func fullscreenDisplays(among ids: [CGDirectDisplayID]) -> Set<CGDirectDisplayID> {
        displays(among: ids) { display in
            (display["Current Space"] as? [String: Any])?["type"] as? Int == fullscreenSpace
        }
    }

    /// The displays `space` is a full screen app's Space on: where one zooming in will land.
    static func displays(withFullscreenSpace space: UInt64, among ids: [CGDirectDisplayID]) -> Set<CGDirectDisplayID> {
        displays(among: ids, where: hasFullscreenSpace(space))
    }

    /// Whether a display, as the window server describes it, has `space` among its Spaces as a
    /// full screen app's. It is there from the start of the zoom, before it is current.
    static func hasFullscreenSpace(_ space: UInt64) -> ([String: Any]) -> Bool {
        { display in
            ((display["Spaces"] as? [[String: Any]]) ?? []).contains { candidate in
                (candidate["ManagedSpaceID"] as? NSNumber)?.uint64Value == space
                    && candidate["type"] as? Int == fullscreenSpace
            }
        }
    }

    /// The displays among `ids` whose Spaces, as the window server describes them, pass `test`.
    private static func displays(among ids: [CGDirectDisplayID],
                                 where test: ([String: Any]) -> Bool) -> Set<CGDirectDisplayID> {
        guard let connection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return SkyLight.displays(among: ids, in: displays, uuid: uuid(of:), where: test)
    }

    /// The same, from a description already read: so the matching can be tested.
    static func displays(among ids: [CGDirectDisplayID], in displays: [[String: Any]],
                         uuid: (CGDirectDisplayID) -> String?,
                         where test: ([String: Any]) -> Bool) -> Set<CGDirectDisplayID> {
        var passes: [String: Bool] = [:]
        for display in displays {
            guard let name = display["Display Identifier"] as? String else { continue }
            passes[name] = test(display)
        }
        // With "Displays have separate Spaces" off there is one set of Spaces, called "Main",
        // and a full screen app on one display leaves the others blank.
        if let shared = passes["Main"] { return shared ? Set(ids) : [] }
        return Set(ids.filter { id in uuid(id).flatMap { passes[$0] } == true })
    }

    // MARK: - A full screen app on its way

    /// The window server's event for a full screen app zooming into a Space of its own. It
    /// comes twice: with the Space and 0 about 40ms into the zoom, and with the Space and 1 as
    /// the app lands, half a second later, alongside `activeSpaceDidChangeNotification`.
    /// Measured on macOS 27.2, and only for a zoom: not for a swipe to a full screen app already
    /// there, nor on the way out. Not an API, so a macOS that numbers it otherwise sends nothing.
    static let fullscreenZoomEvent: UInt32 = 828

    /// Whoever hears a zoom start, called on the main thread with its Space.
    private nonisolated(unsafe) static var zoomStarts: (@MainActor (UInt64) -> Void)?

    /// Calls `handler` with the Space a full screen app has started zooming into, half a second
    /// before that Space is current. Returns false where SkyLight cannot say.
    @discardableResult
    static func whenFullscreenZoomStarts(_ handler: @escaping @MainActor (UInt64) -> Void) -> Bool {
        guard let registerNotifyProc else { return false }
        zoomStarts = handler
        return registerNotifyProc(fullscreenZoomProc, fullscreenZoomEvent, nil) == 0
    }

    /// What the event says: the Space, then whether the app has landed in it. nil for a payload
    /// not shaped as measured, which is never taken for one that is.
    nonisolated static func zoom(_ bytes: UnsafeRawBufferPointer) -> (space: UInt64, landed: Bool)? {
        guard bytes.count >= 12 else { return nil }
        return (bytes.loadUnaligned(as: UInt64.self), bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self) != 0)
    }

    /// SkyLight called it on the main thread every time it was measured, but nothing promises
    /// that, so it hops there.
    fileprivate nonisolated static func zoomed(_ space: UInt64) {
        DispatchQueue.main.async { MainActor.assumeIsolated { zoomStarts?(space) } }
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

/// SkyLight's callback for `fullscreenZoomEvent`. A C function pointer captures nothing, so it
/// finds its handler through `SkyLight`.
private let fullscreenZoomProc: SkyLight.NotifyProc = { _, data, length, _ in
    guard let data, let zoom = SkyLight.zoom(UnsafeRawBufferPointer(start: data, count: length)),
          !zoom.landed else { return }
    SkyLight.zoomed(zoom.space)
}
