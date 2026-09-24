import Foundation

/// Matching, sorting, `var()` resolution and the computation of one `Style` per node.
public struct Cascade: Sendable {
    public var stylesheet: Stylesheet
    /// Which `@media (prefers-color-scheme: …)` blocks are live.
    public var dark: Bool

    public init(stylesheet: Stylesheet, dark: Bool = false) {
        self.stylesheet = stylesheet
        self.dark = dark
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

    // MARK: - var()

    /// Substitutes `var(--name)` and `var(--name, fallback)` against the custom properties
    /// that have already cascaded onto this node.
    func resolve(_ components: [CSSComponent], in custom: [String: [CSSComponent]],
                 at position: CSSPosition, depth: Int = 0) throws -> [CSSComponent] {
        guard depth < 16 else {
            throw CSSError("var() references itself in a loop", at: position)
        }
        guard components.containsVar else { return components }

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
            case .function(let name, let args) where args.contains(where: \.containsVar):
                out.append(.function(name, try args.map {
                    try resolve($0, in: custom, at: position, depth: depth + 1)
                }))
            default:
                out.append(component)
            }
        }
        return out
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
