import AppKit

/// Something the pointer did over the bar. It goes to three places at once: the item's
/// module, socket subscribers, and the item's own `on-click` shortcut. DESIGN.md §8.
public struct BarEvent: Sendable {
    public enum Kind: String, Sendable {
        case click
        case rightClick = "right-click"
        case scroll
        case hover
        case exit
    }

    public var kind: Kind
    public var item: String?
    /// The control in the item under the pointer, by index path in its content (PLAN.md M5).
    public var node: [Int]?
    /// That control's `id`, which is how a socket subscriber tells controls apart.
    public var nodeID: String?
    /// In the cover's coordinates.
    public var point: CGPoint
    /// Relative to the item's frame, which is what a renderer's hit test wants (§9).
    public var local: CGPoint
    public var delta: CGPoint
    public var modifiers: UInt

    public init(kind: Kind, item: String?, point: CGPoint, local: CGPoint = .zero,
                delta: CGPoint = .zero, modifiers: UInt = 0) {
        self.kind = kind
        self.item = item
        self.point = point
        self.local = local
        self.delta = delta
        self.modifiers = modifiers
    }

    public var topic: String { "\(kind.rawValue):\(item ?? "")" }

    public var payload: JSONValue {
        var fields: [String: JSONValue] = [
            "item": item.map(JSONValue.string) ?? .null,
            "x": .number(Double(local.x)),
            "y": .number(Double(local.y)),
            "dx": .number(Double(delta.x)),
            "dy": .number(Double(delta.y)),
            "modifiers": .number(Double(modifiers)),
        ]
        if let node { fields["node"] = nodeID.map(JSONValue.string) ?? .array(node.map { .number(Double($0)) }) }
        return .object(fields)
    }

    public var socketEvent: SocketEvent {
        var fields = payload.objectValue ?? [:]
        fields["target"] = item.map(JSONValue.string) ?? .null
        return SocketEvent(kind: kind.rawValue, topic: topic, fields: fields)
    }
}

/// An `on-click` / `on-scroll` shortcut. A handful of verbs are the host's; anything else is
/// the module's business, which is how `adjust` and `toggle-mute` need no special case here.
public enum Action: Sendable, Equatable {
    case exec(String)
    case emit(String, JSONValue)
    case set(String, JSONValue)
    /// A keyboard shortcut, sent as if typed: `key fn+n` opens Notification Center.
    case key(KeyChord)
    case reload
    /// Open a menu, or close it if it is open: the item's own, or the named item's (PLAN.md M11).
    case menu(String?)
    /// A verb for another item's or a source's module, with its arguments, as that item's own
    /// shortcut would deliver it: `send volume set-level`.
    case send(String, String, JSONValue)
    /// Delivered to the item's module as an event of this name.
    case module(String, JSONValue)

    /// `confined` is for an action a WASM module wrote into its own content: bario's verbs would
    /// let it out of its sandbox, so every verb but `menu` goes back to the module itself, as an
    /// event of that name, for it to do with what its permissions allow.
    public static func parse(_ text: String, confined: Bool = false) -> Action? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let words = Action.split(trimmed)
        guard let verb = words.first else { return nil }
        let rest = Array(words.dropFirst())

        switch verb {
        case "menu":
            guard rest.count <= 1 else { return nil }
            return .menu(rest.first)
        case _ where confined:
            return .module(verb, rest.isEmpty ? .object([:]) : .object(["args": .array(rest.map(JSONValue.string))]))
        case "send":
            guard rest.count >= 2 else { return nil }
            let args = Array(rest.dropFirst(2))
            return .send(rest[0], rest[1], args.isEmpty ? .object([:])
                         : .object(["args": .array(args.map(JSONValue.string))]))
        case "exec":
            // The rest of the line, unsplit, so the shell does the quoting it was given.
            let command = trimmed.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : .exec(command)
        case "emit":
            guard let name = rest.first else { return nil }
            // The payload is the rest of the line, unsplit, so JSON survives the quotes in it.
            let raw = Action.tail(trimmed, after: [verb, name])
            return .emit(name, Action.value(raw))
        case "set":
            guard let target = rest.first else { return nil }
            let raw = Action.tail(trimmed, after: [verb, target])
            guard !raw.isEmpty else { return nil }
            return .set(target, Action.value(raw))
        case "key":
            guard rest.count == 1, let chord = try? KeyChord(parsing: rest[0]) else { return nil }
            return .key(chord)
        case "reload":
            return .reload
        default:
            let payload = rest.isEmpty ? JSONValue.object([:])
                : .object(["args": .array(rest.map(JSONValue.string))])
            return .module(verb, payload)
        }
    }

    /// What is wrong with a shortcut that would otherwise do nothing on every click, for the config
    /// loader to report where it was written. Only `key` has anything to check: `exec` hands its
    /// line to the shell, and a verb bario does not know is the module's.
    public static func validate(_ text: String) throws {
        let words = Action.split(text.trimmingCharacters(in: .whitespaces))
        switch words.first {
        case "key":
            guard words.count == 2 else {
                throw KeyChordError("key takes one chord, like key fn+n")
            }
            _ = try KeyChord(parsing: words[1])
        case "send":
            guard words.count >= 3 else {
                throw ActionError("send takes an item and a verb for its module, like send volume up")
            }
        case "menu":
            guard words.count <= 2 else {
                throw ActionError("menu takes at most the item whose menu it opens, like menu wifi")
            }
        default:
            break
        }
    }

    /// Whatever is left of `text` after the given leading words, with its quoting intact.
    static func tail(_ text: String, after words: [String]) -> String {
        var rest = Substring(text)
        for word in words {
            rest = rest.drop(while: \.isWhitespace)
            // The word as written may have been quoted; skip the run it came from.
            var consumed = 0
            var quote: Character?
            for character in rest {
                consumed += 1
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "'" || character == "\"" {
                    quote = character
                } else if character.isWhitespace {
                    consumed -= 1
                    break
                }
            }
            rest = rest.dropFirst(consumed)
            _ = word
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    static func value(_ raw: String) -> JSONValue {
        guard !raw.isEmpty else { return .object([:]) }
        return (try? JSONValue(parsing: raw)) ?? .string(raw)
    }

    /// Splits on whitespace, honouring single and double quotes so
    /// `exec open -a 'Activity Monitor'` survives.
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// A shortcut that would do nothing on every click, said where it was written.
public struct ActionError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
