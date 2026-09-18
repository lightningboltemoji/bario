import Foundation

/// The structure of every bar, as parsed from `config.kdl`. Looks live in the stylesheet;
/// this file is only about what exists and in what order. DESIGN.md §11.
public struct Config: Sendable, Equatable {
    public var bars: [BarConfig]
    public var renderers: [RendererConfig]

    public init(bars: [BarConfig] = [], renderers: [RendererConfig] = []) {
        self.bars = bars
        self.renderers = renderers
    }

    /// The bar a display should show: the most specific `bar` node that matches it.
    public func bar(for display: DisplayInfo) -> BarConfig? {
        bars.compactMap { bar in bar.display.score(for: display).map { (bar, $0) } }
            .max { $0.1 < $1.1 }?.0
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
    /// nil means "whatever the stylesheet says". Writing either in the config wins over the
    /// stylesheet, because a value written in the file you are editing should be the one that
    /// takes effect.
    public var padding: Insets?
    public var gap: Double?
    /// nil means "this display's menu bar height".
    public var height: Double?
    public var align: Align = .center
    public var hole = HoleConfig()
    public var notch: NotchPolicy = .avoid
    public var items: [ItemConfig] = []
    public var position: KDLPosition = .start
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
    case ignore
}

public struct RendererConfig: Sendable, Equatable {
    public var nodeType: String
    public var path: String
    public var options: JSONValue
    public var position: KDLPosition
}

/// One entry on a bar. A group is an item whose content is other items; a spacer is an empty
/// item with `grow` 1; the notch marker is where the bar splits on a notched display.
public struct ItemConfig: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case module(String)
        case group([ItemConfig])
        case spacer
        case notch
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
    /// A content tree written in the config, for `text` and `data` items: what a `text` item
    /// shows, and what a `data` item shows until something is pushed to it.
    public var content: Node?
    public var gap: Double?
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
    public var width: Double?
    public var minWidth: Double?
    public var maxWidth: Double?
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
