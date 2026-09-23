import AppKit
import CoreAudio
import IOKit.ps

/// A module that renders its state through a format string, which is nearly all of them.
/// Subclassing is not available to actors, so this is a helper the modules hold.
struct FormatRenderer: Sendable {
    var content: Node?
    var contentTemplate: ContentTemplate?
    var template: FormatString?
    var fallbackSlot: String

    init(format: String?, fallback: String) {
        template = format.flatMap { try? FormatString.parse($0) }
        fallbackSlot = fallback
    }

    /// The item's own `content` block wins over its format, and the format over the module's
    /// default: every module that shows a format also shows a content tree, templated or not.
    init(_ context: ModuleContext, format: String, fallback: String) {
        self.init(format: context.format ?? format, fallback: fallback)
        content = context.content
        contentTemplate = context.template
    }

    func render(_ state: StateReader) throws -> Node? {
        if let content { return content }
        if let contentTemplate { return try contentTemplate.render(state) }
        if let template { return template.render(state) }
        return state.value(fallbackSlot).flatMap(\.stringValue).map { Node.text($0) }
    }
}

/// The frontmost application, which is exactly what the cover hides first.
public actor FrontAppModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    private let maxLength: Int?
    private var observer: NSObjectProtocol?

    public init(context: ModuleContext) {
        self.context = context
        self.renderer = FormatRenderer(context, format: "{name}", fallback: "name")
        self.maxLength = context.config["max-length"]?.intValue
    }

    public func start() async {
        let store = context.store
        let item = context.item
        let limit = maxLength
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let patch = FrontAppModule.patch(for: app, limit: limit)
            Task { await store.merge(patch, at: item) }
        }
    }

    public func stop() async {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    public func poll() async -> PollResult {
        let app = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        // Event-driven from here: the activation notification does the rest.
        return PollResult(patch: FrontAppModule.patch(for: app, limit: maxLength), nextIn: nil)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        RenderResult(content: try renderer.render(state))
    }

    static func patch(for app: NSRunningApplication?, limit: Int?) -> JSONValue {
        var name = app?.localizedName ?? ""
        if let limit, limit > 1, name.count > limit {
            name = String(name.prefix(limit - 1)) + "…"
        }
        return .object([
            "name": .string(name),
            "bundle-id": app?.bundleIdentifier.map(JSONValue.string) ?? .null,
            "icon": .string("app.badge"),
        ])
    }
}

/// IOKit power sources. Event-driven: the run loop source fires on every change, so an idle
/// bar with a battery on it runs no timer.
public actor BatteryModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    private let lowThreshold: Double
    private var source: CFRunLoopSource?

    public init(context: ModuleContext) {
        self.context = context
        self.renderer = FormatRenderer(context, format: "{icon} {pct}%", fallback: "pct")
        self.lowThreshold = context.double("low", default: 20) ?? 20
    }

    public func start() async {
        let store = context.store
        let item = context.item
        let box = Unmanaged.passRetained(CallbackBox { 
            Task { await store.merge(BatteryModule.read(), at: item) }
        }).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue().run()
        }, box)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
    }

    public func stop() async {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    public func poll() async -> PollResult {
        PollResult(patch: BatteryModule.read(), nextIn: nil)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        var classes: [String] = []
        let percent = state.value("pct")?.doubleValue ?? 100
        if state.value("charging")?.boolValue == true { classes.append("charging") }
        if state.value("plugged")?.boolValue == true { classes.append("plugged") }
        if percent <= lowThreshold { classes.append("low") }
        let tooltip = state.value("time-remaining")?.intValue
            .map { "\(Humanise.duration(minutes: $0)) remaining" }
        return RenderResult(content: try renderer.render(state), classes: classes, tooltip: tooltip)
    }

    /// Reads IOKit and flattens it to the state shape. Pure enough to be worth separating.
    static func read() -> JSONValue {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let description = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue()
                as? [String: Any]
        else {
            return .object(["present": .bool(false)])
        }

        let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
        let percent = maximum > 0 ? Double(current) / Double(maximum) * 100 : 0
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let plugged = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

        var patch: [String: JSONValue] = [
            "present": .bool(true),
            "pct": .number(percent.rounded()),
            "fraction": .number((percent / 100 * 1000).rounded() / 1000),
            "charging": .bool(charging),
            "plugged": .bool(plugged),
            "icon": .string(Symbols.battery(percent: percent, charging: charging, plugged: plugged)),
        ]
        // -1 means "still estimating"; a bubble reading "-1 min" is worse than no bubble.
        let key = charging || plugged ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
        if let minutes = description[key] as? Int, minutes >= 0 {
            patch["time-remaining"] = .number(Double(minutes))
            patch["time"] = .string(Humanise.duration(minutes: minutes))
        } else {
            patch["time-remaining"] = .null
            patch["time"] = .null
        }
        return .object(patch)
    }
}

