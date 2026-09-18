import Foundation

/// The waybar affordance, and the 80% case: `format = "{icon} {pct}%"`. Compiled once,
/// rendered against state. DESIGN.md §2.
public struct FormatString: Sendable, Hashable {
    public struct Slot: Sendable, Hashable {
        public var name: String
        /// `%.1f`, a date pattern like `HH:mm`, or a plain number meaning "truncate to".
        public var spec: String?
    }

    public enum Piece: Sendable, Hashable {
        case literal(String)
        case slot(Slot)
    }

    public var pieces: [Piece]

    public var slots: [Slot] {
        pieces.compactMap { if case .slot(let slot) = $0 { return slot } else { return nil } }
    }

    public var isPlainText: Bool { slots.isEmpty }

    public init(pieces: [Piece]) { self.pieces = pieces }

    // MARK: - Parsing

    public static func parse(_ text: String) throws -> FormatString {
        var pieces: [Piece] = []
        var literal = ""
        var characters = Array(text)[...]

        func flush() {
            if !literal.isEmpty { pieces.append(.literal(literal)); literal = "" }
        }

        while let c = characters.first {
            characters = characters.dropFirst()
            switch c {
            case "{" where characters.first == "{":
                characters = characters.dropFirst()
                literal.append("{")
            case "}" where characters.first == "}":
                characters = characters.dropFirst()
                literal.append("}")
            case "{":
                var body = ""
                var closed = false
                while let c = characters.first {
                    characters = characters.dropFirst()
                    if c == "}" { closed = true; break }
                    body.append(c)
                }
                guard closed else {
                    throw ModuleError("format '\(text)' has a { with no matching }")
                }
                guard !body.isEmpty else {
                    throw ModuleError("format '\(text)' has an empty {}")
                }
                flush()
                let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                pieces.append(.slot(Slot(name: String(parts[0]),
                                         spec: parts.count > 1 ? String(parts[1]) : nil)))
            case "}":
                throw ModuleError("format '\(text)' has a } with no matching {; write }} for a literal one")
            default:
                literal.append(c)
            }
        }
        flush()
        return FormatString(pieces: pieces)
    }

    // MARK: - Rendering

    /// Reads every slot from the item's own state. A slot named `icon` — or one whose spec is
    /// `icon` — becomes an `icon` node, so formats mix icons and text.
    public func render(_ state: StateReader) -> Node? {
        render { state.value($0) }
    }

    public func render(_ lookup: (String) -> JSONValue?) -> Node? {
        var children: [Node] = []
        var pendingLiteral = ""

        func flushLiteral() {
            if !pendingLiteral.isEmpty {
                children.append(.text(pendingLiteral))
                pendingLiteral = ""
            }
        }

        for piece in pieces {
            switch piece {
            case .literal(let text):
                pendingLiteral += text
            case .slot(let slot):
                let value = lookup(slot.name)
                if slot.isIcon {
                    guard let symbol = value?.stringValue, !symbol.isEmpty else { continue }
                    flushLiteral()
                    children.append(Node(NodeKind.symbolOrFile(symbol), classes: [slot.className]))
                } else {
                    let text = FormatString.format(value, spec: slot.spec)
                    guard !text.isEmpty else { continue }
                    flushLiteral()
                    children.append(.text(text, classes: [slot.className]))
                }
            }
        }
        flushLiteral()

        switch children.count {
        case 0: return nil
        case 1: return children[0]
        default: return .row(align: .center, children)
        }
    }

    /// The spec's shape decides what it means: `%…` is a printf format, digits are a maximum
    /// length, anything else is a `DateFormatter` pattern over an epoch or an ISO date.
    public static func format(_ value: JSONValue?, spec: String?) -> String {
        guard let value, !value.isNull else { return "" }
        guard let spec, !spec.isEmpty else { return value.stringValue ?? "" }

        if spec.hasPrefix("%") {
            if let number = value.doubleValue, spec.last.map({ "fgeFGE".contains($0) }) == true {
                return String(format: spec, number)
            }
            if let number = value.intValue, spec.last.map({ "dixXou".contains($0) }) == true {
                return String(format: spec, number)
            }
            return String(format: spec, value.stringValue ?? "")
        }

        if let limit = Int(spec) {
            let text = value.stringValue ?? ""
            guard text.count > limit, limit > 1 else { return text }
            return String(text.prefix(limit - 1)) + "…"
        }

        if let date = value.asDate {
            let formatter = DateFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.dateFormat = spec
            return formatter.string(from: date)
        }
        return value.stringValue ?? ""
    }
}

extension FormatString.Slot {
    var isIcon: Bool {
        spec == "icon" || name == "icon" || name.hasSuffix(".icon") || name.hasSuffix("-icon")
    }

    /// Slots keep their name as a class, so `#battery .pct` works with no extra configuration.
    var className: String {
        name.split(whereSeparator: { $0 == "." || $0 == "-" }).last.map(String.init) ?? name
    }
}

extension JSONValue {
    /// Epoch seconds, or an ISO 8601 string.
    var asDate: Date? {
        if let seconds = doubleValue { return Date(timeIntervalSince1970: seconds) }
        if case .string(let text) = self {
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }
}
