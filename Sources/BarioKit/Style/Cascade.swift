import Foundation

/// What a cascade knows of the bar it styles, beyond the stylesheet: the appearance, the
/// accent, and the wallpaper of the bar's display (PLAN.md W1). The cascade turns
/// `wallpaper()` and `scheme()` into concrete colours with it, so a new palette is a restyle
/// like any other and eases through the stylesheet's own `transition`.
public struct StyleEnvironment: Sendable, Hashable {
    /// Which `@media (prefers-color-scheme: …)` blocks are live.
    public var dark: Bool
    /// The user's accent colour: `wallpaper(seed)` for an image with no seed.
    public var accent: RGBA
    /// The bar's display's wallpaper, measured. Before it has been, or where it cannot be, nil,
    /// or `Palette.nothing`, which comes to the same.
    public var palette: Palette?
    /// The stylesheet's schemes made for this bar, by name ("" for the unnamed one), when the
    /// frame loop has them cached; any missing is made when it is asked for.
    public var schemes: [String: Scheme]

    public init(dark: Bool = false, accent: RGBA = Palette.defaultAccent, palette: Palette? = nil,
                schemes: [String: Scheme] = [:]) {
        self.dark = dark
        self.accent = accent
        self.palette = palette
        self.schemes = schemes
    }
}

/// Matching, sorting, `var()` resolution and the computation of one `Style` per node.
public struct Cascade: Sendable {
    public var stylesheet: Stylesheet
    public var environment: StyleEnvironment

    /// Which `@media (prefers-color-scheme: …)` blocks are live.
    public var dark: Bool {
        get { environment.dark }
        set { environment.dark = newValue }
    }

    public init(stylesheet: Stylesheet, dark: Bool = false) {
        self.init(stylesheet: stylesheet, environment: StyleEnvironment(dark: dark))
    }

    public init(stylesheet: Stylesheet, environment: StyleEnvironment) {
        self.stylesheet = stylesheet
        self.environment = environment
    }

    public struct Result: Sendable {
        public var style: Style
        /// Declarations dropped after `var()` substitution, in CSS's "invalid at computed
        /// value time" sense. They are reported, not fatal.
        public var diagnostics: [CSSError]
    }

    /// `path` runs root-first and ends at the node being styled. `parent` is that path's
    /// second-to-last resolved style, or nil at the root. `starting` adds the rules written in
    /// `@starting-style`, which take part in no other cascade.
    public func style(for path: [StyleNode],
                      inheriting parent: Style? = nil,
                      inline: [Declaration] = [],
                      starting: Bool = false) -> Result {
        var style = parent?.inherited() ?? Style.initial
        var diagnostics: [CSSError] = []

        var matched: [(declaration: Declaration, key: SortKey)] = []
        for rule in stylesheet.rules {
            if let media = rule.media, !media.matches(dark: dark) { continue }
            if rule.starting && !starting { continue }
            guard let specificity = rule.selectors
                .filter({ $0.matches(path) })
                .map(\.specificity)
                .max() else { continue }
            for declaration in rule.declarations {
                matched.append((declaration, SortKey(important: declaration.important,
                                                     inline: false,
                                                     specificity: specificity,
                                                     order: rule.order)))
            }
        }
        for declaration in inline {
            matched.append((declaration, SortKey(important: declaration.important,
                                                 inline: true,
                                                 specificity: Specificity(ids: 0, classes: 0, types: 0),
                                                 order: Int.max)))
        }
        matched.sort { $0.key < $1.key }

        // Custom properties first: everything else may reference them through var().
        for (declaration, _) in matched where StyleProperty.isCustom(declaration.property) {
            do {
                style.custom[declaration.property] = try resolve(declaration.value, in: style.custom,
                                                                 at: declaration.position)
            } catch let error as CSSError {
                diagnostics.append(error)
            } catch {
                diagnostics.append(CSSError("\(error)", at: declaration.position))
            }
        }

        var animationsAt = CSSPosition.start
        for (declaration, _) in matched where !StyleProperty.isCustom(declaration.property) {
            guard let property = StyleProperty(rawValue: declaration.property) else {
                diagnostics.append(CSSError("unknown property '\(declaration.property)'",
                                            at: declaration.position))
                continue
            }
            do {
                let value = try resolve(declaration.value, in: style.custom, at: declaration.position)
                try style.apply(property, value, at: declaration.position)
                if property == .animation { animationsAt = declaration.position }
            } catch let error as CSSError {
                diagnostics.append(error)
            } catch {
                diagnostics.append(CSSError("\(error)", at: declaration.position))
            }
        }

        // An animation carries its keyframes, resolved for this node, so nothing after the
        // cascade needs the stylesheet.
        style.animations = style.animations.compactMap { animation in
            guard let rule = stylesheet.keyframes[animation.name] else {
                diagnostics.append(CSSError("no @keyframes named '\(animation.name)'", at: animationsAt))
                return nil
            }
            var animation = animation
            animation.keyframes = keyframes(rule, in: style.custom, diagnostics: &diagnostics)
            return animation
        }

        return Result(style: style, diagnostics: diagnostics)
    }

