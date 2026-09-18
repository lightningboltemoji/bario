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
        .object([
            "item": item.map(JSONValue.string) ?? .null,
            "x": .number(Double(local.x)),
            "y": .number(Double(local.y)),
            "dx": .number(Double(delta.x)),
            "dy": .number(Double(delta.y)),
            "modifiers": .number(Double(modifiers)),
        ])
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
    case reload
    /// Delivered to the item's module as an event of this name.
    case module(String, JSONValue)

    public static func parse(_ text: String) -> Action? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let words = Action.split(trimmed)
        guard let verb = words.first else { return nil }
        let rest = Array(words.dropFirst())

        switch verb {
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
        case "reload":
            return .reload
        default:
            let payload = rest.isEmpty ? JSONValue.object([:])
                : .object(["args": .array(rest.map(JSONValue.string))])
            return .module(verb, payload)
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
