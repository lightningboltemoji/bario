import Foundation

// A KDL 2.0 reader, written here rather than taken as a dependency because the error
// messages are the product: every value keeps the line and column it came from so the config
// layer above can point at it. See .agents/knowledge/02-config-kdl.md for the dialect.

public struct KDLPosition: Sendable, Hashable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static let start = KDLPosition(line: 1, column: 1)
    public var description: String { "\(line):\(column)" }
}

public struct KDLError: Error, CustomStringConvertible {
    public var message: String
    public var position: KDLPosition
    public var source: String?

    public init(_ message: String, at position: KDLPosition, source: String? = nil) {
        self.message = message
        self.position = position
        self.source = source
    }

    public var description: String { "\(source ?? "<config>"):\(position): \(message)" }

    public func naming(_ source: String) -> KDLError {
        KDLError(message, at: position, source: self.source ?? source)
    }
}

public enum KDLValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var doubleValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }

    public var json: JSONValue {
        switch self {
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .null: return .null
        }
    }

    /// How it would be written back into a config file, for error messages.
    public var literal: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "#true" : "#false"
        case .null: return "#null"
        }
    }
}

public struct KDLArgument: Sendable, Hashable {
    public var value: KDLValue
    public var position: KDLPosition
}

public struct KDLProperty: Sendable, Hashable {
    public var name: String
    public var value: KDLValue
    public var position: KDLPosition
}

public struct KDLNode: Sendable, Hashable {
    public var name: String
    public var typeAnnotation: String?
    public var arguments: [KDLArgument]
    public var properties: [KDLProperty]
    public var children: [KDLNode]
    public var position: KDLPosition

    public init(name: String,
                typeAnnotation: String? = nil,
                arguments: [KDLArgument] = [],
                properties: [KDLProperty] = [],
                children: [KDLNode] = [],
                position: KDLPosition = .start) {
        self.name = name
        self.typeAnnotation = typeAnnotation
        self.arguments = arguments
        self.properties = properties
        self.children = children
        self.position = position
    }
}

// MARK: - Reading a parsed node

extension KDLNode {
    /// The last property with this name, KDL's own "later wins" rule.
    public func property(_ name: String) -> KDLProperty? {
        properties.last { $0.name == name }
    }

    public func argument(_ index: Int) -> KDLArgument? {
        index < arguments.count ? arguments[index] : nil
    }

    public func children(named name: String) -> [KDLNode] {
        children.filter { $0.name == name }
    }

    public func child(named name: String) -> KDLNode? {
        children.last { $0.name == name }
    }

    /// The canonical KDL → JSON mapping, which is how every module receives its options.
    /// Properties and children become object keys; arguments become `args`, unless the node
    /// is nothing but arguments, in which case it simplifies to the value or to an array.
    public var json: JSONValue {
        if properties.isEmpty && children.isEmpty {
            switch arguments.count {
            case 0: return .object([:])
            case 1: return arguments[0].value.json
            default: return .array(arguments.map(\.value.json))
            }
        }
        var object: [String: JSONValue] = [:]
        if !arguments.isEmpty { object["args"] = .array(arguments.map(\.value.json)) }
        for property in properties { object[property.name] = property.value.json }
        for child in children {
            let value = child.json
            if let existing = object[child.name] {
                if case .array(var list) = existing, children(named: child.name).count > 1 {
                    list.append(value)
                    object[child.name] = .array(list)
                } else {
                    object[child.name] = .array([existing, value])
                }
            } else {
                object[child.name] = value
            }
        }
        return .object(object)
    }
}

// MARK: - Lexer

private enum KDLToken: Sendable, Equatable {
    case word(String)           // a bare identifier: a node name, a property key, or a string
    case value(KDLValue)        // a quoted string, a number, or a #keyword
    case equals
    case braceOpen
    case braceClose
    case parenOpen
    case parenClose
    case semicolon
    case newline
    case slashdash
    case eof
}