    /// What a node that has just appeared transitions from, or nil when no `@starting-style`
    /// rule matches it.
    public func startingStyle(for path: [StyleNode], inheriting parent: Style? = nil,
                              inline: [Declaration] = []) -> Style? {
        guard stylesheet.rules.contains(where: { rule in
            rule.starting && rule.selectors.contains { $0.matches(path) }
        }) else { return nil }
        return style(for: path, inheriting: parent, inline: inline, starting: true).style
    }

    /// What a node transitions to once it has left, or nil when no rule names it `:leaving`.
    public func leavingStyle(for path: [StyleNode], inheriting parent: Style? = nil,
                             inline: [Declaration] = []) -> Style? {
        guard var node = path.last else { return nil }
        node.states.insert(.leaving)
        let leaving = Array(path.dropLast()) + [node]
        guard stylesheet.rules.contains(where: { rule in
            !rule.starting && rule.media.map { $0.matches(dark: dark) } != false
                && rule.selectors.contains { $0.parts.last?.states.contains(.leaving) == true && $0.matches(leaving) }
        }) else { return nil }
        return style(for: leaving, inheriting: parent, inline: inline).style
    }

    /// A keyframes rule's stops for one node, sorted, with `var()` resolved against it.
    func keyframes(_ rule: KeyframesRule, in custom: [String: [CSSComponent]],
                   diagnostics: inout [CSSError]) -> [Keyframe] {
        var byOffset: [Double: Keyframe] = [:]
        for stop in rule.stops {
            var scratch = Style()
            var transform: Transform?
            var opacity: Double?
            for declaration in stop.declarations {
                guard let property = StyleProperty(rawValue: declaration.property) else { continue }
                do {
                    let value = try resolve(declaration.value, in: custom, at: declaration.position)
                    try scratch.apply(property, value, at: declaration.position)
                    if property == .transform { transform = scratch.transform }
                    if property == .opacity { opacity = scratch.opacity }
                } catch let error as CSSError {
                    diagnostics.append(error)
                } catch {
                    diagnostics.append(CSSError("\(error)", at: declaration.position))
                }
            }
            for offset in stop.offsets {
                var frame = byOffset[offset] ?? Keyframe(offset: offset)
                if let transform { frame.transform = transform }
                if let opacity { frame.opacity = opacity }
                byOffset[offset] = frame
            }
        }
        return byOffset.values.sorted { $0.offset < $1.offset }
    }

    // MARK: - var(), wallpaper() and scheme()

    /// Substitutes `var(--name)` and `var(--name, fallback)` against the custom properties
    /// that have already cascaded onto this node, and `wallpaper()` and `scheme()` against the
    /// bar's palette and schemes.
    func resolve(_ components: [CSSComponent], in custom: [String: [CSSComponent]],
                 at position: CSSPosition, depth: Int = 0) throws -> [CSSComponent] {
        guard depth < 16 else {
            throw CSSError("var() references itself in a loop", at: position)
        }
        guard components.needsSubstitution else { return components }

        var out: [CSSComponent] = []
        for component in components {
            switch component {
            case .function("var", let args):
                guard let name = args.first?.first?.identValue, name.hasPrefix("--") else {
                    throw CSSError("var() takes a custom property name, e.g. var(--fg)", at: position)
                }
                if let value = custom[name] {
                    out.append(contentsOf: try resolve(value, in: custom, at: position, depth: depth + 1))
                } else if args.count > 1 {
                    let fallback = Array(Array(args.dropFirst()).joined(separator: [CSSComponent.comma]))
                    out.append(contentsOf: try resolve(fallback, in: custom, at: position, depth: depth + 1))
                } else {
                    throw CSSError("\(name) is not defined, and var(\(name)) has no fallback", at: position)
                }
            case .function("wallpaper", let args):
                let reference = try WallpaperReference(args, at: position)
                out.append(contentsOf: try resolve(reference.value(in: environment), in: custom,
                                                   at: position, depth: depth + 1))
            case .function("scheme", let args):
                let reference = try SchemeReference(args, at: position)
                out.append(.color(try scheme(named: reference.name, at: position)[reference.role]))
            case .function(let name, let args) where args.contains(where: \.needsSubstitution):
                out.append(.function(name, try args.map {
                    try resolve($0, in: custom, at: position, depth: depth + 1)
                }))
            default:
                out.append(component)
            }
        }
        return out
    }

