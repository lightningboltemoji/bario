import Foundation

/// Turns parsed KDL into a validated `Config`. Every failure carries the position of the
/// thing that failed, because a config error's whole job is to say where it is.
public enum ConfigLoader {
    // MARK: - Files

    public static let directoryNames = ["bario"]

    /// `~/.config/bario/`, then `~/Library/Application Support/bario/`. `BARIO_CONFIG_DIR`
    /// overrides both.
    public static var searchDirectories: [URL] {
        if let override = ProcessInfo.processInfo.environment["BARIO_CONFIG_DIR"] {
            return [URL(fileURLWithPath: (override as NSString).expandingTildeInPath)]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".config/bario", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/bario", isDirectory: true),
        ]
    }

    /// Where a config-directory file lives, or nil if there isn't one yet.
    public static func locate(_ filename: String) -> URL? {
        if filename == "config.kdl", let override = ProcessInfo.processInfo.environment["BARIO_CONFIG"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// The config as it should be right now: the user's file, or the built-in default when
    /// there isn't one, so a first run shows a bar rather than an empty strip.
    public static func load() throws -> (config: Config, source: URL?) {
        guard let url = locate("config.kdl") else {
            return (try parse(defaultConfigKDL, source: "<default config>"), nil)
        }
        return (try parse(String(contentsOf: url, encoding: .utf8), source: url.path), url)
    }

    public static func parse(_ text: String, source: String? = nil) throws -> Config {
        try build(KDL.parse(text, source: source))
    }

    // MARK: - Document

    public static func build(_ nodes: [KDLNode]) throws -> Config {
        var config = Config()
        for node in nodes {
            switch node.name {
            case "bar":
                config.bars.append(try bar(node))
            case "renderer":
                config.renderers.append(try renderer(node))
            default:
                throw KDLError("'\(node.name)' is not a top-level node; expected bar or renderer",
                               at: node.position)
            }
        }
        if config.bars.isEmpty {
            throw KDLError("the config has no bar node, so there is nothing to show",
                           at: nodes.first?.position ?? .start)
        }
        return config
    }

    private static func renderer(_ node: KDLNode) throws -> RendererConfig {
        guard let type = node.argument(0)?.value.stringValue else {
            throw KDLError("renderer needs the node type it draws, e.g. renderer \"ring\" path=\"…\"",
                           at: node.position)
        }
        guard let path = node.property("path")?.value.stringValue else {
            throw KDLError("renderer \"\(type)\" needs path=\"…/\(type).wasm\"", at: node.position)
        }
        return RendererConfig(nodeType: type, path: expand(path), options: node.json, position: node.position)
    }

    // MARK: - bar

    private static func bar(_ node: KDLNode) throws -> BarConfig {
        var bar = BarConfig(position: node.position)
        if let filter = node.property("display") {
            bar.display = try displayFilter(filter)
        }
        var counter = 0
        for child in node.children {
            switch child.name {
            case "padding":
                bar.padding = try insets(child)
            case "gap":
                bar.gap = try number(child, "gap")
            case "height":
                bar.height = try number(child, "height")
            case "align":
                bar.align = try enumeration(child, "align", Align.self)
            case "hole":
                bar.hole = try hole(child)
            case "notch" where child.arguments.first != nil:
                bar.notch = try enumeration(child, "notch", NotchPolicy.self)
            case "item", "group", "spacer", "notch":
                counter += 1
                bar.items.append(try parseItem(child, ordinal: counter))
            default:
                throw KDLError("'\(child.name)' is not something a bar contains; expected "
                               + "padding, gap, height, align, hole, notch, item, group or spacer",
                               at: child.position)
            }
        }
        return bar
    }

    private static func displayFilter(_ property: KDLProperty) throws -> DisplayFilter {
        guard let raw = property.value.stringValue else {
            throw KDLError("display takes a name, \"built-in\" or \"external\"", at: property.position)
        }
        switch raw {
        case "built-in", "builtin", "internal": return .builtIn
        case "external": return .external
        case "any", "all": return .any
        default: return .named(raw)
        }
    }

    private static func hole(_ node: KDLNode) throws -> HoleConfig {
        var hole = HoleConfig()
        for property in node.properties {
            switch property.name {
            case "radius": hole.radius = try double(property)
            case "feather": hole.feather = try double(property)
            case "proximity": hole.proximity = try double(property)
            case "click":
                guard let raw = property.value.stringValue, let click = HoleClick(rawValue: raw) else {
                    throw KDLError("hole click is \"reveal\" or \"none\"", at: property.position)
                }
                hole.click = click
            default:
                throw KDLError("hole takes radius, feather, proximity and click, not '\(property.name)'",
                               at: property.position)
            }
        }
        if hole.feather > hole.radius { hole.feather = hole.radius }
        return hole
    }

    // MARK: - items

    private static func parseItem(_ node: KDLNode, ordinal: Int) throws -> ItemConfig {
        var item = ItemConfig(name: node.argument(0)?.value.stringValue ?? "\(node.name)-\(ordinal)",
                              kind: .spacer,
                              position: node.position)
        item.options = node.json

        switch node.name {
        case "spacer":
            item.kind = .spacer
            item.sizing.grow = 1
        case "notch":
            item.kind = .notch
        case "group":
            var counter = 0
            var children: [ItemConfig] = []
            for child in node.children where ["item", "group", "spacer"].contains(child.name) {
                counter += 1
                children.append(try parseItem(child, ordinal: counter))
            }
            guard !children.isEmpty else {
                throw KDLError("group \"\(item.name)\" has no items in it", at: node.position)
            }
            item.kind = .group(children)
        default:
            guard let module = node.property("module")?.value.stringValue else {
                throw KDLError("item \"\(item.name)\" needs module=\"…\"", at: node.position)
            }
            item.kind = .module(module)
        }

        for property in node.properties {
            switch property.name {
            case "module", "display": continue         // handled above
            case "format": item.format = try string(property)
            case "priority": item.priority = try integer(property)
            case "width": item.sizing.width = try double(property)
            case "min-width": item.sizing.minWidth = try double(property)
            case "max-width": item.sizing.maxWidth = try double(property)
            case "grow": item.sizing.grow = try double(property)
            case "shrink": item.sizing.shrink = try double(property)
            case "gap": item.gap = try double(property)
            case "align":
                guard let raw = property.value.stringValue, let align = Align(rawValue: raw) else {
                    throw KDLError("align is one of \(Align.allNames)", at: property.position)
                }
                item.align = align
            case "style": item.style = try string(property)
            case "hidden-until-set": item.hiddenUntilSet = property.value.boolValue ?? true
            case "interval": item.interval = try interval(property)
            case "on-click": item.actions.click = try string(property)
            case "on-right-click": item.actions.rightClick = try string(property)
            case "on-scroll": item.actions.scroll = try string(property)
            default:
                // Module options are the module's business, not ours: they stay in `options`
                // and reach the module untouched. DESIGN.md §3.
                continue
            }
        }

        for child in node.children {
            switch child.name {
            case "gap" where !item.children.isEmpty: item.gap = try number(child, "gap")
            case "content":
                guard item.moduleName != nil else {
                    throw KDLError("only an item has content; a \(node.name) is laid out, not rendered",
                                   at: child.position)
                }
                guard child.arguments.isEmpty, child.properties.isEmpty, child.children.count == 1 else {
                    throw KDLError("content holds one node, e.g. content { text \"hello\" }; "
                                   + "put several in a row", at: child.position)
                }
                guard item.format == nil else {
                    throw KDLError("item \"\(item.name)\" has both format= and content; it shows one or "
                                   + "the other", at: child.position)
                }
                item.content = try child.children[0].content()
            default: continue
            }
        }
        return item
    }

    // MARK: - Scalars

    private static func interval(_ property: KDLProperty) throws -> Interval {
        if let seconds = property.value.doubleValue { return .seconds(seconds) }
        guard let raw = property.value.stringValue else {
            throw KDLError("interval takes a duration like \"10m\", \"watch\", or a number of seconds",
                           at: property.position)
        }
        if raw == "watch" { return .watch }
        guard let seconds = parseDuration(raw) else {
            throw KDLError("'\(raw)' is not a duration; write \"500ms\", \"2s\", \"10m\", \"1h\" or \"watch\"",
                           at: property.position)
        }
        return .seconds(seconds)
    }

    /// `500ms`, `2s`, `10m`, `1h`, or a bare number of seconds.
    public static func parseDuration(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        for (suffix, scale) in [("ms", 0.001), ("s", 1.0), ("m", 60.0), ("h", 3600.0)]
        where text.hasSuffix(suffix) {
            guard let value = Double(text.dropLast(suffix.count)) else { return nil }
            return value * scale
        }
        return Double(text)
    }

    private static func insets(_ node: KDLNode) throws -> Insets {
        let values = try node.arguments.map { argument -> Double in
            guard let value = argument.value.doubleValue else {
                throw KDLError("padding takes numbers, found \(argument.value.literal)", at: argument.position)
            }
            return value
        }
        guard let insets = Insets(values: values) else {
            throw KDLError("padding takes 1 to 4 numbers (all, vertical horizontal, …), found \(values.count)",
                           at: node.position)
        }
        return insets
    }

    private static func number(_ node: KDLNode, _ name: String) throws -> Double {
        guard let value = node.argument(0)?.value.doubleValue else {
            throw KDLError("\(name) takes a number", at: node.position)
        }
        return value
    }

    private static func enumeration<T: RawRepresentable & CaseIterable>(
        _ node: KDLNode, _ name: String, _ type: T.Type
    ) throws -> T where T.RawValue == String {
        let names = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        guard let raw = node.argument(0)?.value.stringValue, let value = T(rawValue: raw) else {
            throw KDLError("\(name) is one of \(names)", at: node.position)
        }
        return value
    }

    private static func string(_ property: KDLProperty) throws -> String {
        guard let value = property.value.stringValue else {
            throw KDLError("\(property.name) takes a string, found \(property.value.literal)",
                           at: property.position)
        }
        return value
    }

    private static func double(_ property: KDLProperty) throws -> Double {
        guard let value = property.value.doubleValue else {
            throw KDLError("\(property.name) takes a number, found \(property.value.literal)",
                           at: property.position)
        }
        return value
    }

    private static func integer(_ property: KDLProperty) throws -> Int {
        let value = try double(property)
        guard value == value.rounded() else {
            throw KDLError("\(property.name) takes a whole number, found \(property.value.literal)",
                           at: property.position)
        }
        return Int(value)
    }

    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

extension Align {
    public static var allNames: String {
        allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
    }
}

/// What bario shows before there is a config file: enough of a bar to prove it works.
public let defaultConfigKDL = """
// bario's built-in default. Copy this to ~/.config/bario/config.kdl and make it yours.
bar {
  padding 0 8
  gap 6
  hole radius=40 feather=0 proximity=80 click="reveal"

  item "app" module="front-app" priority=10 format="{name}" max-length=28
  spacer
  notch
  spacer
  item "clock" module="clock" format="EEE d MMM  HH:mm" priority=10
  group "status" {
    item "wifi" module="wifi" format="{icon}"
    item "volume" module="volume" format="{icon}"
    item "battery" module="battery" format="{icon} {pct}%" {
      low 20
    }
  }
}
"""
