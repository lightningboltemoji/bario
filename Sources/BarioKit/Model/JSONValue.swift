import Foundation

/// The one data type the whole system speaks: state patches over the socket, state in the
/// store, config payloads for modules, and the parts of a content tree that stay untyped
/// (canvas display lists, custom node payloads).
///
/// Numbers are Doubles, but an integral one re-encodes as an integer, so `bario set battery
/// '{"pct": 43}'` followed by `bario get battery` prints `43` and not `43.0`.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Reading

extension JSONValue {
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return ["true", "yes", "on", "1"].contains(s.lowercased()) ? true
                                  : ["false", "no", "off", "0"].contains(s.lowercased()) ? false : nil
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var intValue: Int? {
        guard let d = doubleValue, d.isFinite, d >= -9.007e15, d <= 9.007e15 else { return nil }
        return Int(d)
    }

    /// The value as text. Numbers, bools and strings all have one; containers do not, so a
    /// format string that names a container slot leaves it empty rather than printing JSON.
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 9.007e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }

    /// Dotted path lookup: `store.value(at: "battery.pct")`. An empty path is the whole value.
    public func value(at path: String) -> JSONValue? {
        var current: JSONValue? = self
        for part in JSONValue.split(path) {
            guard let here = current, case .object(let o) = here else { return nil }
            current = o[part]
        }
        return current
    }

    static func split(_ path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
    }
}

// MARK: - Writing

extension JSONValue {
    /// Deep merge, the semantics of the socket's `set` op and of a module's state patch:
    /// objects merge key by key, everything else replaces wholesale, and an explicit `null`
    /// in `patch` deletes the key it lands on.
    public func merging(_ patch: JSONValue) -> JSONValue {
        guard case .object(var mine) = self, case .object(let theirs) = patch else { return patch }
        for (key, value) in theirs {
            if value.isNull {
                mine.removeValue(forKey: key)
            } else if let existing = mine[key] {
                mine[key] = existing.merging(value)
            } else {
                mine[key] = value
            }
        }
        return .object(mine)
    }

    /// Merge `patch` in at a dotted path, creating intermediate objects on the way down.
    public func merging(_ patch: JSONValue, at path: String) -> JSONValue {
        let parts = JSONValue.split(path)
        guard !parts.isEmpty else { return merging(patch) }
        return merging(JSONValue.nest(parts, patch))
    }

    /// Replace (not merge) the value at a dotted path.
    public func setting(_ path: String, to value: JSONValue) -> JSONValue {
        let parts = JSONValue.split(path)
        guard let head = parts.first else { return value }
        var object = objectValue ?? [:]
        if parts.count == 1 {
            if value.isNull { object.removeValue(forKey: head) } else { object[head] = value }
        } else {
            let rest = parts.dropFirst().joined(separator: ".")
            object[head] = (object[head] ?? .object([:])).setting(rest, to: value)
        }
        return .object(object)
    }

    private static func nest(_ parts: [String], _ leaf: JSONValue) -> JSONValue {
        parts.reversed().reduce(leaf) { inner, key in .object([key: inner]) }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Keep integers looking like integers on the way out.
            if n == n.rounded(), abs(n) < 9.007e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Literals and bridging

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}
extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue {
    public init(_ data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public init(parsing text: String) throws {
        self = try JSONValue(Data(text.utf8))
    }

    public func encoded(pretty: Bool = false, sortKeys: Bool = false) -> Data {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = pretty ? [.prettyPrinted] : []
        if sortKeys { formatting.insert(.sortedKeys) }
        encoder.outputFormatting = formatting
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var jsonText: String { String(decoding: encoded(), as: UTF8.self) }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonText }
}
