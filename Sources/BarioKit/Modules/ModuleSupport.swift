import Foundation

/// A fixed-length rolling window, which is what a `{graph}` slot reads.
public struct History: Sendable {
    public private(set) var values: [Double] = []
    public var capacity: Int

    public init(capacity: Int = 32) { self.capacity = max(2, capacity) }

    public mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public var json: JSONValue { .array(values.map(JSONValue.number)) }
    public var peak: Double { values.max() ?? 0 }
}

public enum Humanise {
    private static let units = ["B", "kB", "MB", "GB", "TB"]

    /// `1.2 MB/s`. A format string cannot scale units, so the module writes the scaled form
    /// alongside the raw number.
    public static func bytes(_ value: Double, perSecond: Bool = false) -> String {
        var value = max(0, value)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let text = value < 10 && index > 0
            ? String(format: "%.1f", value)
            : String(format: "%.0f", value)
        return "\(text) \(units[index])\(perSecond ? "/s" : "")"
    }

    /// `3:10`, the shape a battery estimate is always written in.
    public static func duration(minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// Picks an SF Symbol from a value, so `format="{icon}"` works without anyone learning symbol
/// names. One ladder per subject, in one place.
public enum Symbols {
    public static func battery(percent: Double, charging: Bool, plugged: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        if plugged { return "battery.100percent.bolt" }
        switch percent {
        case ..<10: return "battery.0percent"
        case ..<35: return "battery.25percent"
        case ..<60: return "battery.50percent"
        case ..<85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// RSSI in dBm, the usual -30 (excellent) to -90 (unusable) range.
    public static func wifiBars(rssi: Double) -> Int {
        switch rssi {
        case (-55)...: return 3
        case (-67)...: return 2
        case (-80)...: return 1
        default: return 0
        }
    }

    public static func wifi(on: Bool, rssi: Double?) -> String {
        guard on else { return "wifi.slash" }
        guard let rssi else { return "wifi" }
        switch wifiBars(rssi: rssi) {
        case 0: return "wifi.exclamationmark"
        case 1: return "wifi.slash"
        case 2: return "wifi"
        default: return "wifi"
        }
    }

    public static func volume(level: Double, muted: Bool) -> String {
        if muted || level <= 0 { return "speaker.slash.fill" }
        switch level {
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
