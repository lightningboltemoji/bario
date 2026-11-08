import CoreGraphics
import Foundation

/// `objc_msgSend` as the two methods' implementations take it: the receiver and the selector
/// as pointers, then the arguments.
private typealias KeyboardLevel = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UInt64) -> Float
private typealias SetKeyboardLevel = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, Float, UInt64) -> Bool

/// The display's backlight and the keyboard's, which have no public API. The display's is
/// DisplayServices', and the keyboard's CoreBrightness's `KeyboardBrightnessClient`; both are
/// looked up when first wanted, as SkyLight is, so nothing links against them and a Mac where
/// they are missing has a `brightness` module that reports none. Neither needs a permission.
enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private nonisolated(unsafe) static let displayServices = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter: Get? = displayServices.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: Get.self) }
    private static let setter: Set? = displayServices.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: Set.self) }

    /// The first display whose brightness can be read, the built-in one first: the one the
    /// brightness keys change.
    static func display() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        let online = ids.prefix(Int(count)).sorted { CGDisplayIsBuiltin($0) > CGDisplayIsBuiltin($1) }
        return online.first { level(of: $0) != nil }
    }

    /// 0…1.
    static func level(of display: CGDirectDisplayID) -> Double? {
        guard let getter else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? Double(value) : nil
    }

    static func set(_ value: Double, of display: CGDirectDisplayID) {
        _ = setter?(display, Float(min(1, max(0, value))))
    }

    // MARK: - The keyboard

    private nonisolated(unsafe) static let coreBrightness = dlopen(
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)

    /// One client for the life of the process, which is how CoreBrightness's own are used.
    private nonisolated(unsafe) static let client: NSObject? = {
        _ = coreBrightness
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return type.init()
    }()
    private static let lock = NSLock()

    /// The keyboard backlight's identity, if the Mac has one.
    static func keyboard() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        let selector = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let client, client.responds(to: selector),
              let ids = client.perform(selector)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return ids.first?.uint64Value
    }

    /// 0…1.
    static func level(ofKeyboard keyboard: UInt64) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        guard let client, client.responds(to: selector), let method = client.method(for: selector) else { return nil }
        return Double(unsafeBitCast(method, to: KeyboardLevel.self)(
            UnsafeRawPointer(Unmanaged.passUnretained(client).toOpaque()),
            unsafeBitCast(selector, to: UnsafeRawPointer.self), keyboard))
    }

    static func set(_ value: Double, ofKeyboard keyboard: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let selector = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let client, client.responds(to: selector), let method = client.method(for: selector) else { return }
        _ = unsafeBitCast(method, to: SetKeyboardLevel.self)(
            UnsafeRawPointer(Unmanaged.passUnretained(client).toOpaque()),
            unsafeBitCast(selector, to: UnsafeRawPointer.self), Float(min(1, max(0, value))), keyboard)
    }
}
