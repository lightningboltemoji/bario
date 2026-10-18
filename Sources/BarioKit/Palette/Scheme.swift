import Foundation

/// `@scheme [--name] { seed; harmony; chroma; contrast }`, as written (PLAN.md W12). The unnamed
/// scheme is what `scheme(<role>)` uses, and exists with the defaults whether or not a rule
/// says so; `scheme(--name <role>)` names another.
public struct SchemeRule: Sendable, Hashable {
    public enum Chroma: Sendable, Hashable {
        /// A multiple of the usual chroma.
        case scale(Double)
        /// The seed's own chroma, kept to 0.03…0.2, which suits a muted wallpaper better.
        case seed
    }

    /// Nil for the unnamed scheme.
    public var name: String?
    /// Any colour but `currentColor`, since a scheme belongs to a bar and not to a node.
    public var seed: [CSSComponent]
    public var harmony: Harmony
    public var chroma: Chroma
    /// What every `on-` role reaches against its partner.
    public var contrast: Double
    public var position: CSSPosition

    public static let defaults = SchemeRule(
        name: nil, seed: [.function("wallpaper", [[.ident("seed")]])], harmony: .tonal,
        chroma: .scale(1), contrast: 4.5, position: .start)

    /// The descriptors, and what each takes, for error messages.
    static let descriptors = ["seed", "harmony", "chroma", "contrast"]

    /// The key a scheme is made from and cached by: the seed as this bar's environment resolves
    /// it, with `wallpaper()`, `accent` and `system()` all known (PLAN.md W3), and the rest.
    func key(in environment: StyleEnvironment) -> Scheme.Key {
        let cascade = Cascade(stylesheet: Stylesheet(), environment: environment)
        let seed = (try? cascade.resolve(self.seed, in: [:], at: position))
            .flatMap { try? CSSValue.color($0, at: position) } ?? .accent
        let rgba = ColorResolver(dark: environment.dark, accent: environment.accent).resolve(seed)
        return Scheme.Key(seed: RGBA(r: rgba.r, g: rgba.g, b: rgba.b), harmony: harmony, chroma: chroma,
                          contrast: contrast, dark: environment.dark)
    }
}

/// Where a scheme puts its secondary and tertiary hues, around the seed's.
public enum Harmony: Sendable, Hashable {
    case tonal, analogous, complementary, split, triadic, monochrome
    /// `harmony: 50deg 180deg`: the secondary's and the tertiary's turn from the seed's hue.
    case angles(Double, Double)

    static let names: [String: Harmony] = [
        "tonal": .tonal, "analogous": .analogous, "complementary": .complementary,
        "split": .split, "triadic": .triadic, "monochrome": .monochrome,
    ]

    /// The secondary's and tertiary's turns from the seed's hue, in degrees. Nil is the seed's
    /// own hue, quietly.
    var turns: (secondary: Double?, tertiary: Double?) {
        switch self {
        case .tonal: return (nil, 60)
        case .analogous: return (-30, 30)
        case .complementary: return (nil, 180)
        case .split: return (150, 210)
        case .triadic: return (120, 240)
        case .monochrome: return (nil, nil)
        case .angles(let secondary, let tertiary):
            func turn(_ degrees: Double) -> Double? {
                degrees.truncatingRemainder(dividingBy: 360) == 0 ? nil : degrees
            }
            return (turn(secondary), turn(tertiary))
        }
    }
}

/// A theme generated from one seed colour (PLAN.md W12): four hues with chromas, primary at the
/// seed's hue, secondary and tertiary where the harmony puts them, and neutral at the seed's hue
/// with almost no chroma, each at fixed lightnesses for the appearance. Every `on-` role starts
/// at its own lightness and moves further only if it falls short of the contrast against its
/// partner, by the same solver as `on()`.
public struct Scheme: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable, CaseIterable {
        case primary
        case onPrimary = "on-primary"
        case primaryContainer = "primary-container"
        case onPrimaryContainer = "on-primary-container"
        case secondary
        case onSecondary = "on-secondary"
        case secondaryContainer = "secondary-container"
        case onSecondaryContainer = "on-secondary-container"
        case tertiary
        case onTertiary = "on-tertiary"
        case tertiaryContainer = "tertiary-container"
        case onTertiaryContainer = "on-tertiary-container"
        case surface
        case surfaceContainer = "surface-container"
        case onSurface = "on-surface"
        case outline