private struct KDLLexeme {
    var token: KDLToken
    var position: KDLPosition
}

private struct KDLLexer {
    let characters: [Character]
    var index = 0
    var line = 1
    var column = 1

    init(_ text: String) {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        characters = Array(text)
    }

    var position: KDLPosition { KDLPosition(line: line, column: column) }
    var isAtEnd: Bool { index >= characters.count }

    func peek(_ offset: Int = 0) -> Character? {
        let at = index + offset
        return at < characters.count ? characters[at] : nil
    }

    mutating func advance() -> Character? {
        guard index < characters.count else { return nil }
        let c = characters[index]
        index += 1
        if c.isKDLNewline { line += 1; column = 1 } else { column += 1 }
        return c
    }

    mutating func match(_ string: String) -> Bool {
        let chars = Array(string)
        guard index + chars.count <= characters.count else { return false }
        for (offset, c) in chars.enumerated() where characters[index + offset] != c { return false }
        for _ in chars { _ = advance() }
        return true
    }

    mutating func tokenize() throws -> [KDLLexeme] {
        var out: [KDLLexeme] = []
        while true {
            try skipInsignificant()
            let start = position
            guard let c = peek() else {
                out.append(KDLLexeme(token: .eof, position: start))
                return out
            }
            switch c {
            case "{": _ = advance(); out.append(KDLLexeme(token: .braceOpen, position: start))
            case "}": _ = advance(); out.append(KDLLexeme(token: .braceClose, position: start))
            case "(": _ = advance(); out.append(KDLLexeme(token: .parenOpen, position: start))
            case ")": _ = advance(); out.append(KDLLexeme(token: .parenClose, position: start))
            case ";": _ = advance(); out.append(KDLLexeme(token: .semicolon, position: start))
            case "=": _ = advance(); out.append(KDLLexeme(token: .equals, position: start))
            case let c where c.isKDLNewline:
                _ = advance()
                out.append(KDLLexeme(token: .newline, position: start))
            case "/" where peek(1) == "-":
                _ = advance(); _ = advance()
                out.append(KDLLexeme(token: .slashdash, position: start))
            case "\"":
                out.append(KDLLexeme(token: .value(.string(try quotedString())), position: start))
            case "#":
                out.append(KDLLexeme(token: try hashToken(), position: start))
            case "r" where peek(1) == "\"" || (peek(1) == "#" && countingRawHashes()):
                // KDL 1.0 raw strings, still in the wild and unambiguous here.
                _ = advance()
                var hashes = 0
                while peek() == "#" { _ = advance(); hashes += 1 }
                out.append(KDLLexeme(token: .value(.string(try rawString(hashes: hashes))), position: start))
            default:
                out.append(KDLLexeme(token: try bareToken(), position: start))
            }
        }
    }

    private func countingRawHashes() -> Bool {
        var offset = 1
        while peek(offset) == "#" { offset += 1 }
        return offset > 1 && peek(offset) == "\""
    }

    /// Whitespace, comments and escaped line breaks, none of which reach the parser.
    private mutating func skipInsignificant() throws {
        while let c = peek() {
            if c.isKDLSpace {
                _ = advance()
            } else if c == "/" , peek(1) == "/" {
                while let c = peek(), !c.isKDLNewline { _ = advance() }
            } else if c == "/", peek(1) == "*" {
                try skipBlockComment()
            } else if c == "\\" {
                // Line continuation: the escape, then anything up to and including a newline.
                _ = advance()
                while let c = peek(), c.isKDLSpace { _ = advance() }
                if peek() == "/" , peek(1) == "/" {
                    while let c = peek(), !c.isKDLNewline { _ = advance() }
                }
                if let c = peek(), c.isKDLNewline { _ = advance() }
            } else {
                return
            }
        }
    }

    private mutating func skipBlockComment() throws {
        let start = position
        var depth = 0
        while true {
            if match("/*") { depth += 1 }
            else if match("*/") {
                depth -= 1
                if depth == 0 { return }
            } else if advance() == nil {
                throw KDLError("unterminated /* comment", at: start)
            }
        }
    }

