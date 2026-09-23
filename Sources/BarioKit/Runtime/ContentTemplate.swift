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
public struct ContentTemplate: Sendable, Hashable {
    indirect enum Piece: Sendable, Hashable {
        case literal(JSONValue)
        /// `"{history}"`: the value, whatever its type.
        case value(String)
        case format(FormatString)
        case array([Piece])
        case object([String: Piece])
    }

    let root: Piece

    public init(_ json: JSONValue) throws {
        root = try ContentTemplate.compile(json)
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

    private static func compile(_ json: JSONValue) throws -> Piece {
        switch json {
        case .string(let text) where text.contains("{") || text.contains("}"):
            let format = try FormatString.parse(text)
            if format.pieces.count == 1, case .slot(let slot) = format.pieces[0], slot.spec == nil {
                return .value(slot.name)
            }
            // `{{` alone is a literal brace, and stays a literal.
            return format.isPlainText ? .literal(.string(format.string { _ in nil })) : .format(format)
        case .array(let items):
            return .array(try items.map(compile))
        case .object(let fields):
            return .object(try fields.mapValues(compile))
        default:
            return .literal(json)
        }
    }
}

extension ContentTemplate.Piece {
    var hasSlots: Bool {
        switch self {
        case .literal: return false
        case .value, .format: return true
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
        case .array(let items): return .array(items.map { $0.fill(lookup) })
        case .object(let fields): return .object(fields.mapValues { $0.fill(lookup) })
        }
    }
}

extension FormatString {
    /// Every piece as text, icons included by name: what a format is inside a string that
    /// is not itself a node, like a `text` node's or a `class`.
    func string(_ lookup: (String) -> JSONValue?) -> String {
        pieces.map { piece in
            switch piece {
            case .literal(let text): return text
            case .slot(let slot): return FormatString.format(lookup(slot.name), spec: slot.spec)
            }
        }.joined()
    }
}