/// CoreAudio's default output device, with listeners on the device, its volume, its mute and
/// its data source, re-registered whenever the default device itself changes.
///
/// The icon follows the device as well as the level: headphones show as headphones, and AirPods
/// and Beats as themselves, so the bar says where the sound is going.
public actor VolumeModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    /// Bluetooth outputs that are speakers, by name: Bluetooth audio is headphones unless this
    /// says otherwise.
    private let speakers: [String]
    private var block: AudioObjectPropertyListenerBlock?
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress)] = []

    public init(context: ModuleContext) {
        self.context = context
        self.renderer = FormatRenderer(context, format: "{icon}", fallback: "level")
        switch context.option("speakers") {
        case .string(let names)?: speakers = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case .array(let names)?: speakers = names.compactMap(\.stringValue)
        default: speakers = []
        }
    }

    public func start() async {
        let store = context.store
        let item = context.item
        let speakers = speakers
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task {
                await store.merge(VolumeModule.read(speakers: speakers), at: item)
                await self?.followDeviceChanges()
            }
        }
        block = listener
        listen(to: AudioObjectID(kAudioObjectSystemObject),
               selector: kAudioHardwarePropertyDefaultOutputDevice,
               scope: kAudioObjectPropertyScopeGlobal)
        followDeviceChanges()
    }

    public func stop() async {
        unlistenAll()
        block = nil
    }

    public func poll() async -> PollResult {
        // A safety net rather than a heartbeat: the listeners do the work.
        PollResult(patch: VolumeModule.read(speakers: speakers), nextIn: nil)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        var classes: [String] = []
        if state.value("muted")?.boolValue == true { classes.append("muted") }
        if state.value("headphones")?.boolValue == true { classes.append("headphones") }
        return RenderResult(content: try renderer.render(state), classes: classes,
                            tooltip: state.value("device")?.stringValue)
    }

    /// `on-scroll="adjust"` and `on-click="toggle-mute"` from DESIGN.md §8. Neither is a
    /// special case in the config layer: an action bario does not recognise arrives here.
    public func onEvent(_ event: ModuleEvent) async -> JSONValue? {
        switch event.name {
        case "toggle-mute", "mute":
            VolumeModule.setMuted(!(VolumeModule.read()["muted"]?.boolValue ?? false))
        case "adjust", "scroll":
            // A scroll's dy is in points; a tenth of a percent per point is about right for a
            // trackpad and still usable with a wheel.
            let dy = event.payload["dy"]?.doubleValue ?? 0
            let dx = event.payload["dx"]?.doubleValue ?? 0
            let step = event.payload["step"]?.doubleValue ?? ((dy != 0 ? dy : dx) * 0.4)
            guard step != 0 else { return nil }
            let current = VolumeModule.read()["level"]?.doubleValue ?? 0
            VolumeModule.setLevel(current + step)
        case "up":
            VolumeModule.setLevel((VolumeModule.read()["level"]?.doubleValue ?? 0) + 5)
        case "down":
            VolumeModule.setLevel((VolumeModule.read()["level"]?.doubleValue ?? 0) - 5)
        default:
            return nil
        }
        return VolumeModule.read(speakers: speakers)
    }

    static func setLevel(_ percent: Double) {
        guard let device = defaultOutputDevice() else { return }
        var value = Float32(min(100, max(0, percent)) / 100)
        var address = AudioObjectPropertyAddress(mSelector: virtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        if !AudioObjectHasProperty(device, &address) {
            // No virtual main volume: set each channel instead.
            for channel in UInt32(1)...UInt32(2) {
                var perChannel = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
                guard AudioObjectHasProperty(device, &perChannel) else { continue }
                AudioObjectSetPropertyData(device, &perChannel, 0, nil,
                                           UInt32(MemoryLayout<Float32>.size), &value)
            }
            return
        }
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &value)
        // Coming off zero should also unmute, or the slider moves and nothing happens.
        if percent > 0 { setMuted(false) }
    }

    static func setMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice() else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// The volume and mute properties live on the device, so they have to be re-attached when
    /// the default output device changes.
    private func followDeviceChanges() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        registrations.filter { $0.0 != system }.forEach { unlisten($0.0, $0.1) }
        registrations.removeAll { $0.0 != system }

        guard let device = VolumeModule.defaultOutputDevice() else { return }
        // The data source too: on a Mac whose headphone jack is part of the built-in device,
        // plugging in changes the source from speakers to headphones and not the device.
        for selector in [VolumeModule.virtualMainVolume, kAudioDevicePropertyVolumeScalar,
                         kAudioDevicePropertyMute, kAudioDevicePropertyDataSource] {
            listen(to: device, selector: selector, scope: kAudioDevicePropertyScopeOutput)
        }
    }

    private func listen(to object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope) {
        guard let block else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return }
        if AudioObjectAddPropertyListenerBlock(object, &address, nil, block) == noErr {
            registrations.append((object, address))
        }
    }

    private func unlisten(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        guard let block else { return }
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, nil, block)
    }

    private func unlistenAll() {
        registrations.forEach { unlisten($0.0, $0.1) }
        registrations = []
    }

    /// 'vmvc', the virtual main volume: one scalar across however many channels the device has.
    static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)

    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    static func scalar(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Float32? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// A property that is a four-character code, like a transport type or a data source.
    static func code(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func name(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    /// Where the sound goes, in the words a config would use.
    public enum Transport: String, Sendable {
        case builtIn = "built-in", bluetooth, usb, hdmi, displayport, airplay, thunderbolt, virtual,
             aggregate, other

        init(_ code: UInt32?) {
            switch code {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayport
            case kAudioDeviceTransportTypeAirPlay: self = .airplay
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
            default: self = .other
            }
        }
    }

    /// 'hdpn', the built-in device's headphone jack as a data source.
    static let headphoneSource: UInt32 = 0x6864_706E

    /// There is no property that says "headphones", so it is read from what there is: the
    /// built-in jack's data source, Bluetooth (which is headphones far more often than not,
    /// with `speakers` for the exceptions), or a name that says so.
    static func isHeadphones(name: String, transport: Transport, dataSource: UInt32?,
                             speakers: [String] = []) -> Bool {
        if dataSource == headphoneSource { return true }
        if speakers.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return false }
        if transport == .bluetooth { return true }
        return ["headphone", "headset", "airpods", "buds"].contains { name.localizedCaseInsensitiveContains($0) }
    }

    static func read(speakers: [String] = []) -> JSONValue {
        guard let device = defaultOutputDevice() else {
            return .object(["present": .bool(false), "icon": .string("speaker.slash")])
        }
        // The virtual main volume where the device has one, else the left channel.
        let volume = scalar(device, virtualMainVolume)
            ?? scalar(device, kAudioDevicePropertyVolumeScalar, element: 1)
            ?? 0

        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) {
            _ = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &muted)
        }

        let level = Double(volume) * 100
        let name = self.name(device) ?? ""
        let transport = Transport(code(device, kAudioDevicePropertyTransportType))
        let headphones = isHeadphones(name: name, transport: transport,
                                      dataSource: code(device, kAudioDevicePropertyDataSource,
                                                       scope: kAudioDevicePropertyScopeOutput),
                                      speakers: speakers)
        let speakerIcon = Symbols.volume(level: level, muted: muted != 0)
        return .object([
            "present": .bool(true),
            "level": .number(level.rounded()),
            "fraction": .number((level / 100 * 1000).rounded() / 1000),
            "muted": .bool(muted != 0),
            "device": .string(name),
            "transport": .string(transport.rawValue),
            "headphones": .bool(headphones),
            "icon": .string(headphones ? Symbols.headphones(name: name, muted: muted != 0) : speakerIcon),
            // The level as waves whatever the device, for a format that wants both.
            "level-icon": .string(speakerIcon),
        ])
    }
}

/// Lets a C callback call back into Swift without capturing.
final class CallbackBox {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func run() { body() }
}