    private mutating func hashToken() throws -> KDLToken {
        // Either a #keyword or a raw string opener.
        var hashes = 0
        let start = position
        while peek() == "#" { _ = advance(); hashes += 1 }
        if peek() == "\"" { return .value(.string(try rawString(hashes: hashes))) }
        guard hashes == 1 else { throw KDLError("expected a raw string after ###", at: start) }

        var word = ""
        while let c = peek(), c.isKDLBare { word.append(advance()!) }
        switch word {
        case "true": return .value(.bool(true))
        case "false": return .value(.bool(false))
        case "null": return .value(.null)
        case "inf": return .value(.number(.infinity))
        case "-inf": return .value(.number(-.infinity))
        case "nan": return .value(.number(.nan))
        default:
            throw KDLError("unknown keyword #\(word); the keywords are #true, #false, #null, #inf, #-inf and #nan",
                           at: start)
        }
    }

    private mutating func bareToken() throws -> KDLToken {
        let start = position
        var word = ""
        while let c = peek(), c.isKDLBare { word.append(advance()!) }
        guard !word.isEmpty else {
            let c = peek().map(String.init) ?? "end of file"
            _ = advance()
            throw KDLError("unexpected \(c)", at: start)
        }
        if let number = try KDLLexer.number(word, at: start) { return .value(.number(number)) }
        // The documented deviation: KDL 2.0 reserves these bare, but DESIGN.md's example
        // config writes `hidden-until-set=true`, so they keep their v1 meaning here.
        switch word {
        case "true": return .value(.bool(true))
        case "false": return .value(.bool(false))
        case "null": return .value(.null)
        default: break
        }
        if word == "-" || word == "+" { return .word(word) }
        return .word(word)
    }

    /// Returns nil when the word is not number-shaped at all; throws when it is but is malformed.
    private static func number(_ word: String, at position: KDLPosition) throws -> Double? {
        var body = Substring(word)
        var sign = 1.0
        if body.hasPrefix("-") { sign = -1; body = body.dropFirst() }
        else if body.hasPrefix("+") { body = body.dropFirst() }
        guard let first = body.first, first.isNumber else { return nil }

        let digits = body.replacingOccurrences(of: "_", with: "")
        func radix(_ prefix: String, _ base: Int, _ name: String) throws -> Double? {
            guard digits.hasPrefix(prefix) else { return nil }
            let rest = String(digits.dropFirst(prefix.count))
            guard !rest.isEmpty, let value = UInt64(rest, radix: base) else {
                throw KDLError("'\(word)' is not a valid \(name) number", at: position)
            }
            return sign * Double(value)
        }
        if let v = try radix("0x", 16, "hexadecimal") { return v }
        if let v = try radix("0o", 8, "octal") { return v }
        if let v = try radix("0b", 2, "binary") { return v }
        guard let value = Double(digits) else {
            throw KDLError("'\(word)' starts like a number but is not one", at: position)
        }
        return sign * value
    }

    private mutating func rawString(hashes: Int) throws -> String {
        let start = position
        let closing = "\"" + String(repeating: "#", count: hashes)
        if match("\"\"\"") {
            var body = ""
            let terminator = "\"\"\"" + String(repeating: "#", count: hashes)
            while !match(terminator) {
                guard let c = advance() else { throw KDLError("unterminated raw string", at: start) }
                body.append(c)
            }
            return KDLLexer.dedent(body, at: start)
        }
        guard advance() == "\"" else { throw KDLError("expected a raw string", at: start) }
        var body = ""
        while !match(closing) {
            guard let c = advance() else { throw KDLError("unterminated raw string", at: start) }
            body.append(c)
        }
        return body
    }

