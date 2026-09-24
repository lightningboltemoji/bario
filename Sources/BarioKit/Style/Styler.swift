import CoreGraphics

/// The style stage (DESIGN.md §10): every item and content node of one bar, with its resolved
/// style and no geometry yet. Its inputs are the stylesheet (inside the cascade), each item's
/// last render, and which item the pointer is over or pressing.
public struct Styler: Sendable {
    public var cascade: Cascade

    public init(cascade: Cascade) {
        self.cascade = cascade
    }

    /// Which item the pointer is over, and which is being pressed.
    public struct Interaction: Sendable, Hashable {
        public var hovered: String?
        public var active: String?

        public init(hovered: String? = nil, active: String? = nil) {
            self.hovered = hovered
            self.active = active
        }
    }

    /// `modes` are the modes that are on: classes on the bar, and what `when` and `unless`
    /// show items by.
    public func style(bar: BarConfig, items: [ItemConfig],
                      states: [String: ModuleHost.ItemState],
                      interaction: Interaction = Interaction(),
                      modes: Set<String> = []) -> StyledBar {
        let barNode = StyleNode(type: "bar", id: nil, classes: modes, states: [])
        let barStyle = cascade.style(for: [barNode]).style
        let shown = Shown(states: states, modes: modes)

        // The notch marker is kept as a position among the items that are shown, so an
        // invisible item before it cannot move the split.
        var marker: (index: Int, mode: NotchMarker)?
        var visible: [ItemConfig] = []
        for item in items {
            if case .notch(let mode) = item.kind {
                marker = (visible.count, mode)
            } else if shown(item) {
                visible.append(item)
            }
        }
        return StyledBar(config: bar, style: barStyle,
                         items: siblings(visible, parentPath: [barNode], parentStyle: barStyle,
                                         shown: shown, interaction: interaction),
                         notchMarker: marker, styler: self)
    }

    /// The item again, with one more state. Overflow is the one style input only layout can
    /// know, so layout asks for it here.
    public func restyle(_ item: StyledItem, adding state: StyleState) -> StyledItem {
        var item = item
        item.states.insert(state)
        var path = item.path
        path[path.count - 1].states = item.states
        item.path = path
        item.style = itemStyle(item.config, path: path, parentStyle: item.parentStyle)
        return item
    }

    // MARK: - Items

    /// Whether an item takes part in the bar at all. One a mode leaves out is not there; an
    /// item that has never rendered has nothing to show yet, and a placeholder is exactly what
    /// the first frame waits to avoid; an item whose module says invisible is not there
    /// either, and neither is a group with nothing in it.
    struct Shown {
        var states: [String: ModuleHost.ItemState]
        var modes: Set<String>

        func callAsFunction(_ config: ItemConfig) -> Bool {
            if let mode = config.when, !modes.contains(mode) { return false }
            if let mode = config.unless, modes.contains(mode) { return false }
            switch config.kind {
            case .module:
                guard let state = states[config.name], state.rendered else { return false }
                return state.result.visible
            case .group(let children):
                return children.contains { self($0) }
            case .spacer:
                return true
            case .notch:
                return false
            }
        }
    }

    /// A run of shown siblings. `:first-child`, `:last-child` and `:only-child` count only
    /// these, so a hidden item does not leave a hole in a group's corner radii. Spacers are the
    /// space between things, not things, so they do not count either.
    private func siblings(_ configs: [ItemConfig], parentPath: [StyleNode], parentStyle: Style,
                          shown: Shown, interaction: Interaction) -> [StyledItem] {
        let ranked = configs.indices.filter { configs[$0].kind != .spacer }
        return configs.indices.map { index in
            var structural: Set<StyleState> = []
            if index == ranked.first { structural.insert(.firstChild) }
            if index == ranked.last { structural.insert(.lastChild) }
            if ranked.count == 1, index == ranked.first { structural.insert(.onlyChild) }
            return style(configs[index], parentPath: parentPath, parentStyle: parentStyle,
                         shown: shown, interaction: interaction, structural: structural)
        }
    }

