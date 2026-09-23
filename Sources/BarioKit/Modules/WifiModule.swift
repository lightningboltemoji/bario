import CoreLocation
import CoreWLAN
import Foundation

/// CoreWLAN. The SSID needs Location Services on macOS 14+ (DESIGN.md §13), so the module is
/// built to be useful without it: signal strength, channel and the on/off state never need
/// permission, and `ssid-denied` lets a config explain the gap instead of showing a blank.
public actor WifiModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    private let interval: Double
    private let wantsSSID: Bool
    private nonisolated(unsafe) static var askedForLocation = false

    public init(context: ModuleContext) {
        self.context = context
        self.renderer = FormatRenderer(context, format: "{icon}", fallback: "ssid")
        if case .seconds(let seconds)? = context.interval { interval = seconds } else { interval = 5 }
        // Only ask for Location Services if the format actually wants an SSID.
        self.wantsSSID = (context.format ?? "").contains("{ssid")
            || context.bool("request-location", default: false)
    }

    public func start() async {
        guard wantsSSID else { return }
        WifiModule.requestLocationOnce()
    }

    public func poll() async -> PollResult {
        PollResult(patch: WifiModule.read(wantsSSID: wantsSSID), nextIn: interval)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        var classes: [String] = []
        if state.value("on")?.boolValue != true { classes.append("off") }
        if state.value("ssid-denied")?.boolValue == true { classes.append("no-location") }
        let tooltip = state.value("ssid")?.stringValue
            ?? (state.value("ssid-denied")?.boolValue == true
                ? "Wi-Fi network names need Location Services (System Settings → Privacy)"
                : nil)
        return RenderResult(content: try renderer.render(state), classes: classes, tooltip: tooltip)
    }

    static func requestLocationOnce() {
        guard !askedForLocation else { return }
        askedForLocation = true
        // Fire and forget: the answer arrives whenever it arrives, and the module never waits.
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    static func read(wantsSSID: Bool) -> JSONValue {
        guard let interface = CWWiFiClient.shared().interface() else {
            return .object(["present": .bool(false), "on": .bool(false),
                            "icon": .string("wifi.slash")])
        }
        let on = interface.powerOn()
        let rssi = Double(interface.rssiValue())
        let hasSignal = on && rssi != 0

        var patch: [String: JSONValue] = [
            "present": .bool(true),
            "on": .bool(on),
            "interface": .string(interface.interfaceName ?? "en0"),
            "icon": .string(Symbols.wifi(on: on, rssi: hasSignal ? rssi : nil)),
        ]
        if hasSignal {
            patch["rssi"] = .number(rssi)
            patch["bars"] = .number(Double(Symbols.wifiBars(rssi: rssi)))
            patch["noise"] = .number(Double(interface.noiseMeasurement()))
            patch["channel"] = interface.wlanChannel().map { .number(Double($0.channelNumber)) } ?? .null
            // A rough 0…1 for a meter node: -30 dBm is excellent, -90 is unusable.
            patch["quality"] = .number(max(0, min(1, (rssi + 90) / 60)))
        } else {
            patch["rssi"] = .null
            patch["bars"] = .number(0)
            patch["quality"] = .number(0)
        }

        if wantsSSID, let ssid = interface.ssid() {
            patch["ssid"] = .string(ssid)
            patch["ssid-denied"] = .bool(false)
        } else if wantsSSID {
            patch["ssid"] = .null
            // nil from ssid() while the radio is up means the entitlement, not the radio.
            patch["ssid-denied"] = .bool(on)
        }
        return .object(patch)
    }
}