    private mutating func quotedString() throws -> String {
        let start = position
        if match("\"\"\"") {
            var body = ""
            while !match("\"\"\"") {
                guard let c = peek() else { throw KDLError("unterminated multi-line string", at: start) }
                if c == "\\" { body.append(contentsOf: try escape()) } else { body.append(advance()!) }
            }
            return KDLLexer.dedent(body, at: start)
        }
        guard advance() == "\"" else { throw KDLError("expected a string", at: start) }
        var body = ""
        while true {
            guard let c = peek() else { throw KDLError("unterminated string", at: start) }
            if c == "\"" { _ = advance(); return body }
            if c.isKDLNewline { throw KDLError("a string cannot span lines; use \"\"\" for a multi-line string", at: start) }
            if c == "\\" { body.append(contentsOf: try escape()) } else { body.append(advance()!) }
        }
    }

    private mutating func escape() throws -> String {
        let start = position
        _ = advance()                                   // the backslash
        guard let c = advance() else { throw KDLError("unterminated escape", at: start) }
        switch c {
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "b": return "\u{8}"
        case "f": return "\u{C}"
        case "s": return " "
        case "\\": return "\\"
        case "\"": return "\""
        case "u":
            guard advance() == "{" else { throw KDLError("\\u needs braces: \\u{1F4A1}", at: start) }
            var hex = ""
            while let c = peek(), c != "}" { hex.append(advance()!) }
            guard advance() == "}", let scalar = UInt32(hex, radix: 16), let value = Unicode.Scalar(scalar) else {
                throw KDLError("\\u{\(hex)} is not a Unicode scalar", at: start)
            }
            return String(Character(value))
        case let c where c.isKDLSpace || c.isKDLNewline:
            // Escaped whitespace: swallow it all, so a long string can be wrapped.
            while let c = peek(), c.isKDLSpace || c.isKDLNewline { _ = advance() }
            return ""
        default:
            throw KDLError("unknown escape \\\(c)", at: start)
        }
    }

    /// A multi-line string is written indented; the closing line's indentation is the margin.
    private static func dedent(_ body: String, at position: KDLPosition) -> String {
        var lines = body.components(separatedBy: "\n")
        guard lines.count >= 2 else { return body }
        let last = lines.removeLast()
        let margin = last.prefix { $0 == " " || $0 == "\t" }
        if !lines.isEmpty, lines[0].trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        let stripped = lines.map { line -> String in
            line.hasPrefix(margin) ? String(line.dropFirst(margin.count)) : line
        }
        return stripped.joined(separator: "\n")
    }
}

extension Character {
    /// KDL whitespace, which excludes line breaks.
    var isKDLSpace: Bool {
        self == " " || self == "\t" || unicodeScalars.first.map {
            [0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
             0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000, 0xFEFF].contains($0.value)
        } ?? false
    }

    var isKDLNewline: Bool {
        self == "\n" || self == "\r" || self == "\u{0B}" || self == "\u{0C}"
            || self == "\u{85}" || self == "\u{2028}" || self == "\u{2029}"
    }

    /// Characters a bare identifier may contain.
    var isKDLBare: Bool {
        if isKDLSpace || isKDLNewline { return false }
        return !"\\/(){};[]\"#=".contains(self)
    }
}

// MARK: - Parser

public enum KDL {
    public static func parse(_ text: String, source: String? = nil) throws -> [KDLNode] {
        var lexer = KDLLexer(text)
        do {
            var parser = KDLParser(lexemes: try lexer.tokenize())
            return try parser.document()
        } catch let error as KDLError {
            throw source.map { error.naming($0) } ?? error
        }
    }

    public static func parse(contentsOf url: URL) throws -> [KDLNode] {
        try parse(String(contentsOf: url, encoding: .utf8), source: url.lastPathComponent)
    }
}

private struct KDLParser {
    let lexemes: [KDLLexeme]
    var index = 0

    var current: KDLToken { lexemes[index].token }
    var position: KDLPosition { lexemes[index].position }

    mutating func advance() { if index < lexemes.count - 1 { index += 1 } }

    mutating func skipNewlines() {
        while current == .newline || current == .semicolon { advance() }
    }

