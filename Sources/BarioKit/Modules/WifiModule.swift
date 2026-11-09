import CoreLocation
import CoreWLAN
import Foundation
import SystemConfiguration

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
        PollResult(patch: WifiModule.read(wantsSSID: wantsSSID), every: interval)
    }

    /// The menu bario shows for Wi-Fi when the config has none: the network, how good the link
    /// is, the addresses, and what has gone through it since the Mac started. Copy it into an
    /// item's `menu { … }` to change it.
    public static let defaultMenuKDL = """
    row class="title" { icon "{icon}" class="glyph"; text "Wi-Fi"; spacer; text "{interface}" class="value" }
    if "!on" { row class="note" { text "Wi-Fi is off" } }
    if "ssid" { row { text "Network"; spacer; text "{ssid}" class="value" } }
    if "ssid-denied" { row class="note" { text "The network's name needs Location Services for bario" } }
    if "rssi" {
      row { text "Signal"; spacer; text "{rssi} dBm · {quality-pct}%" class="value" }
      row { text "Channel"; spacer; text "{channel} · {band} · {width}" class="value" }
    }
    if "tx-rate" { row { text "Link rate"; spacer; text "{tx-rate} Mbps" class="value" } }
    if "security" { row { text "Security"; spacer; text "{security}" class="value" } }
    if "ip" {
      separator
      row { text "IP address"; spacer; text "{ip}" class="value" }
      if "router" { row { text "Router"; spacer; text "{router}" class="value" } }
    }
    if "received" {
      separator
      row { text "Received"; spacer; text "{received:bytes}" class="value" }
      row { text "Sent"; spacer; text "{sent:bytes}" class="value" }
    }
    separator
    row on-click="exec open 'x-apple.systempreferences:com.apple.wifi-settings-extension'" { text "Wi-Fi Settings…" }
    """

    private static let defaultMenu = MenuConfig.builtIn(defaultMenuKDL, for: "wifi")

    public func menu(_ state: StateReader) async throws -> Node? {
        try WifiModule.defaultMenu?.render(state)
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
            let channel = interface.wlanChannel()
            patch["channel"] = channel.map { .number(Double($0.channelNumber)) } ?? .null
            patch["band"] = channel.map { .string(WifiModule.band($0.channelBand)) } ?? .null
            patch["width"] = channel.map { .string(WifiModule.width($0.channelWidth)) } ?? .null
            // A rough 0…1 for a meter node: -30 dBm is excellent, -90 is unusable.
            let quality = max(0, min(1, (rssi + 90) / 60))
            patch["quality"] = .number(quality)
            patch["quality-pct"] = .number((quality * 100).rounded())
            let rate = interface.transmitRate()
            patch["tx-rate"] = rate > 0 ? .number(rate.rounded()) : .null
            patch["security"] = WifiModule.security(interface.security()).map(JSONValue.string) ?? .null
        } else {
            for key in ["rssi", "channel", "band", "width", "tx-rate", "security"] { patch[key] = .null }
            patch["bars"] = .number(0)
            patch["quality"] = .number(0)
            patch["quality-pct"] = .number(0)
        }

        // What it is on the network, and what has gone through it since the Mac started.
        let name = interface.interfaceName ?? "en0"
        patch["ip"] = WifiModule.address(of: name).map(JSONValue.string) ?? .null
        patch["router"] = WifiModule.router(for: name).map(JSONValue.string) ?? .null
        if let totals = WifiModule.totals(of: name) {
            patch["received"] = .number(Double(totals.rx))
            patch["sent"] = .number(Double(totals.tx))
        }

        // Read whenever macOS will say it, which costs nothing; asked for only when wanted, since
        // asking is a Location Services prompt.
        // A denial is recorded only where the name was asked for.
        if let ssid = interface.ssid() {
            patch["ssid"] = .string(ssid)
            if wantsSSID { patch["ssid-denied"] = .bool(false) }
        } else {
            patch["ssid"] = .null
            // nil from ssid() while the radio is up means the entitlement, not the radio.
            if wantsSSID { patch["ssid-denied"] = .bool(on) }
        }
        return .object(patch)
    }
}

extension WifiModule {
    static func band(_ band: CWChannelBand) -> String {
        switch band {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return "unknown band"
        }
    }

    static func width(_ width: CWChannelWidth) -> String {
        switch width {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        default: return "unknown width"
        }
    }

    static func security(_ security: CWSecurity) -> String? {
        switch security {
        case .none: return "None"
        case .WEP, .dynamicWEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "WPA2/WPA3 Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed: return "WPA Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "WPA2/WPA3 Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .OWE, .oweTransition: return "Enhanced Open"
        default: return nil
        }
    }

    /// The interface's IPv4 address, from `getifaddrs`.
    static func address(of interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == interface,
                  let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return nil
    }

    /// The router, while this interface is the one the Mac routes through.
    static func router(for interface: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "bario" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              value["PrimaryInterface"] as? String == interface else { return nil }
        return value["Router"] as? String
    }

    /// Bytes in and out since the Mac started, in the kernel's 64-bit counters: `getifaddrs`'s
    /// are 32 bits and wrap every 4 GB, which a day's video goes past.
    static func totals(of interface: String) -> (rx: UInt64, tx: UInt64)? {
        let index = Int32(if_nametoindex(interface))
        guard index > 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> (UInt64, UInt64)? in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { return nil }
                if header.ifm_type == RTM_IFINFO2, Int32(header.ifm_index) == index,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    return (message.ifm_data.ifi_ibytes, message.ifm_data.ifi_obytes)
                }
                offset += Int(header.ifm_msglen)
            }
            return nil
        }
    }
}