    /// One of the stylesheet's schemes for this bar: the frame loop's cached one, or made now.
    func scheme(named name: String?, at position: CSSPosition) throws -> Scheme {
        if let scheme = environment.schemes[name ?? ""] { return scheme }
        guard let rule = stylesheet.schemes[name ?? ""] ?? (name == nil ? SchemeRule.defaults : nil) else {
            throw CSSError("no @scheme is called \(name ?? "")", at: position)
        }
        return Scheme(rule.key(in: environment))
    }

    struct SortKey: Comparable {
        var important: Bool
        var inline: Bool
        var specificity: Specificity
        var order: Int

        static func < (a: SortKey, b: SortKey) -> Bool {
            if a.important != b.important { return !a.important }
            if a.inline != b.inline { return !a.inline }
            if a.specificity != b.specificity { return a.specificity < b.specificity }
            return a.order < b.order
        }
    }
}

/// `wallpaper(<slot>[, <fallback>])` or `wallpaper(seed [<n>][, <fallback>])`, checked where it
/// is written and substituted by the cascade (PLAN.md W2, W9, W10).
struct WallpaperReference {
    enum Target: Equatable {
        case slot(Slot.Name)
        /// 1 is the strongest.
        case seed(Int)
    }

    var target: Target
    var fallback: [CSSComponent]?

    init(_ args: [[CSSComponent]], at position: CSSPosition) throws {
        let slots = Slot.Name.allCases.map(\.rawValue).joined(separator: ", ")
        guard (1...2).contains(args.count), args.last?.isEmpty == false else {
            throw CSSError("wallpaper() takes a slot or a seed, and an optional fallback colour: "
                           + "wallpaper(vibrant), wallpaper(seed 2) or wallpaper(vibrant, accent)", at: position)
        }
        fallback = args.count == 2 ? args[1] : nil
        switch args[0] {
        case [.ident("seed")]:
            target = .seed(1)
        case let words where words.first == .ident("seed") && words.count == 2:
            guard case .number(let n, let unit) = words[1], unit == nil, (1...4).contains(n), n == n.rounded() else {
                throw CSSError("a wallpaper has up to four seeds, so wallpaper(seed …) takes 1 to 4, "
                               + "not '\(words[1].text)'", at: position)
            }
            target = .seed(Int(n))
        case let words:
            guard words.count == 1, let name = words[0].identValue.flatMap(Slot.Name.init(rawValue:)) else {
                throw CSSError("'\(words.text)' is not something a wallpaper has; its slots are \(slots), "
                               + "and its seeds are seed, seed 2, seed 3 and seed 4", at: position)
            }
            target = .slot(name)
        }
    }

    /// What it stands for: the palette's colour, or the fallback where the slot was made up or
    /// the seed is missing. With no palette and no fallback a slot is made up from nothing,
    /// so it always has a colour, and a seed is the accent.
    func value(in environment: StyleEnvironment) -> [CSSComponent] {
        switch target {
        case .slot(let name):
            if let slot = environment.palette?[name], slot.found || fallback == nil {
                return [.color(slot.rgba)]
            }
            if let fallback { return fallback }
            return [.color(Palette.nothing(accent: environment.accent)[name].rgba)]
        case .seed(let n):
            let seeds = environment.palette?.seeds ?? []
            if seeds.count >= n { return [.color(seeds[n - 1].rgba)] }
            if let fallback { return fallback }
            return [.color(seeds.first?.rgba ?? environment.accent)]
        }
    }
}