    mutating func document() throws -> [KDLNode] {
        let nodes = try nodeList()
        guard current == .eof else {
            throw KDLError("unexpected \(describe(current))", at: position)
        }
        return nodes
    }

    mutating func nodeList() throws -> [KDLNode] {
        var nodes: [KDLNode] = []
        while true {
            skipNewlines()
            if current == .eof || current == .braceClose { return nodes }
            let commented = current == .slashdash
            if commented { advance(); skipNewlines() }
            let node = try parseNode()
            if !commented { nodes.append(node) }
        }
    }

    mutating func parseNode() throws -> KDLNode {
        let start = position
        let annotation = try typeAnnotation()
        guard let name = nameToken() else {
            throw KDLError("expected a node name, found \(describe(current))", at: position)
        }
        advance()

        var node = KDLNode(name: name, typeAnnotation: annotation, position: start)

        loop: while true {
            switch current {
            case .newline, .semicolon, .eof, .braceClose:
                break loop
            case .braceOpen:
                let opened = position
                advance()
                node.children = try nodeList()
                guard current == .braceClose else {
                    throw KDLError("expected } to close \(name)'s children, opened at \(opened), found \(describe(current))",
                                   at: position)
                }
                advance()
                break loop
            case .slashdash:
                advance()
                if current == .braceOpen {
                    advance()
                    _ = try nodeList()
                    guard current == .braceClose else {
                        throw KDLError("expected } to close the commented-out block", at: position)
                    }
                    advance()
                } else {
                    _ = try entry(of: name)
                }
            default:
                if let entry = try entry(of: name) {
                    switch entry {
                    case .argument(let a): node.arguments.append(a)
                    case .property(let p): node.properties.append(p)
                    }
                }
            }
        }
        return node
    }

    private enum Entry {
        case argument(KDLArgument)
        case property(KDLProperty)
    }

    private mutating func entry(of nodeName: String) throws -> Entry? {
        let start = position
        _ = try typeAnnotation()
        let token = current
        advance()

        if current == .equals {
            advance()
            guard let key = nameOf(token) else {
                throw KDLError("a property name must be a word or a string, found \(describe(token))", at: start)
            }
            _ = try typeAnnotation()
            guard let value = valueOf(current) else {
                throw KDLError("\(nodeName)'s property '\(key)' has no value", at: position)
            }
            advance()
            return .property(KDLProperty(name: key, value: value, position: start))
        }

        guard let value = valueOf(token) else {
            throw KDLError("expected a value in \(nodeName), found \(describe(token))", at: start)
        }
        return .argument(KDLArgument(value: value, position: start))
    }

    private mutating func typeAnnotation() throws -> String? {
        guard current == .parenOpen else { return nil }
        advance()
        guard let name = nameToken() else {
            throw KDLError("expected a type name after (", at: position)
        }
        advance()
        guard current == .parenClose else {
            throw KDLError("expected ) to close the (\(name)) type annotation", at: position)
        }
        advance()
        return name
    }

    private func nameToken() -> String? { nameOf(current) }

    private func nameOf(_ token: KDLToken) -> String? {
        switch token {
        case .word(let w): return w
        case .value(.string(let s)): return s
        default: return nil
        }
    }

    private func valueOf(_ token: KDLToken) -> KDLValue? {
        switch token {
        case .value(let v): return v
        case .word(let w): return .string(w)      // KDL 2.0: a bare word is a string
        default: return nil
        }
    }

    private func describe(_ token: KDLToken) -> String {
        switch token {
        case .word(let w): return "'\(w)'"
        case .value(let v): return v.literal
        case .equals: return "'='"
        case .braceOpen: return "'{'"
        case .braceClose: return "'}'"
        case .parenOpen: return "'('"
        case .parenClose: return "')'"
        case .semicolon: return "';'"
        case .newline: return "end of line"
        case .slashdash: return "'/-'"
        case .eof: return "end of file"
        }
    }
}