        /// What an `on-` role reads against, and is solved against.
        public var partners: [Role] {
            switch self {
            case .onPrimary: return [.primary]
            case .onPrimaryContainer: return [.primaryContainer]
            case .onSecondary: return [.secondary]
            case .onSecondaryContainer: return [.secondaryContainer]
            case .onTertiary: return [.tertiary]
            case .onTertiaryContainer: return [.tertiaryContainer]
            case .onSurface: return [.surface, .surfaceContainer]
            default: return []
            }
        }
    }

    /// Everything a scheme is made from. Schemes are cached per bar by it.
    public struct Key: Sendable, Hashable {
        public var seed: RGBA
        public var harmony: Harmony
        public var chroma: SchemeRule.Chroma
        public var contrast: Double
        public var dark: Bool
    }

    public var key: Key
    public var colors: [Role: RGBA]

    public subscript(_ role: Role) -> RGBA { colors[role]! }

    public init(_ key: Key) {
        self.key = key
        let seed = OKLCH(key.seed)
        let primary: Double
        switch key.chroma {
        case .scale(let scale): primary = 0.13 * max(0, scale)
        case .seed: primary = min(0.2, max(0.03, seed.c))
        }
        let (second, third) = key.harmony.turns
        let mono = key.harmony == .monochrome
        typealias Family = (c: Double, h: Double)
        func hue(_ turn: Double) -> Double {
            let h = (seed.h + turn).truncatingRemainder(dividingBy: 360)
            return h < 0 ? h + 360 : h
        }
        let families: [(base: Role, Family)] = [
            (.primary, (mono ? 0 : primary, seed.h)),
            (.secondary, mono ? (0, seed.h) : second.map { (0.8 * primary, hue($0)) } ?? (0.35 * primary, seed.h)),
            (.tertiary, mono ? (0, seed.h) : third.map { (0.75 * primary, hue($0)) } ?? (0.75 * primary, seed.h)),
        ]
        let neutral: Family = (mono ? 0 : 0.012, seed.h)
        let dark = key.dark
        func tone(_ family: Family, _ light: Double, _ inDark: Double) -> OKLCH {
            OKLCH(l: dark ? inDark : light, c: family.c, h: family.h)
        }

        var colors: [Role: RGBA] = [:]
        for (base, family) in families {
            let (on, container, onContainer) = Scheme.partnersOf(base)
            let fill = tone(family, 0.52, 0.80).rgba()
            let well = tone(family, 0.90, 0.36).rgba()
            colors[base] = fill
            colors[container] = well
            // Light ink on the light scheme's fills and dark ink on the dark's, and the other way
            // round on containers.
            colors[on] = tone(family, 0.99, 0.24).readable(against: fill, ratio: key.contrast, lighter: !dark)
            colors[onContainer] = tone(family, 0.28, 0.94)
                .readable(against: well, ratio: key.contrast, lighter: dark)
        }
        let surface = tone(neutral, 0.975, 0.20)
        colors[.surface] = surface.rgba()
        colors[.surfaceContainer] = tone(neutral, 0.93, 0.27).rgba()
        // On either surface: solved against the harder one first, then checked on the other.
        var ink = tone(neutral, 0.24, 0.93)
        for partner in [Role.surfaceContainer, .surface] {
            ink = OKLCH(ink.readable(against: colors[partner]!, ratio: key.contrast, lighter: dark))
        }
        colors[.onSurface] = ink.rgba()
        // Visible against the surface, as a border has to be, and no more.
        colors[.outline] = surface.readable(against: colors[.surface]!, ratio: 3, lighter: dark)
        self.colors = colors
    }

    private static func partnersOf(_ base: Role) -> (on: Role, container: Role, onContainer: Role) {
        switch base {
        case .secondary: return (.onSecondary, .secondaryContainer, .onSecondaryContainer)
        case .tertiary: return (.onTertiary, .tertiaryContainer, .onTertiaryContainer)
        default: return (.onPrimary, .primaryContainer, .onPrimaryContainer)
        }
    }
}

/// `scheme(<role>)` or `scheme(--name <role>)`, checked where it is written and substituted by
/// the cascade (PLAN.md W2, W12).
struct SchemeReference {
    /// Nil for the unnamed scheme.
    var name: String?
    var role: Scheme.Role

    init(_ args: [[CSSComponent]], at position: CSSPosition) throws {
        guard args.count == 1, !args[0].isEmpty else {
            throw CSSError("scheme() takes a role, after the name of an @scheme for one other than the "
                           + "unnamed: scheme(primary) or scheme(--pop on-primary)", at: position)
        }
        var words = args[0]
        if let first = words.first?.identValue, first.hasPrefix("--") {
            name = first
            words.removeFirst()
        }
        guard words.count == 1, let role = words[0].identValue.flatMap(Scheme.Role.init(rawValue:)) else {
            throw CSSError("'\(words.text)' is not a scheme's role; they are "
                           + Scheme.Role.allCases.map(\.rawValue).joined(separator: ", "), at: position)
        }
        self.role = role
    }
}
