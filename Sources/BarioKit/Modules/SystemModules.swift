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

    /// The menu bario shows for the battery when the config has none. Copy it into an item's
    /// `menu { … }` to change it.
    public static let defaultMenuKDL = """
    row class="title" { text "Battery"; spacer; text "{pct}%" class="value" }
    row { text "Power source"; spacer; text "{source}" class="value" }
    if "time" { row { text "{time-label}"; spacer; text "{time}" class="value" } }
    if "health" { row { text "Condition"; spacer; text "{health}" class="value" } }
    separator
    row on-click="exec open 'x-apple.systempreferences:com.apple.Battery-Settings.extension'" { text "Battery Settings…" }
    """

    private static let defaultMenu = MenuConfig.builtIn(defaultMenuKDL, for: "battery")

    public func menu(_ state: StateReader) async throws -> Node? {
        guard state.value("present")?.boolValue == true else { return nil }
        return try BatteryModule.defaultMenu?.render(state)
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
            "source": .string(plugged ? "Power adapter" : "Battery"),
            "time-label": .string(charging ? "Until full" : plugged ? "Time to full" : "Remaining"),
            "health": (description[kIOPSBatteryHealthKey] as? String).map(JSONValue.string) ?? .null,
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
    /// The `CallbackBox` every listener is registered with, nil once stopped. Listeners are
    /// registered as a proc and this pointer rather than as a block: CoreAudio never matches a
    /// Swift block on removal, so a removed block kept firing and every re-registration added
    /// one more. The box is never released, so a callback already under way when `stop`
    /// removes it still has something to call.
    private var listener: UnsafeMutableRawPointer?
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    /// The device whose properties are being listened to.
    private var followed: AudioDeviceID?
    /// A burst of changes, like a volume key held down, is one read at a time: a change that
    /// lands mid-read asks for one more after it, and the last read is the one that stays.
    private var reading = false
    private var readAgain = false

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
        listener = Unmanaged.passRetained(CallbackBox { [weak self] in
            Task { await self?.changed() }
        }).toOpaque()
        // The default output, and for the menu, the default input and the list of devices.
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDevices] {
            listen(to: AudioObjectID(kAudioObjectSystemObject), selector: selector,
                   scope: kAudioObjectPropertyScopeGlobal)
        }
        followDeviceChanges()
    }

    public func stop() async {
        unlistenAll()
        listener = nil
    }

    /// What every listener calls, for the default device and for its properties alike.
    private func changed() async {
        guard listener != nil else { return }
        if reading {
            readAgain = true
            return
        }
        reading = true
        repeat {
            readAgain = false
            followDeviceChanges()
            await context.store.merge(VolumeModule.read(speakers: speakers), at: context.item)
        } while readAgain && listener != nil
        reading = false
    }

    public func poll() async -> PollResult {
        // A safety net rather than a heartbeat: the listeners do the work.
        PollResult(patch: VolumeModule.read(speakers: speakers), nextIn: nil)
    }

    /// The menu bario shows for volume when the config has none: the level as a slider, and
    /// every output and input, the chosen one checked. Copy it into an item's `menu { … }` to
    /// change it.
    public static let defaultMenuKDL = """
    row class="title" { text "Sound"; spacer; text "{device}" class="value" }
    row { icon "{level-icon}" class="glyph"; slider value="{fraction}" on-change="set-level" }
    if "outputs" {
      separator
      row class="header" { text "Output" }
      each "outputs" {
        row class="device {state}" on-click="output {id}" keep-open=#true {
          icon "checkmark" class="check"; text "{name}"
        }
      }
    }
    if "inputs" {
      separator
      row class="header" { text "Input" }
      each "inputs" {
        row class="device {state}" on-click="input {id}" keep-open=#true {
          icon "checkmark" class="check"; text "{name}"
        }
      }
    }
    separator
    row on-click="exec open 'x-apple.systempreferences:com.apple.Sound-Settings.extension'" { text "Sound Settings…" }
    """

    private static let defaultMenu = MenuConfig.builtIn(defaultMenuKDL, for: "volume")

    public func menu(_ state: StateReader) async throws -> Node? {
        try VolumeModule.defaultMenu?.render(state)
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
        case "set-level", "set":
            // A slider's `value` is 0…1; `set 40` and `set-level 40` are percent.
            if let value = event.payload["value"]?.doubleValue {
                VolumeModule.setLevel(value * 100)
            } else if let percent = event.payload["args"]?.arrayValue?.first?.stringValue.flatMap(Double.init) {
                VolumeModule.setLevel(percent)
            }
        case "output", "input":
            guard let uid = event.payload["args"]?.arrayValue?.first?.stringValue ?? event.payload["id"]?.stringValue,
                  let device = VolumeModule.device(uid: uid) else { return nil }
            VolumeModule.setDefault(device, input: event.name == "input")
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
    /// the default output device changes, and only then.
    private func followDeviceChanges() {
        let device = VolumeModule.defaultOutputDevice()
        guard device != followed else { return }
        followed = device

        let system = AudioObjectID(kAudioObjectSystemObject)
        registrations.filter { $0.0 != system }.forEach { unlisten($0.0, $0.1) }
        registrations.removeAll { $0.0 != system }

        guard let device else { return }
        // The data source too: on a Mac whose headphone jack is part of the built-in device,
        // plugging in changes the source from speakers to headphones and not the device.
        for selector in [VolumeModule.virtualMainVolume, kAudioDevicePropertyVolumeScalar,
                         kAudioDevicePropertyMute, kAudioDevicePropertyDataSource] {
            listen(to: device, selector: selector, scope: kAudioDevicePropertyScopeOutput)
        }
    }

    private func listen(to object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope) {
        guard let listener else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return }
        if AudioObjectAddPropertyListener(object, &address, VolumeModule.proc, listener) == noErr {
            registrations.append((object, address))
        }
    }

    private func unlisten(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        guard let listener else { return }
        var address = address
        AudioObjectRemovePropertyListener(object, &address, VolumeModule.proc, listener)
    }

    /// Called on CoreAudio's own thread, so it only hands the change on.
    private static let proc: AudioObjectPropertyListenerProc = { _, _, _, box in
        if let box { Unmanaged<CallbackBox>.fromOpaque(box).takeUnretainedValue().run() }
        return noErr
    }

    private func unlistenAll() {
        registrations.forEach { unlisten($0.0, $0.1) }
        registrations = []
    }

    /// 'vmvc', the virtual main volume: one scalar across however many channels the device has.
    static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)

    static func defaultOutputDevice() -> AudioDeviceID? { defaultDevice(input: false) }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                                                                  : kAudioHardwarePropertyDefaultOutputDevice,
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

    /// Every device with channels that way, in CoreAudio's order: what a menu lists.
    static func devices(input: Bool) -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { channels($0, input: input) > 0 }
    }

    static func channels(_ device: AudioDeviceID, input: Bool) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: input ? kAudioDevicePropertyScopeInput
                                                               : kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// A device's UID, which unlike its ID is the same from one boot to the next.
    static func uid(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    static func device(uid: String) -> AudioDeviceID? {
        (devices(input: false) + devices(input: true)).first { self.uid($0) == uid }
    }

    static func setDefault(_ device: AudioDeviceID, input: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                                                                  : kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = device
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    /// One way's devices as a menu lists them: `id` (the UID), `name`, and `state`, which is
    /// `selected` on the default one, a class for the stylesheet.
    static func list(input: Bool) -> JSONValue {
        let chosen = defaultDevice(input: input)
        return .array(devices(input: input).compactMap { device in
            guard let uid = uid(device), let name = name(device) else { return nil }
            return .object(["id": .string(uid), "name": .string(name),
                            "transport": .string(Transport(code(device, kAudioDevicePropertyTransportType)).rawValue),
                            "state": .string(device == chosen ? "selected" : "")])
        })
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
            "outputs": list(input: false),
            "inputs": list(input: true),
            "input": defaultDevice(input: true).flatMap { self.name($0) }.map(JSONValue.string) ?? .null,
        ])
    }
}

/// Lets a C callback call back into Swift without capturing.
final class CallbackBox {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func run() { body() }
}
