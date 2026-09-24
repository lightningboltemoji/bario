import Foundation

/// The structure of every bar, as parsed from `config.kdl`. Looks live in the stylesheet;
/// this file is only about what exists and in what order. DESIGN.md §11.
public struct Config: Sendable, Equatable {
    public var bars: [BarConfig]
    public var renderers: [RendererConfig]
    /// Providers with no bubble: modules that write state for other items to read, and are
    /// never laid out. DESIGN.md §3.
    public var sources: [ItemConfig]
    public var modes: [ModeConfig]

    public init(bars: [BarConfig] = [], renderers: [RendererConfig] = [],
                sources: [ItemConfig] = [], modes: [ModeConfig] = []) {
        self.bars = bars
        self.renderers = renderers
        self.sources = sources
        self.modes = modes
    }

    /// The bar a display should show: the most specific `bar` node that matches it.
    public func bar(for display: DisplayInfo) -> BarConfig? {
        bars.compactMap { bar in bar.display.score(for: display).map { (bar, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// `display` with its strip as tall as it has to be: over the whole menu bar, which must
    /// stay covered, and down to the bottom of the bar, which may hang past it. DESIGN.md §6.
    public func strip(on display: DisplayInfo) -> DisplayInfo {
        var display = display
        let bar = bar(for: display)?.height(on: display) ?? Double(display.menuBarHeight)
        display.stripHeight = max(display.menuBarHeight, CGFloat(bar))
        return display
    }
}

public enum DisplayFilter: Sendable, Hashable {
    case any
    case builtIn
    case external
    case named(String)

    /// How specific a match this is, or nil for no match. Higher wins.
    public func score(for display: DisplayInfo) -> Int? {
        switch self {
        case .any: return 0
        case .builtIn: return display.isBuiltIn ? 2 : nil
        case .external: return display.isBuiltIn ? nil : 2
        case .named(let name):
            return display.name.compare(name, options: .caseInsensitive) == .orderedSame ? 3 : nil
        }
    }
}

public struct BarConfig: Sendable, Equatable {
    public var display: DisplayFilter = .any
    /// The same on every display, down from the top of the screen. nil means "this display's
    /// menu bar height", which differs from display to display.
    public var height: Double?
    public var align: Align = .center
    public var hole = HoleConfig()
    public var notch: NotchPolicy = .avoid
    public var items: [ItemConfig] = []
    public var position: KDLPosition = .start

    public func height(on display: DisplayInfo) -> Double {
        height ?? Double(display.menuBarHeight)
    }
}

/// The probe's knobs, moved into config. DESIGN.md §8.
public struct HoleConfig: Sendable, Equatable {
    public init() {}

    public var radius: Double = 40
    public var feather: Double = 0
    public var proximity: Double = 80
    public var click: HoleClick = .reveal
}

public enum HoleClick: String, Sendable, Equatable {
    /// A click in the bar uncovers everything until the pointer leaves, so menus stay usable.
    case reveal
    case none
}

public enum NotchPolicy: String, Sendable, Equatable, CaseIterable {
    case avoid
    /// Treat the display as having no notch, so only an `always` marker splits the bar.
    case ignore
}

/// When a `notch` marker splits the bar. DESIGN.md §6.
public enum NotchMarker: String, Sendable, Equatable {
    /// At the notch on a notched display and at the screen's centre on any other, so one
    /// config keeps its two halves apart on both.
    case always
    /// Only on a notched display; elsewhere the bar is one row, as if the marker were not there.
    case ifPresent = "if-present"
}

/// A named condition over the state store and time. While it holds, the bar wears its name as
/// a class and items shown `when` it appear; DESIGN.md §6.
public struct ModeConfig: Sendable, Equatable {
    public var name: String
    /// On while any of these paths holds a truthy value.
    public var whilePaths: [String] = []
    /// On when any of these paths changes value; a path's first value is not a change.
    public var changed: [String] = []
    /// How long it stays on after the last thing that turned it on, in seconds.
    public var hold: Double = 0
    public var position: KDLPosition = .start

    public init(name: String, position: KDLPosition = .start) {
        self.name = name
        self.position = position
    }

    /// Every path the mode is decided from.
    public var paths: [String] { whilePaths + changed }
}

public struct RendererConfig: Sendable, Equatable {
    public var nodeType: String
    public var path: String
    public var options: JSONValue
    public var position: KDLPosition
}

/// One entry on a bar. A group is an item whose content is other items; a spacer is an empty
/// item with `grow` 1; the notch marker is where the bar splits in two.
public struct ItemConfig: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case module(String)
        case group([ItemConfig])
        case spacer
        case notch(NotchMarker)
    }

    public init(name: String, kind: Kind, position: KDLPosition = .start) {
        self.name = name
        self.kind = kind
        self.position = position
    }

    public var name: String
    public var kind: Kind
    public var format: String?
    public var priority: Int = 0
    public var sizing = Sizing()
    public var interval: Interval?
    public var actions = Actions()
    /// A one-off stylesheet body for this item, `style="color: red"`.
    public var style: String?
    /// Stay out of the layout until a provider writes something under this item's key.
    public var hiddenUntilSet = false
    /// Laid out only while this mode is on, or only while it is off. The module runs either
    /// way, so an item a mode brings in has its content ready.
    public var when: String?
    public var unless: String?
    /// A content tree written in the config: what an item shows in place of its format, and
    /// what a `data` item shows until something is pushed to it.
    public var content: Node?
    /// A content tree with slots in it, filled from the item's state on every render; what a
    /// `content` block is when any string in it names a slot.
    public var template: ContentTemplate?
    public var align: Align?
    /// The whole config node as JSON — what the module receives from `init(config)`.
    public var options: JSONValue = .object([:])
    public var position: KDLPosition = .start

    public var moduleName: String? {
        if case .module(let name) = kind { return name } else { return nil }
    }

    public var children: [ItemConfig] {
        if case .group(let items) = kind { return items } else { return [] }
    }

    /// Depth-first, self first: every item that owns a state key.
    public var flattened: [ItemConfig] {
        [self] + children.flatMap(\.flattened)
    }
}

public struct Sizing: Sendable, Equatable {
    public var grow: Double = 0
    public var shrink: Double = 1
}

public enum Interval: Sendable, Equatable {
    case seconds(Double)
    /// Keep the process running and read lines as they come (waybar's continuous `exec`).
    case watch
}

public struct Actions: Sendable, Equatable {
    public init() {}

    public var click: String?
    public var rightClick: String?
    public var scroll: String?
}
