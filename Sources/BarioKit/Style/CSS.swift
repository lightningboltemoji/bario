import Foundation

// The CSS subset: a tokenizer, a generic value AST, and a stylesheet parser. Not a browser
// engine — a fixed property list and a fixed selector grammar, where anything outside the
// grammar is an error with a line number. See .agents/knowledge/03-style-engine.md.

public struct CSSPosition: Sendable, Hashable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static let start = CSSPosition(line: 1, column: 1)
    public var description: String { "\(line):\(column)" }
}

public struct CSSError: Error, CustomStringConvertible {
    public var message: String
    public var position: CSSPosition
    public var source: String?

    public init(_ message: String, at position: CSSPosition, source: String? = nil) {
        self.message = message
        self.position = position
        self.source = source
    }

    public var description: String { "\(source ?? "<style>"):\(position): \(message)" }

    public func naming(_ source: String) -> CSSError {
        CSSError(message, at: position, source: self.source ?? source)
    }
}

// MARK: - The generic value AST

/// One piece of a declaration's value, before any property-specific parser sees it. Keeping
/// this layer is what makes `var()` substitution possible.
public indirect enum CSSComponent: Sendable, Hashable {
    case number(Double, unit: String?)
    case ident(String)
    case string(String)
    case hash(String)
    /// `rgba(0, 0, 0, 0.3)`, `var(--fg, red)`, `blur(20pt)`. Arguments are split on commas.
    /// A bare `( … )`, which `calc()` groups with, is a function with no name.
    case function(String, [[CSSComponent]])
    case comma
    case slash
    /// A `+`, `-` or `*` on its own, as `calc(h + 50)` writes them: `+` and `-` need whitespace
    /// after them, or they start a number.
    case delim(Character)
    /// A colour already computed, which no stylesheet can write: what `wallpaper()` and
    /// `scheme()` become when the cascade substitutes them (PLAN.md W2).
    case color(RGBA)

    public var identValue: String? { if case .ident(let s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case .number(let n, _) = self { return n } else { return nil } }
    public var unit: String? { if case .number(_, let u) = self { return u } else { return nil } }

    public var isComma: Bool { self == .comma }

    /// The functions the cascade replaces before any property parser sees a value.
    public static let substituted: Set<String> = ["var", "wallpaper", "scheme"]
    /// The ones that read the wallpaper's colours, which a bar's first frame waits for.
    public static let fromWallpaper: Set<String> = ["wallpaper", "scheme"]

    /// How it would be written, for error messages.
    public var text: String {
        switch self {
        case .number(let n, let unit):
            let body = n == n.rounded() && abs(n) < 1e12 ? String(Int(n)) : String(n)
            return body + (unit ?? "")
        case .ident(let s): return s
        case .string(let s): return "\"\(s)\""
        case .hash(let s): return "#\(s)"
        case .function(let name, let args):
            return name + "(" + args.map { $0.map(\.text).joined(separator: " ") }.joined(separator: ", ") + ")"
        case .comma: return ","
        case .slash: return "/"
        case .delim(let c): return String(c)
        case .color(let rgba): return rgba.hex
        }
    }
}

extension Array where Element == CSSComponent {
    public var text: String { map(\.text).joined(separator: " ") }

    /// Split a value on top-level commas: `transition: a 1s, b 2s`.
    public func splitOnCommas() -> [[CSSComponent]] {
        var out: [[CSSComponent]] = []
        var current: [CSSComponent] = []
        for component in self {
            if component.isComma {
                out.append(current)
                current = []
            } else {
                current.append(component)
            }
        }
        if !current.isEmpty || !out.isEmpty { out.append(current) }
        return out
    }

    /// Whether the cascade has something to substitute here before a property parser can read
    /// it: a `var()`, or a `wallpaper()` or `scheme()`, which become colours (PLAN.md W2).
    public var needsSubstitution: Bool { mentions(CSSComponent.substituted) }

    /// Whether a function of one of these names appears anywhere, however deep.
    public func mentions(_ functions: Set<String>) -> Bool {
        contains { component in
            if case .function(let name, let args) = component {
                return functions.contains(name) || args.contains { $0.mentions(functions) }
            }
            return false
        }
    }
}

// MARK: - Stylesheet

public struct Declaration: Sendable, Hashable {
    public var property: String
    public var value: [CSSComponent]
    public var important: Bool
    public var position: CSSPosition
}

public struct MediaQuery: Sendable, Hashable {
    public enum Appearance: String, Sendable { case light, dark }
    public var appearance: Appearance

    public func matches(dark: Bool) -> Bool {
        appearance == .dark ? dark : !dark
    }
}

public struct StyleRule: Sendable, Hashable {
    public var selectors: [Selector]
    public var declarations: [Declaration]
    public var media: MediaQuery?
    /// Source order, the cascade's last tie-break.
    public var order: Int
    public var position: CSSPosition
    /// Written inside `@starting-style`: what an item that has just appeared transitions from,
    /// and part of no other cascade.
    public var starting = false
}

/// `@keyframes name { from { … } 40% { … } to { … } }`, as written: declarations are resolved
/// against each node that runs it, so `var()` works inside one.
public struct KeyframesRule: Sendable, Hashable {
    public struct Stop: Sendable, Hashable {
        /// 0…1; `from, 50%` is two.
        public var offsets: [Double]
        public var declarations: [Declaration]
    }

    public var name: String
    public var stops: [Stop]
    public var position: CSSPosition
}

public struct Stylesheet: Sendable, Hashable {
    public var rules: [StyleRule]
    /// By name. A later definition of a name replaces an earlier one, as in CSS.
    public var keyframes: [String: KeyframesRule]
    /// `@scheme` rules by name, "" for the unnamed one. A later one replaces an earlier one, as
    /// `@keyframes` do.
    public var schemes: [String: SchemeRule]

    public init(rules: [StyleRule] = [], keyframes: [String: KeyframesRule] = [:],
                schemes: [String: SchemeRule] = [:]) {
        self.rules = rules
        self.keyframes = keyframes
        self.schemes = schemes
    }

    /// `knownSchemes` are the names of schemes defined in the sheets this one will be layered
    /// over, which `scheme(--name …)` may name as well as its own.
    public static func parse(_ text: String, source: String? = nil,
                             knownSchemes: Set<String> = []) throws -> Stylesheet {
        do {
            var parser = CSSParser(text: text)
            parser.knownSchemes = knownSchemes
            return try parser.stylesheet()
        } catch let error as CSSError {
            throw source.map { error.naming($0) } ?? error
        }
    }

    public static func parse(contentsOf url: URL) throws -> Stylesheet {
        try parse(String(contentsOf: url, encoding: .utf8), source: url.lastPathComponent)
    }

    /// Declarations written inline on one item, `style="color: red"`.
    public static func parseDeclarations(_ text: String, source: String? = nil) throws -> [Declaration] {
        do {
            var parser = CSSParser(text: text)
            return try parser.declarationsToEnd()
        } catch let error as CSSError {
            throw source.map { error.naming($0) } ?? error
        }
    }

    /// Whether anything here is coloured from the wallpaper, so a bar's first frame has a
    /// palette to wait for (PLAN.md W7).
    public var usesWallpaper: Bool {
        rules.contains { $0.declarations.contains { $0.value.mentions(CSSComponent.fromWallpaper) } }
    }

    public func appending(_ other: Stylesheet) -> Stylesheet {
        let offset = (rules.map(\.order).max() ?? -1) + 1
        return Stylesheet(rules: rules + other.rules.map { rule in
            var rule = rule
            rule.order += offset
            return rule
        }, keyframes: keyframes.merging(other.keyframes) { _, later in later },
           schemes: schemes.merging(other.schemes) { _, later in later })
    }
}

// MARK: - Parser

struct CSSParser {
    let characters: [Character]
    var index = 0
    var line = 1
    var column = 1
    var order = 0
    /// Schemes the sheet may name besides its own: those of the sheets it is layered over.
    var knownSchemes: Set<String> = []

    init(text: String) {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        characters = Array(text)
    }

    var position: CSSPosition { CSSPosition(line: line, column: column) }

    func peek(_ offset: Int = 0) -> Character? {
        let at = index + offset
        return at < characters.count ? characters[at] : nil
    }

    @discardableResult
    mutating func advance() -> Character? {
        guard index < characters.count else { return nil }
        let c = characters[index]
        index += 1
        if c == "\n" { line += 1; column = 1 } else { column += 1 }
        return c
    }

    mutating func skipTrivia() throws {
        while let c = peek() {
            if c.isWhitespace {
                advance()
            } else if c == "/", peek(1) == "*" {
                let start = position
                advance(); advance()
                while true {
                    guard let c = advance() else { throw CSSError("unterminated /* comment", at: start) }
                    if c == "*", peek() == "/" { advance(); break }
                }
            } else {
                return
            }
        }
    }

    // MARK: Top level

    mutating func stylesheet() throws -> Stylesheet {
        var sheet = Stylesheet()
        while true {
            try skipTrivia()
            guard let c = peek() else {
                try checkSchemeNames(in: sheet)
                return sheet
            }
            if c == "@" {
                let start = position
                advance()                                       // @
                switch readIdentifier() {
                case "media":
                    sheet.rules.append(contentsOf: try media(at: start))
                case "keyframes":
                    let rule = try keyframes(at: start)
                    sheet.keyframes[rule.name] = rule
                case "starting-style":
                    sheet.rules.append(contentsOf: try startingStyle(at: start))
                case "scheme":
                    let rule = try scheme(at: start)
                    sheet.schemes[rule.name ?? ""] = rule
                case let name:
                    throw CSSError("bario's stylesheet has four at-rules, @media, @keyframes, "
                                   + "@starting-style and @scheme; found @\(name)", at: start)
                }
            } else {
                sheet.rules.append(try rule(media: nil))
            }
        }
    }

    /// `@keyframes spin { to { transform: rotate(360deg) } }`. Only `transform` and `opacity`
    /// may animate this way, because the compositor runs it with no help from bario.
    mutating func keyframes(at start: CSSPosition) throws -> KeyframesRule {
        try skipTrivia()
        let name: String
        if peek() == "\"" || peek() == "'" {
            name = try readString()
        } else {
            name = readIdentifier()
        }
        guard !name.isEmpty else { throw CSSError("@keyframes needs a name", at: position) }
        try skipTrivia()
        guard peek() == "{" else { throw CSSError("expected { after @keyframes \(name)", at: position) }
        advance()
        var rule = KeyframesRule(name: name, stops: [], position: start)
        while true {
            try skipTrivia()
            guard let c = peek() else { throw CSSError("unterminated @keyframes block", at: start) }
            if c == "}" { advance(); break }
            let selector = try readUntilBrace()
            let offsets = try selector.text.split(separator: ",").map { piece -> Double in
                let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                switch text {
                case "from": return 0
                case "to": return 1
                default:
                    guard text.hasSuffix("%"), let value = Double(text.dropLast()), (0...100).contains(value) else {
                        throw CSSError("a keyframe is from, to or a percentage, not '\(text)'",
                                       at: selector.position)
                    }
                    return value / 100
                }
            }
            advance()                                   // {
            let declarations = try declarationBlock()
            for declaration in declarations
            where declaration.property != "transform" && declaration.property != "opacity" {
                throw CSSError("@keyframes animate transform and opacity only, not '\(declaration.property)'",
                               at: declaration.position)
            }
            rule.stops.append(KeyframesRule.Stop(offsets: offsets, declarations: declarations))
        }
        guard !rule.stops.isEmpty else { throw CSSError("@keyframes \(name) has no keyframes", at: start) }
        return rule
    }

    /// `@scheme --pop { seed: accent; harmony: 50deg 180deg; }`: a theme generated from one seed
    /// colour, which `scheme(--pop primary)` names (PLAN.md W12). Its descriptors are checked
    /// here, so a mistake in one is an error on its line.
    mutating func scheme(at start: CSSPosition) throws -> SchemeRule {
        try skipTrivia()
        var rule = SchemeRule.defaults
        rule.position = start
        if peek() == "-" {
            let name = readIdentifier()
            guard name.hasPrefix("--"), name.count > 2 else {
                throw CSSError("an @scheme's name is a custom name, as in @scheme --pop", at: start)
            }
            rule.name = name
            try skipTrivia()
        }
        guard peek() == "{" else {
            throw CSSError("expected { after @scheme\(rule.name.map { " " + $0 } ?? "")", at: position)
        }
        advance()
        for declaration in try declarationBlock(validate: false) {
            let value = declaration.value
            let at = declaration.position
            switch declaration.property {
            case "seed":
                rule.seed = try CSSParser.schemeSeed(value, at: at)
            case "harmony":
                if value.count == 1, let name = value[0].identValue, let harmony = Harmony.names[name] {
                    rule.harmony = harmony
                } else if value.count == 2 {
                    rule.harmony = .angles(try CSSValue.angle([value[0]], at: at), try CSSValue.angle([value[1]], at: at))
                } else {
                    throw CSSError("'\(value.text)' is not a harmony; use tonal, analogous, complementary, "
                                   + "split, triadic or monochrome, or two angles for the secondary and tertiary "
                                   + "hues, as in 50deg 180deg", at: at)
                }
            case "chroma":
                if value == [.ident("seed")] {
                    rule.chroma = .seed
                } else {
                    let scale = try CSSValue.number(value, at: at)
                    guard scale >= 0 else { throw CSSError("an @scheme's chroma is 0 or more", at: at) }
                    rule.chroma = .scale(scale)
                }
            case "contrast":
                let ratio = try CSSValue.number(value, at: at)
                guard (1...21).contains(ratio), value[0].unit == nil else {
                    throw CSSError("an @scheme's contrast is a ratio from 1 to 21, as in contrast: 7", at: at)
                }
                rule.contrast = ratio
            case let other:
                throw CSSError("'\(other)' is not something @scheme takes; it takes "
                               + SchemeRule.descriptors.dropLast().joined(separator: ", ") + " and contrast", at: at)
            }
        }
        return rule
    }

    /// A scheme belongs to a bar, so its seed may be any colour a bar knows, the wallpaper's
    /// included, but nothing a node decides: not `currentColor`, nor a custom property.
    static func schemeSeed(_ value: [CSSComponent], at position: CSSPosition) throws -> [CSSComponent] {
        guard !value.mentions(["var", "scheme"]) else {
            throw CSSError("a scheme belongs to the bar, so its seed cannot read a custom property or another "
                           + "scheme; write the colour itself", at: position)
        }
        try checkSubstitutions(value, at: position)
        // Parsed with each wallpaper() standing in as black, for its grammar and for currentColor.
        func standIn(_ components: [CSSComponent]) -> [CSSComponent] {
            components.map { component in
                guard case .function(let name, let args) = component else { return component }
                return name == "wallpaper" ? .color(RGBA(r: 0, g: 0, b: 0)) : .function(name, args.map(standIn))
            }
        }
        if try CSSValue.color(standIn(value), at: position).mentionsCurrent {
            throw CSSError("a scheme belongs to the bar, not to a node, so its seed cannot be currentColor",
                           at: position)
        }
        return value
    }

    /// Every `scheme(--name …)` names a scheme this sheet defines, or one it is layered over.
    func checkSchemeNames(in sheet: Stylesheet) throws {
        func check(_ value: [CSSComponent], at position: CSSPosition) throws {
            for component in value {
                guard case .function(let name, let args) = component else { continue }
                if name == "scheme", let reference = try? SchemeReference(args, at: position),
                   let scheme = reference.name, sheet.schemes[scheme] == nil, !knownSchemes.contains(scheme) {
                    let known = sheet.schemes.keys.filter { !$0.isEmpty }.sorted()
                    throw CSSError("no @scheme is called \(scheme)"
                                   + (known.isEmpty ? "" : "; this stylesheet has " + known.joined(separator: ", ")),
                                   at: position)
                }
                for arg in args { try check(arg, at: position) }
            }
        }
        for rule in sheet.rules {
            for declaration in rule.declarations { try check(declaration.value, at: declaration.position) }
        }
    }

    /// `@starting-style { #names { opacity: 0 } }`: the styles an item that has just appeared
    /// starts from, as in CSS.
    mutating func startingStyle(at start: CSSPosition) throws -> [StyleRule] {
        try skipTrivia()
        guard peek() == "{" else { throw CSSError("expected { after @starting-style", at: position) }
        advance()
        var rules: [StyleRule] = []
        while true {
            try skipTrivia()
            guard let c = peek() else { throw CSSError("unterminated @starting-style block", at: start) }
            if c == "}" { advance(); return rules }
            if c == "@" { throw CSSError("@starting-style blocks do not nest", at: position) }
            var rule = try rule(media: nil)
            rule.starting = true
            rules.append(rule)
        }
    }

    mutating func media(at start: CSSPosition) throws -> [StyleRule] {
        let query = try mediaQuery()
        try skipTrivia()
        guard peek() == "{" else {
            throw CSSError("expected { after @media", at: position)
        }
        advance()
        var rules: [StyleRule] = []
        while true {
            try skipTrivia()
            guard let c = peek() else { throw CSSError("unterminated @media block", at: start) }
            if c == "}" { advance(); return rules }
            if c == "@" { throw CSSError("@media blocks do not nest", at: position) }
            rules.append(try rule(media: query))
        }
    }

    mutating func mediaQuery() throws -> MediaQuery {
        let start = position
        try skipTrivia()
        guard peek() == "(" else {
            throw CSSError("@media takes (prefers-color-scheme: dark) or (prefers-color-scheme: light)",
                           at: position)
        }
        advance()
        try skipTrivia()
        let feature = readIdentifier()
        try skipTrivia()
        guard peek() == ":" else {
            throw CSSError("expected : in the media query", at: position)
        }
        advance()
        try skipTrivia()
        let value = readIdentifier()
        try skipTrivia()
        guard peek() == ")" else { throw CSSError("expected ) to close the media query", at: position) }
        advance()
        guard feature == "prefers-color-scheme" else {
            throw CSSError("the only media feature is prefers-color-scheme; found '\(feature)'", at: start)
        }
        guard let appearance = MediaQuery.Appearance(rawValue: value) else {
            throw CSSError("prefers-color-scheme is light or dark; found '\(value)'", at: start)
        }
        return MediaQuery(appearance: appearance)
    }

    mutating func rule(media: MediaQuery?) throws -> StyleRule {
        let start = position
        let selectorText = try readUntilBrace()
        let selectors = try SelectorParser.parseList(selectorText.text, at: selectorText.position)
        guard peek() == "{" else {
            throw CSSError("expected { after the selector", at: position)
        }
        advance()
        let declarations = try declarationBlock()
        order += 1
        return StyleRule(selectors: selectors, declarations: declarations, media: media,
                         order: order - 1, position: start)
    }

    mutating func readUntilBrace() throws -> (text: String, position: CSSPosition) {
        try skipTrivia()
        let start = position
        var text = ""
        while let c = peek(), c != "{" {
            if c == "}" || c == ";" {
                throw CSSError("expected { after the selector '\(text.trimmed)'", at: position)
            }
            if c == "/", peek(1) == "*" {
                try skipTrivia()                    // a comment inside a selector list
                text.append(" ")
                continue
            }
            text.append(advance()!)
        }
        guard peek() != nil else {
            throw CSSError("the selector '\(text.trimmed)' has no { } block", at: start)
        }
        return (text, start)
    }

    /// `validate: false` for an at-rule whose block holds descriptors rather than properties.
    mutating func declarationBlock(validate: Bool = true) throws -> [Declaration] {
        var declarations: [Declaration] = []
        while true {
            try skipTrivia()
            guard let c = peek() else { throw CSSError("unterminated { } block", at: position) }
            if c == "}" { advance(); return declarations }
            if c == ";" { advance(); continue }
            declarations.append(try declaration(validate: validate))
        }
    }

    mutating func declarationsToEnd() throws -> [Declaration] {
        var declarations: [Declaration] = []
        while true {
            try skipTrivia()
            guard let c = peek() else { return declarations }
            if c == ";" { advance(); continue }
            declarations.append(try declaration())
        }
    }

    mutating func declaration(validate: Bool = true) throws -> Declaration {
        let start = position
        let name = readIdentifier()
        guard !name.isEmpty else {
            let c = peek().map(String.init) ?? "end of file"
            throw CSSError("expected a property name, found \(c)", at: start)
        }
        try skipTrivia()
        guard peek() == ":" else {
            throw CSSError("expected : after '\(name)'", at: position)
        }
        advance()

        var value: [CSSComponent] = []
        var important = false
        while true {
            try skipTrivia()
            guard let c = peek() else { break }     // end of an inline style="…"
            if c == ";" { advance(); break }
            if c == "}" { break }
            if c == "!" {
                advance()
                try skipTrivia()
                let word = readIdentifier()
                guard word == "important" else {
                    throw CSSError("expected !important, found !\(word)", at: start)
                }
                important = true
                continue
            }
            value.append(try component())
        }

        guard !value.isEmpty else {
            throw CSSError("'\(name)' has no value", at: start)
        }
        let declaration = Declaration(property: name, value: value, important: important, position: start)
        guard validate else { return declaration }
        // Validate now, while the position is at hand, unless substitution defers it. What
        // wallpaper() and scheme() ask for is checked either way.
        if value.needsSubstitution {
            try CSSParser.checkSubstitutions(value, at: start)
        } else {
            _ = try StyleProperty.validate(declaration)
        }
        return declaration
    }

    /// A slot or role that does not exist is an error where it is written (PLAN.md W2).
    static func checkSubstitutions(_ value: [CSSComponent], at position: CSSPosition) throws {
        for component in value {
            guard case .function(let name, let args) = component else { continue }
            if name == "wallpaper" { _ = try WallpaperReference(args, at: position) }
            if name == "scheme" { _ = try SchemeReference(args, at: position) }
            for arg in args { try checkSubstitutions(arg, at: position) }
        }
    }

    // MARK: Components

    mutating func component() throws -> CSSComponent {
        let start = position
        guard let c = peek() else { throw CSSError("unexpected end of value", at: start) }
        switch c {
        case ",": advance(); return .comma
        case "/": advance(); return .slash
        case "*": advance(); return .delim("*")
        case "(":
            advance()
            return .function("", try arguments(of: "", at: start))
        case "\"", "'":
            return .string(try readString())
        case "#":
            advance()
            let body = readWhile { $0.isHexDigit }
            guard [3, 4, 6, 8].contains(body.count) else {
                throw CSSError("'#\(body)' is not a colour; write #rgb, #rgba, #rrggbb or #rrggbbaa", at: start)
            }
            return .hash(body)
        case let c where c.isNumber || c == "." || c == "-" || c == "+":
            if c == "-" || c == "+" {
                let next = peek(1)
                let numeric = next.map { $0.isNumber || $0 == "." } ?? false
                let identifier = c == "-" && next.map { $0.isLetter || $0 == "-" || $0 == "_" } ?? false
                if identifier { return try identOrFunction() }
                if !numeric { advance(); return .delim(c) }
            }
            return try number()
        default:
            return try identOrFunction()
        }
    }

    mutating func number() throws -> CSSComponent {
        let start = position
        var text = ""
        if peek() == "-" || peek() == "+" { text.append(advance()!) }
        text += readWhile { $0.isNumber }
        if peek() == "." { text.append(advance()!); text += readWhile { $0.isNumber } }
        if peek() == "e" || peek() == "E", let next = peek(1), next.isNumber || next == "-" || next == "+" {
            text.append(advance()!)
            text.append(advance()!)
            text += readWhile { $0.isNumber }
        }
        guard let value = Double(text) else {
            throw CSSError("'\(text)' is not a number", at: start)
        }
        var unit: String? = nil
        if peek() == "%" { advance(); unit = "%" }
        else {
            let word = readIdentifier()
            if !word.isEmpty { unit = word }
        }
        return .number(value, unit: unit)
    }

    mutating func identOrFunction() throws -> CSSComponent {
        let start = position
        let name = readIdentifier()
        guard !name.isEmpty else {
            let c = peek().map(String.init) ?? "end of file"
            advance()
            throw CSSError("unexpected \(c) in a value", at: start)
        }
        guard peek() == "(" else { return .ident(name) }
        advance()
        return .function(name, try arguments(of: name, at: start))
    }

    /// What is between a function's parentheses, the opening one already read, split on
    /// commas.
    mutating func arguments(of name: String, at start: CSSPosition) throws -> [[CSSComponent]] {
        var args: [[CSSComponent]] = []
        var current: [CSSComponent] = []
        while true {
            try skipTrivia()
            guard let c = peek() else { throw CSSError("unterminated \(name)(", at: start) }
            if c == ")" {
                advance()
                args.append(current)
                return args
            }
            if c == "," {
                advance()
                args.append(current)
                current = []
                continue
            }
            current.append(try component())
        }
    }

    mutating func readString() throws -> String {
        let start = position
        let quote = advance()!
        var text = ""
        while true {
            guard let c = advance() else { throw CSSError("unterminated string", at: start) }
            if c == quote { return text }
            if c == "\\" {
                guard let escaped = advance() else { throw CSSError("unterminated string", at: start) }
                text.append(escaped)
            } else if c == "\n" {
                throw CSSError("a string cannot span lines", at: start)
            } else {
                text.append(c)
            }
        }
    }

    mutating func readIdentifier() -> String {
        var text = ""
        if peek() == "-", let next = peek(1), next == "-" || next.isLetter || next == "_" {
            text.append(advance()!)
        }
        text += readWhile { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return text
    }

    mutating func readWhile(_ predicate: (Character) -> Bool) -> String {
        var text = ""
        while let c = peek(), predicate(c) { text.append(advance()!) }
        return text
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
