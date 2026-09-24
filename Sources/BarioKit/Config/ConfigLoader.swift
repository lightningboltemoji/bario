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
            case "source":
                config.sources.append(try source(node))
            case "mode":
                config.modes.append(try mode(node))
            default:
                throw KDLError("'\(node.name)' is not a top-level node; expected bar, renderer, source or mode",
                               at: node.position)
            }
        }
        if config.bars.isEmpty {
            throw KDLError("the config has no bar node, so there is nothing to show",
                           at: nodes.first?.position ?? .start)
        }
        try check(config)
        return config
    }

    /// What can only be checked once everything is read: modes named before they are
    /// declared, and sources sharing a key in the store with something else.
    private static func check(_ config: Config) throws {
        var modes: Set<String> = []
        for mode in config.modes where !modes.insert(mode.name).inserted {
            throw KDLError("there are two modes called \"\(mode.name)\"", at: mode.position)
        }
        let items = config.bars.flatMap(\.items).flatMap(\.flattened)
        for item in items {
            for name in [item.when, item.unless].compactMap({ $0 }) where !modes.contains(name) {
                let known = modes.isEmpty ? "there are none" : "the ones that exist are "
                    + modes.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                throw KDLError("\(item.name) names a mode \"\(name)\" that no mode node declares; \(known)",
                               at: item.position)
            }
        }
        var keys = Set(items.map(\.name))
        for source in config.sources where !keys.insert(source.name).inserted {
            throw KDLError("source \"\(source.name)\" writes under a key an item or another source already has",
                           at: source.position)
        }
    }

    // MARK: - source and mode

    /// `source "emira" module="exec" interval="watch" { command "emira" "watch" }`: a module with
    /// no bubble, which only writes state.
    private static func source(_ node: KDLNode) throws -> ItemConfig {
        guard node.argument(0)?.value.stringValue != nil else {
            throw KDLError("source needs the name its state is written under, e.g. source \"emira\" module=\"exec\"",
                           at: node.position)
        }
        let source = try parseItem(node, ordinal: 0)
        let shown = source.format != nil || source.content != nil || source.template != nil
            || source.when != nil || source.unless != nil || source.actions != Actions()
        if shown {
            throw KDLError("source \"\(source.name)\" is never shown, so it takes no format, content, "
                           + "when, unless or on-click; show its state from an item", at: node.position)
        }
        return source
    }

    /// `mode "guide" { while "emira.moving"; changed "emira.focus"; hold "700ms" }`
    private static func mode(_ node: KDLNode) throws -> ModeConfig {
        guard let name = node.argument(0)?.value.stringValue, !name.isEmpty else {
            throw KDLError("mode needs a name, e.g. mode \"guide\" { changed \"emira.focus\" }", at: node.position)
        }
        var mode = ModeConfig(name: name, position: node.position)
        for child in node.children {
            switch child.name {
            case "while", "changed":
                let paths = child.arguments.compactMap(\.value.stringValue)
                guard !paths.isEmpty, paths.count == child.arguments.count else {
                    throw KDLError("\(child.name) takes the paths it watches, e.g. \(child.name) \"emira.focus\"",
                                   at: child.position)
                }
                if child.name == "while" { mode.whilePaths += paths } else { mode.changed += paths }
            case "hold":
                guard let value = child.argument(0)?.value,
                      let seconds = value.doubleValue ?? value.stringValue.flatMap(parseDuration),
                      seconds >= 0 else {
                    throw KDLError("hold takes a duration like \"700ms\"", at: child.position)
                }
                mode.hold = seconds
            default:
                throw KDLError("'\(child.name)' is not part of a mode; expected while, changed or hold",
                               at: child.position)
            }
        }
        guard !mode.paths.isEmpty else {
            throw KDLError("mode \"\(name)\" has nothing to turn it on; give it while or changed",
                           at: node.position)
        }
        return mode
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
            case _ where styling.contains(child.name):
                throw movedToStylesheet(child.name, child.arguments.map(\.value), selector: "bar",
                                        at: child.position)
            case "height":
                let height = try number(child, "height")
                guard height > 0 else {
                    throw KDLError("height takes the bar's height in points, from the top of the screen",
                                   at: child.position)
                }
                bar.height = height
            case "align":
                bar.align = try enumeration(child, "align", Align.self)
            case "hole":
                bar.hole = try hole(child)
            case "notch" where child.argument(0)?.value.stringValue.flatMap(NotchPolicy.init) != nil:
                bar.notch = try enumeration(child, "notch", NotchPolicy.self)
            case "item", "group", "spacer", "notch":
                counter += 1
                bar.items.append(try parseItem(child, ordinal: counter))
            default:
                throw KDLError("'\(child.name)' is not something a bar contains; expected "
                               + "height, align, hole, notch, item, group or spacer",
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
            // The argument is the marker's mode, not its name.
            item.name = "\(node.name)-\(ordinal)"
            switch node.argument(0)?.value.stringValue {
            case nil: item.kind = .notch(.always)
            case NotchMarker.ifPresent.rawValue: item.kind = .notch(.ifPresent)
            default:
                throw KDLError("notch takes \"avoid\" or \"ignore\" as the bar's policy, or "
                               + "\"if-present\" as a marker", at: node.position)
            }
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
                throw KDLError("\(node.name) \"\(item.name)\" needs module=\"…\"", at: node.position)
            }
            item.kind = .module(module)
        }

        for property in node.properties {
            switch property.name {
            case "module", "display": continue         // handled above
            case "format": item.format = try string(property)
            case "priority": item.priority = try integer(property)
            case "grow": item.sizing.grow = try double(property)
            case "shrink": item.sizing.shrink = try double(property)
            case _ where styling.contains(property.name):
                throw movedToStylesheet(property.name, [property.value], selector: "#\(item.name)",
                                        at: property.position)
            case "align":
                guard let raw = property.value.stringValue, let align = Align(rawValue: raw) else {
                    throw KDLError("align is one of \(Align.allNames)", at: property.position)
                }
                item.align = align
            case "style": item.style = try string(property)
            case "hidden-until-set": item.hiddenUntilSet = property.value.boolValue ?? true
            case "when": item.when = try string(property)
            case "unless": item.unless = try string(property)
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
            case "gap" where !item.children.isEmpty:
                throw movedToStylesheet(child.name, child.arguments.map(\.value), selector: "#\(item.name)",
                                        at: child.position)
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
                (item.content, item.template) = try child.children[0].contentOrTemplate()
            default: continue
            }
        }
        return item
    }

    // MARK: - Styling

    /// How things look is the stylesheet's, where it cascades, transitions and follows
    /// `@media`. A value here would override all of that, so these are errors that say where
    /// the value goes instead.
    private static let styling: Set<String> = ["padding", "gap", "width", "min-width", "max-width"]

    private static func movedToStylesheet(_ name: String, _ values: [KDLValue], selector: String,
                                          at position: KDLPosition) -> KDLError {
        let value = values.map { $0.doubleValue.map { "\(KDLValue.number($0).literal)pt" } ?? $0.literal }
        let css = value.isEmpty ? "…" : value.joined(separator: " ")
        return KDLError("\(name) is styling, so it goes in style.css: \(selector) { \(name): \(css) }",
                        at: position)
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
