import Foundation

/// The JSON shape of a content node, and the only enforcement point for it. `schema/
/// content.json` is the published contract; this is what the running system actually checks.
extension Node: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        static let id = Key(stringValue: "id")
        static let `class` = Key(stringValue: "class")
    }

    /// Keys that describe the node rather than name its kind.
    private static let reserved: Set<String> = ["id", "class"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kindKeys = c.allKeys.filter { !Node.reserved.contains($0.stringValue) }

        guard let key = kindKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "a content node needs a kind key, one of "
                    + "text, icon, meter, graph, row, column, spacer, canvas, raster, "
                    + "or a node type registered by a renderer"))
        }
        guard kindKeys.count == 1 else {
            let names = kindKeys.map(\.stringValue).sorted().joined(separator: ", ")
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "a content node has exactly one kind key, found \(kindKeys.count): \(names)"))
        }

        kind = try Node.decodeKind(named: key.stringValue, from: c, key: key, path: decoder.codingPath)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        classes = try c.decodeIfPresent(StringList.self, forKey: .class)?.values ?? []
    }

    private static func decodeKind(named name: String,
                                   from c: KeyedDecodingContainer<Key>,
                                   key: Key,
                                   path: [CodingKey]) throws -> NodeKind {
        func payload() throws -> JSONValue { try c.decode(JSONValue.self, forKey: key) }
        func bad(_ why: String) -> DecodingError {
            DecodingError.dataCorrupted(.init(codingPath: path + [key], debugDescription: why))
        }

        switch name {
        case "text":
            let v = try payload()
            if let s = v.stringValue { return .text(s) }
            if let s = v["value"]?.stringValue { return .text(s) }
            throw bad("text takes a string, or an object with a string \"value\"")

        case "icon":
            let v = try payload()
            if let s = v.stringValue { return .symbolOrFile(s) }
            if let f = v["file"]?.stringValue { return .icon(.file(f)) }
            if let s = (v["symbol"] ?? v["name"])?.stringValue { return .icon(.symbol(s)) }
            throw bad("icon takes an SF Symbol name, or an object with \"file\" or \"symbol\"")

        case "meter":
            let v = try payload()
            if let n = v.doubleValue { return .meter(Meter(value: n)) }
            guard let value = v["value"]?.doubleValue else {
                throw bad("meter needs a numeric \"value\" from 0 to 1")
            }
            return .meter(Meter(value: value, width: v["width"]?.doubleValue))

        case "graph":
            let v = try payload()
            if let a = v.arrayValue { return .graph(Graph(values: a.compactMap(\.doubleValue))) }
            guard let values = v["values"]?.arrayValue else {
                throw bad("graph needs \"values\", an array of numbers")
            }
            return .graph(Graph(values: values.compactMap(\.doubleValue),
                                width: v["width"]?.doubleValue,
                                max: v["max"]?.doubleValue))

        case "row", "column":
            let container = try Node.decodeContainer(from: c, key: key, path: path)
            return name == "row" ? .row(container) : .column(container)

        case "spacer":
            let v = try payload()
            if v.isNull { return .spacer(Spacer()) }
            if let n = v.doubleValue { return .spacer(Spacer(grow: n)) }
            return .spacer(Spacer(grow: v["grow"]?.doubleValue))

        case "canvas":
            let v = try payload()
            guard let ops = v["ops"]?.arrayValue else {
                throw bad("canvas needs \"ops\", the display list")
            }
            return .canvas(CanvasNode(width: v["width"]?.doubleValue,
                                      height: v["height"]?.doubleValue,
                                      ops: ops))

        case "raster":
            let v = try payload()
            guard let width = v["width"]?.doubleValue, let source = v["source"] else {
                throw bad("raster needs \"width\" and \"source\"")
            }
            return .raster(RasterNode(width: width, height: v["height"]?.doubleValue, source: source))

        default:
            // A renderer module's node type (DESIGN.md §9.2). Whether it is *registered* is
            // decided when the scene is built, not here.
            return .custom(name, try payload())
        }
    }

    private static func decodeContainer(from c: KeyedDecodingContainer<Key>,
                                        key: Key,
                                        path: [CodingKey]) throws -> Container {
        if let children = try? c.decode([Node].self, forKey: key) {
            return Container(children: children)
        }
        let nested = try c.nestedContainer(keyedBy: Key.self, forKey: key)
        let children = try nested.decodeIfPresent([Node].self, forKey: Key(stringValue: "children")) ?? []
        let v = try c.decode(JSONValue.self, forKey: key)
        var align: Align?
        if let raw = v["align"]?.stringValue {
            guard let parsed = Align(rawValue: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: path + [key],
                    debugDescription: "align is one of start, center, end, stretch, baseline; got \"\(raw)\""))
            }
            align = parsed
        }
        return Container(gap: v["gap"]?.doubleValue, align: align, children: children)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        let key = Key(stringValue: kind.typeName)
        switch kind {
        case .text(let s):
            try c.encode(s, forKey: key)
        case .icon(.symbol(let s)):
            try c.encode(s, forKey: key)
        case .icon(.file(let f)):
            try c.encode(JSONValue.object(["file": .string(f)]), forKey: key)
        case .meter(let m):
            var o: [String: JSONValue] = ["value": .number(m.value)]
            if let w = m.width { o["width"] = .number(w) }
            try c.encode(JSONValue.object(o), forKey: key)
        case .graph(let g):
            var o: [String: JSONValue] = ["values": .array(g.values.map(JSONValue.number))]
            if let w = g.width { o["width"] = .number(w) }
            if let m = g.max { o["max"] = .number(m) }
            try c.encode(JSONValue.object(o), forKey: key)
        case .row(let container), .column(let container):
            var nested = c.nestedContainer(keyedBy: Key.self, forKey: key)
            if let gap = container.gap { try nested.encode(gap, forKey: Key(stringValue: "gap")) }
            if let align = container.align { try nested.encode(align, forKey: Key(stringValue: "align")) }
            try nested.encode(container.children, forKey: Key(stringValue: "children"))
        case .spacer(let s):
            try c.encode(JSONValue.object(s.grow.map { ["grow": .number($0)] } ?? [:]), forKey: key)
        case .canvas(let canvas):
            var o: [String: JSONValue] = ["ops": .array(canvas.ops)]
            if let w = canvas.width { o["width"] = .number(w) }
            if let h = canvas.height { o["height"] = .number(h) }
            try c.encode(JSONValue.object(o), forKey: key)
        case .raster(let raster):
            var o: [String: JSONValue] = ["width": .number(raster.width), "source": raster.source]
            if let h = raster.height { o["height"] = .number(h) }
            try c.encode(JSONValue.object(o), forKey: key)
        case .custom(_, let payload):
            try c.encode(payload, forKey: key)
        }
        try c.encodeIfPresent(id, forKey: .id)
        if !classes.isEmpty { try c.encode(classes, forKey: .class) }
    }
}

extension NodeKind {
    /// An icon string naming a path is a file; anything else is an SF Symbol.
    static func symbolOrFile(_ s: String) -> NodeKind {
        s.contains("/") || s.hasPrefix("~") ? .icon(.file(s)) : .icon(.symbol(s))
    }
}

// MARK: - Convenience builders

extension Node {
    public static func text(_ s: String, id: String? = nil, classes: [String] = []) -> Node {
        Node(.text(s), id: id, classes: classes)
    }
    public static func icon(_ symbol: String, id: String? = nil, classes: [String] = []) -> Node {
        Node(.icon(.symbol(symbol)), id: id, classes: classes)
    }
    public static func row(gap: Double? = nil, align: Align? = nil, _ children: [Node],
                           id: String? = nil, classes: [String] = []) -> Node {
        Node(.row(Container(gap: gap, align: align, children: children)), id: id, classes: classes)
    }
    public static func column(gap: Double? = nil, align: Align? = nil, _ children: [Node],
                              id: String? = nil, classes: [String] = []) -> Node {
        Node(.column(Container(gap: gap, align: align, children: children)), id: id, classes: classes)
    }
    public static func spacer(grow: Double? = nil) -> Node { Node(.spacer(Spacer(grow: grow))) }
}
