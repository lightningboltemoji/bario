import Foundation

/// A pseudo-class, i.e. a state the scene tree can be in.
public enum StyleState: String, Sendable, Hashable, CaseIterable {
    case hover, active, overflow, stale, error
    case firstChild = "first-child"
    case lastChild = "last-child"
    case onlyChild = "only-child"
    case empty
}

/// One compound selector: everything that must be true of a single node.
public struct SelectorPart: Sendable, Hashable {
    /// nil means `*`.
    public var type: String?
    public var id: String?
    public var classes: [String] = []
    public var states: [StyleState] = []

    public init(type: String? = nil, id: String? = nil, classes: [String] = [], states: [StyleState] = []) {
        self.type = type
        self.id = id
        self.classes = classes
        self.states = states
    }
}

/// A full selector: a chain of compound parts joined by the descendant combinator, the only
/// combinator in the grammar. `#battery .pct` is `[#battery, .pct]`.
public struct Selector: Sendable, Hashable {
    public var parts: [SelectorPart]
    public var position: CSSPosition

    public init(parts: [SelectorPart], position: CSSPosition = .start) {
        self.parts = parts
        self.position = position
    }

    /// CSS specificity: ids, then classes and pseudo-classes, then types.
    public var specificity: Specificity {
        var s = Specificity(ids: 0, classes: 0, types: 0)
        for part in parts {
            if part.id != nil { s.ids += 1 }
            s.classes += part.classes.count + part.states.count
            if part.type != nil { s.types += 1 }
        }
        return s
    }
}

public struct Specificity: Sendable, Hashable, Comparable {
    public var ids: Int
    public var classes: Int
    public var types: Int

    public static func < (a: Specificity, b: Specificity) -> Bool {
        (a.ids, a.classes, a.types) < (b.ids, b.classes, b.types)
    }
}

// MARK: - What a selector matches against

/// One node in the scene, reduced to what selectors care about.
public struct StyleNode: Sendable, Hashable {
    public var type: String
    public var id: String?
    public var classes: Set<String>
    public var states: Set<StyleState>

    public init(type: String, id: String? = nil, classes: Set<String> = [], states: Set<StyleState> = []) {
        self.type = type
        self.id = id
        self.classes = classes
        self.states = states
    }

    /// `:root` is an alias for the bar, so variables defined there inherit everywhere.
    var matchesRoot: Bool { type == "bar" }
}

extension SelectorPart {
    public func matches(_ node: StyleNode) -> Bool {
        if let type, type != "*" {
            if type == ":root" {
                guard node.matchesRoot else { return false }
            } else if type != node.type {
                return false
            }
        }
        if let id, id != node.id { return false }
        for name in classes where !node.classes.contains(name) { return false }
        for state in states where !node.states.contains(state) { return false }
        return true
    }
}

extension Selector {
    /// `path` runs root-first and ends at the node being matched.
    public func matches(_ path: [StyleNode]) -> Bool {
        guard let last = parts.last, let node = path.last, last.matches(node) else { return false }
        var remaining = parts.dropLast()
        var ancestors = path.dropLast()
        // Descendant combinators only, so a greedy walk from the right is exact.
        while let part = remaining.last {
            var matched = false
            while let ancestor = ancestors.last {
                ancestors = ancestors.dropLast()
                if part.matches(ancestor) { matched = true; break }
            }
            guard matched else { return false }
            remaining = remaining.dropLast()
        }
        return true
    }
}

// MARK: - Parsing

enum SelectorParser {
    static func parseList(_ text: String, at position: CSSPosition) throws -> [Selector] {
        var selectors: [Selector] = []
        for piece in text.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = piece.trimmed
            guard !trimmed.isEmpty else {
                throw CSSError("empty selector in the list '\(text.trimmed)'", at: position)
            }
            selectors.append(try parse(trimmed, at: position))
        }
        guard !selectors.isEmpty else {
            throw CSSError("expected a selector", at: position)
        }
        return selectors
    }

    static func parse(_ text: String, at position: CSSPosition) throws -> Selector {
        if text.contains(">") || text.contains("+") || text.contains("~") {
            throw CSSError("the only combinator is descendant (a space); found '\(text)'", at: position)
        }
        var parts: [SelectorPart] = []
        for word in text.split(whereSeparator: \.isWhitespace) {
            parts.append(try parsePart(String(word), at: position))
        }
        guard !parts.isEmpty else { throw CSSError("expected a selector", at: position) }
        return Selector(parts: parts, position: position)
    }

    private static func parsePart(_ text: String, at position: CSSPosition) throws -> SelectorPart {
        var part = SelectorPart()
        var characters = Array(text)[...]

        func take(while predicate: (Character) -> Bool) -> String {
            var out = ""
            while let c = characters.first, predicate(c) { out.append(c); characters = characters.dropFirst() }
            return out
        }
        func name(after symbol: String) throws -> String {
            let word = take { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            guard !word.isEmpty else {
                throw CSSError("expected a name after '\(symbol)' in '\(text)'", at: position)
            }
            return word
        }

        // A leading type, `*`, or `:root`.
        if characters.first == "*" {
            characters = characters.dropFirst()
            part.type = "*"
        } else if text.hasPrefix(":root") {
            characters = characters.dropFirst(5)
            part.type = ":root"
        } else if let c = characters.first, c.isLetter {
            part.type = take { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }

        while let c = characters.first {
            switch c {
            case "#":
                characters = characters.dropFirst()
                part.id = try name(after: "#")
            case ".":
                characters = characters.dropFirst()
                part.classes.append(try name(after: "."))
            case ":":
                characters = characters.dropFirst()
                if characters.first == ":" {
                    throw CSSError("there are no pseudo-elements in bario's stylesheet; found '\(text)'",
                                   at: position)
                }
                let word = try name(after: ":")
                guard let state = StyleState(rawValue: word) else {
                    let known = StyleState.allCases.map { ":\($0.rawValue)" }.joined(separator: ", ")
                    throw CSSError("unknown pseudo-class ':\(word)'; the ones that exist are \(known)",
                                   at: position)
                }
                part.states.append(state)
            case "[":
                throw CSSError("there are no attribute selectors in bario's stylesheet; found '\(text)'",
                               at: position)
            default:
                throw CSSError("unexpected '\(c)' in the selector '\(text)'", at: position)
            }
        }
        return part
    }
}

extension Substring {
    var trimmed: String { String(self).trimmingCharacters(in: .whitespacesAndNewlines) }
}
