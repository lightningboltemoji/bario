import Foundation

/// A `content` block with slots in it: a content tree whose strings are format strings,
/// compiled once when the config loads and filled from state on every render.
///
/// ```kdl
/// content {
///   row {
///     graph values="{history}" max=1
///     text "{load:%3.0f}%"
///   }
/// }
/// ```
///
/// A string that is exactly one slot with no spec is replaced by the value itself, so a graph
/// gets its array and a meter its number, and a missing one is empty text; any other string
/// renders as a format does. The filled tree goes through the same decoder a pushed tree does,
/// so a template works for every node kind, a renderer's included.
///
/// Among a container's children, `each "outputs" { … }` repeats what is inside it for every
/// element of the list at that path, reading slots from the element first, and `if "ssid" { … }`
/// (or `if "!ssid"`) keeps what is inside it while the value is truthy (PLAN.md M8). A slot whose
/// name starts with `/` reads from the root of the store rather than the item's state (M9), and
/// one filled into an `on-…` action is single-quoted, so a value is one argument whatever is in
/// it (M10).
public struct ContentTemplate: Sendable, Hashable {
    indirect enum Piece: Sendable, Hashable {
        case literal(JSONValue)
        /// `"{history}"`: the value, whatever its type.
        case value(String)
        case format(FormatString)
        /// An action whose slots are filled quoted.
        case action(FormatString)
        case array([Piece])
        case object([String: Piece])
        /// Children repeated for every element of the list at a path.
        case each(String, [Piece])
        /// Children kept while the value at a path is truthy, or with `!`, while it is not.
        case when(String, [Piece])
    }

    let root: Piece

    public init(_ json: JSONValue) throws {
        root = try ContentTemplate.compile(json)
        switch root {
        case .each, .when:
            throw ModuleError("each and if stand among the children of a row or a column")
        default:
            break
        }
    }

    /// Without a slot anywhere in the tree it is plain content, decoded once from `plain`.
    public var hasSlots: Bool { root.hasSlots }

    /// The tree with its escapes undone, `{{` as `{`: what plain content is.
    public var plain: JSONValue { root.fill { _ in nil } }

    public func render(_ state: StateReader) throws -> Node {
        try render { state.value($0) }
    }

    public func render(_ lookup: (String) -> JSONValue?) throws -> Node {
        let json = root.fill(lookup)
        do {
            return try JSONDecoder().decode(Node.self, from: json.encoded())
        } catch let error as DecodingError {
            throw ModuleError("content: \(error.contentMessage)")
        }
    }

    private static func compile(_ json: JSONValue, key: String? = nil) throws -> Piece {
        switch json {
        case .string(let text) where text.contains("{") || text.contains("}"):
            let format = try FormatString.parse(text)
            // `{{` alone is a literal brace, and stays a literal.
            if format.isPlainText { return .literal(.string(format.string { _ in nil })) }
            if let key, key.hasPrefix("on-") { return .action(format) }
            if format.pieces.count == 1, case .slot(let slot) = format.pieces[0], slot.spec == nil {
                return .value(slot.name)
            }
            return .format(format)
        case .array(let items):
            return .array(try items.map { try compile($0) })
        case .object(let fields):
            if fields.count == 1, let (word, body) = fields.first, word == "each" || word == "if",
               let path = body["path"]?.stringValue {
                let children = try (body["children"]?.arrayValue ?? []).map { try compile($0) }
                return word == "each" ? .each(path, children) : .when(path, children)
            }
            var pieces: [String: Piece] = [:]
            for (name, value) in fields { pieces[name] = try compile(value, key: name) }
            return .object(pieces)
        default:
            return .literal(json)
        }
    }
}

extension ContentTemplate.Piece {
    var hasSlots: Bool {
        switch self {
        case .literal: return false
        case .value, .format, .action, .each, .when: return true
        case .array(let items): return items.contains { $0.hasSlots }
        case .object(let fields): return fields.values.contains { $0.hasSlots }
        }
    }

    func fill(_ lookup: (String) -> JSONValue?) -> JSONValue {
        switch self {
        case .literal(let json): return json
        // Missing is empty, as a missing slot in a format is.
        case .value(let name): return lookup(name).flatMap { $0.isNull ? nil : $0 } ?? .string("")
        case .format(let format): return .string(format.string(lookup))
        case .action(let format): return .string(format.string(lookup, quoted: true))
        case .array(let items): return .array(items.flatMap { $0.expand(lookup) })
        case .object(let fields): return .object(fields.mapValues { $0.fill(lookup) })
        case .each, .when: return .array(expand(lookup))
        }
    }

    /// What this piece is among an array's elements: itself, or for `each` and `if`, however
    /// many elements it comes to.
    func expand(_ lookup: (String) -> JSONValue?) -> [JSONValue] {
        switch self {
        case .each(let path, let children):
            guard let list = lookup(path)?.arrayValue else { return [] }
            return withoutActuallyEscaping(lookup) { outer in
                list.flatMap { element in
                    // The element's own fields first, `{.}` for the element itself, then the item's.
                    let scoped: (String) -> JSONValue? = { name in
                        if name == "." { return element }
                        if element.objectValue != nil, let value = element.value(at: name) { return value }
                        return outer(name)
                    }
                    return children.flatMap { $0.expand(scoped) }
                }
            }
        case .when(let path, let children):
            let negated = path.hasPrefix("!")
            let truthy = lookup(negated ? String(path.dropFirst()) : path)?.isTruthy ?? false
            return truthy != negated ? children.flatMap { $0.expand(lookup) } : []
        default:
            return [fill(lookup)]
        }
    }
}

extension FormatString {
    /// Every piece as text, icons included by name: what a format is inside a string that
    /// is not itself a node, like a `text` node's or a `class`. `quoted` single-quotes what each
    /// slot fills in, as the shell and the action language both read it: one word, whatever is
    /// in it.
    func string(_ lookup: (String) -> JSONValue?, quoted: Bool = false) -> String {
        pieces.map { piece in
            switch piece {
            case .literal(let text): return text
            case .slot(let slot):
                let text = FormatString.format(lookup(slot.name), spec: slot.spec)
                return quoted ? FormatString.shellQuoted(text) : text
            }
        }.joined()
    }

    /// `'it'\''s'`: one word to `/bin/sh` and to `Action.split` alike.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
