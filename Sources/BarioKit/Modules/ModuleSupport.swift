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

    /// Always `capacity` long, with `null` in front until it fills, so a graph's step never
    /// changes as the history grows and new samples come in at the right from the start.
    public var padded: JSONValue {
        .array(Array(repeating: .null, count: capacity - values.count) + values.map(JSONValue.number))
    }
}

/// The newest `capacity` snapshots of something sampled, oldest first. A window is the newest
/// one against one further back, so the ring is as deep as the longest window.
public struct Ring<Element: Sendable>: Sendable {
    public private(set) var elements: [Element] = []
    public let capacity: Int

    public init(capacity: Int) { self.capacity = max(2, capacity) }

    public mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity { elements.removeFirst(elements.count - capacity) }
    }

    public mutating func removeAll() { elements.removeAll() }

    public var count: Int { elements.count }
    public var latest: Element? { elements.last }

    /// The snapshot `samples` before the newest, or the oldest there is: a window not yet
    /// full reports over what it has.
    public func back(_ samples: Int) -> Element? {
        guard !elements.isEmpty else { return nil }
        return elements[max(0, elements.count - 1 - samples)]
    }

    /// The newest `samples` snapshots, or all of them.
    public func suffix(_ samples: Int) -> ArraySlice<Element> { elements.suffix(samples) }
}

/// How a stats item samples, all of it from config: how often, the windows it reports over,
/// and how much history it keeps. Windows and history are durations, so a different interval
/// changes neither what `1m` means nor how long a graph is.
public struct Sampling: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        /// As written, `5s` or `1m`, which is the suffix of the keys it writes: `load-5s`.
        public var name: String
        public var samples: Int
    }

    public var interval: Double
    public var windows: [Window]
    /// Samples of per-sample history.
    public var history: Int

    /// Snapshots a counter ring needs for the longest window, or the history, whichever is
    /// longer, with one more for the difference.
    public var depth: Int { max(history, windows.map(\.samples).max() ?? 1) + 1 }

    public init(interval: Double, windows: [Window] = [], history: Int = 32) {
        self.interval = interval
        self.windows = windows
        self.history = max(2, history)
    }

    public init(context: ModuleContext, defaultInterval: Double,
                defaultWindows: [String] = []) throws {
        var interval = defaultInterval
        if case .seconds(let seconds)? = context.interval, seconds > 0 { interval = seconds }

        let names = try Sampling.names(context.config["windows"]) ?? defaultWindows
        var windows: [Window] = []
        for name in names {
            guard let seconds = ConfigLoader.parseDuration(name), seconds > 0 else {
                throw ModuleError("windows takes durations like \"5s 1m\"; '\(name)' is not one")
            }
            guard seconds >= interval - 1e-9 else {
                throw ModuleError("window \(name) is shorter than interval \(Sampling.written(interval)), "
                                  + "so it would hold no sample; sample more often or widen the window")
            }
            windows.append(Window(name: name, samples: max(1, Int((seconds / interval).rounded()))))
        }

        var history = 32
        switch context.config["history"] {
        case .number(let samples)?:
            history = Int(samples)
        case .string(let raw)?:
            guard let seconds = ConfigLoader.parseDuration(raw), seconds > 0 else {
                throw ModuleError("history takes a duration like \"60s\" or a number of samples; "
                                  + "'\(raw)' is neither")
            }
            history = Int((seconds / interval).rounded())
        default:
            break
        }
        self.init(interval: interval, windows: windows, history: history)
    }

    /// `"5s 1m"`, `"5s, 1m"`, or a list: `windows "5s" "1m"`.
    private static func names(_ value: JSONValue?) throws -> [String]? {
        switch value {
        case nil, .null?:
            return nil
        case .string(let text)?:
            return text.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        case .number(let seconds)?:
            return [written(seconds)]
        case .array(let items)?:
            return try items.map { item in
                if case .number(let seconds) = item { return written(seconds) }
                if let text = item.stringValue { return text }
                throw ModuleError("windows takes durations like \"5s 1m\"")
            }
        default:
            throw ModuleError("windows takes durations like \"5s 1m\"")
        }
    }

    /// Seconds the way a config would say them.
    static func written(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds == seconds.rounded() { return "\(Int(seconds))s" }
        return "\(seconds)s"
    }
}

public enum Humanise {
    private static let units = ["B", "kB", "MB", "GB", "TB"]

    /// `1.2 MB/s`. A format string cannot scale units, so the module writes the scaled form
    /// alongside the raw number.
    /// `  12 kB/s`: a byte rate right-aligned to the widest one, so a number that changes
    /// every second never changes the width of what shows it. Figure spaces are as wide as a
    /// digit in any font with tabular figures, not only a monospaced one.
    public static func rate(_ value: Double) -> String {
        let text = bytes(value, perSecond: true)
        return String(repeating: "\u{2007}", count: max(0, 8 - text.count)) + text
    }

    public static func bytes(_ value: Double, perSecond: Bool = false) -> String {
        var value = max(0, value)
        var index = 0
        // Scaled by what the number would print as, so 999.7 is "1.0 kB" and not "1000 B".
        while value >= 999.5, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let text = value < 9.95 && index > 0
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

    /// Headphones by what they are, where the name says: AirPods and Beats have symbols of
    /// their own. Muted is the same slash whatever the headphones.
    public static func headphones(name: String, muted: Bool) -> String {
        if muted { return "headphones.slash" }
        let name = name.lowercased()
        if name.contains("airpods max") { return "airpods.max" }
        if name.contains("airpods pro") { return "airpods.pro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        return "headphones"
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