    private func style(_ config: ItemConfig, parentPath: [StyleNode], parentStyle: Style,
                       shown: Shown, interaction: Interaction,
                       structural: Set<StyleState>) -> StyledItem {
        let state = shown.states[config.name]
        var itemStates = structural
        if interaction.hovered == config.name { itemStates.insert(.hover) }
        if interaction.active == config.name { itemStates.insert(.active) }
        if state?.stale == true { itemStates.insert(.stale) }
        if state?.error != nil { itemStates.insert(.error) }
        if case .module = config.kind, state?.result.content == nil { itemStates.insert(.empty) }

        var classes = Set(state?.result.classes ?? [])
        if state?.error != nil { classes.insert("error") }

        let type: String
        switch config.kind {
        case .group: type = "group"
        case .spacer, .notch: type = "spacer"
        case .module: type = "item"
        }
        let path = parentPath + [StyleNode(type: type, id: config.name, classes: classes,
                                           states: itemStates)]
        let style = itemStyle(config, path: path, parentStyle: parentStyle)
        var item = StyledItem(config: config, style: style, states: itemStates, classes: classes,
                              tooltip: state?.result.tooltip, path: path, parentStyle: parentStyle)
        // A spacer is the space between things, and has no way in or out to show.
        if !item.isSpacer {
            item.starting = cascade.startingStyle(for: path, inheriting: parentStyle, inline: inlineRules(config))
            item.leaving = cascade.leavingStyle(for: path, inheriting: parentStyle, inline: inlineRules(config))
        }

        switch config.kind {
        case .group(let children):
            item.children = siblings(children.filter { shown($0) },
                                     parentPath: path, parentStyle: style,
                                     shown: shown, interaction: interaction)
        case .module:
            item.content = state?.result.content.map {
                styleNode($0, parentPath: path, parentStyle: style)
            }
        case .spacer, .notch:
            break
        }
        return item
    }

    private func itemStyle(_ config: ItemConfig, path: [StyleNode], parentStyle: Style) -> Style {
        cascade.style(for: path, inheriting: parentStyle, inline: inlineRules(config)).style
    }

    private func inlineRules(_ config: ItemConfig) -> [Declaration] {
        guard let style = config.style else { return [] }
        return (try? Stylesheet.parseDeclarations(style)) ?? []
    }

    // MARK: - Content

    /// `structural` is where the node sits among its siblings, so `.stacked text:last-child`
    /// reaches the second line of a column as `group item:last-child` reaches an item.
    private func styleNode(_ node: Node, parentPath: [StyleNode], parentStyle: Style,
                           structural: Set<StyleState> = []) -> SceneNode {
        let path = parentPath + [StyleNode(type: node.typeName, id: node.id,
                                           classes: Set(node.classes), states: structural)]
        let style = cascade.style(for: path, inheriting: parentStyle).style
        var styled = SceneNode(kind: node.kind, style: style, id: node.id, classes: node.classes)
        switch node.kind {
        case .row(let container), .column(let container):
            let count = container.children.count
            styled.children = container.children.enumerated().map { index, child in
                var structural: Set<StyleState> = []
                if index == 0 { structural.insert(.firstChild) }
                if index == count - 1 { structural.insert(.lastChild) }
                if count == 1 { structural.insert(.onlyChild) }
                return styleNode(child, parentPath: path, parentStyle: style, structural: structural)
            }
        default:
            break
        }
        return styled
    }
}

/// One bar after the style stage: what layout works from.
public struct StyledBar: Sendable {
    public var config: BarConfig
    public var style: Style
    /// In config order, without the notch marker.
    public var items: [StyledItem]
    /// Where an explicit `notch` marker splits `items`, and on which displays.
    public var notchMarker: (index: Int, mode: NotchMarker)?
    /// The styler that produced this, for the one restyle layout needs.
    public var styler: Styler
}

/// One item after the style stage. Its content nodes carry their styles and no frames yet.
public struct StyledItem: Sendable {
    public var config: ItemConfig
    public var style: Style
    public var states: Set<StyleState>
    public var classes: Set<String>
    public var tooltip: String?
    public var content: SceneNode?
    public var children: [StyledItem] = []
    /// What it transitions from when it appears, and to when it leaves, if the stylesheet says.
    public var starting: Style?
    public var leaving: Style?
    /// What the item was cascaded from, so it can be restyled with one more state.
    var path: [StyleNode]
    var parentStyle: Style

    init(config: ItemConfig, style: Style, states: Set<StyleState>, classes: Set<String>,
         tooltip: String?, path: [StyleNode], parentStyle: Style) {
        self.config = config
        self.style = style
        self.states = states
        self.classes = classes
        self.tooltip = tooltip
        self.path = path
        self.parentStyle = parentStyle
    }

    public var isSpacer: Bool { if case .spacer = config.kind { return true } else { return false } }
    public var isGroup: Bool { if case .group = config.kind { return true } else { return false } }
}
