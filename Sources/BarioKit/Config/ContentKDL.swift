import Foundation

/// A content tree written in KDL, for an item whose content is known when the config is:
///
/// ```kdl
/// item "wave" module="data" {
///   content {
///     raster width=80 height=20 {
///       source surface="wave"
///     }
///   }
/// }
/// ```
///
/// It is the JSON content model (DESIGN.md §2) node for node, and goes through the same decoder
/// a pushed tree does, so the two cannot disagree. A node's name is its kind, and `id=` and
/// `class=` belong to the node. A row's or column's child nodes are its children, beside `gap=`
/// and `align=`. Any other kind takes its payload either as one argument (`text "73%"`,
/// `icon "wifi"`, `meter 0.7`), as several (a list, for `graph`), or as properties and child
/// nodes, which become the payload's fields (`meter value=0.7 width=24`,
/// `source surface="wave"`). A canvas's child nodes are its ops, in order (`canvasOp()`).
///
/// A tree with a slot in any of its strings (`graph values="{history}"`) is a template instead,
/// filled from state on every render ([20-stats-widgets.md]). Its values are not known until
/// then, so what is checked here is only what can be: the format strings themselves, and
/// every subtree that has no slot in it.
extension KDLNode {
    public func content() throws -> Node {
        let json = try template(of: contentJSON()).plain
        do {
            return try JSONDecoder().decode(Node.self, from: json.encoded())
        } catch let error as DecodingError {
            throw KDLError(error.contentMessage, at: position)
        }
    }

    /// Plain content, decoded now, or a template when a string in it has a slot.
    public func contentOrTemplate() throws -> (content: Node?, template: ContentTemplate?) {
        let template = try template(of: contentJSON())
        return template.hasSlots ? (nil, template) : (try content(), nil)
    }

    private func template(of json: JSONValue) throws -> ContentTemplate {
        do {
            return try ContentTemplate(json)
        } catch {
            throw KDLError("\(error)", at: position)
        }
    }

    private func contentJSON() throws -> JSONValue {
        var object: [String: JSONValue] = [:]
        var fields = properties
        for property in fields where property.name == "id" || property.name == "class" {
            guard property.value.stringValue != nil else {
                throw KDLError("\(property.name) is a string", at: property.position)
            }
            object[property.name] = property.value.json
        }
        fields.removeAll { $0.name == "id" || $0.name == "class" }

        switch name {
        case "row", "column":
            guard arguments.isEmpty else {
                throw KDLError("\(name) takes gap= and align=, and its children as nodes inside it",
                               at: position)
            }
            var payload: [String: JSONValue] = [:]
            for property in fields { payload[property.name] = property.value.json }
            // Each child is checked on its own, so an error points at the child that has it.
            payload["children"] = .array(try children.map { child in
                let json = try child.contentJSON()
                if try !child.template(of: json).hasSlots { _ = try child.content() }
                return json
            })
            object[name] = .object(payload)
        case "canvas":
            guard arguments.isEmpty else {
                throw KDLError("canvas takes width= and height=, and its ops as nodes inside it",
                               at: position)
            }
            var payload: [String: JSONValue] = [:]
            for property in fields { payload[property.name] = property.value.json }
            payload["ops"] = .array(try children.map { try $0.canvasOp() })
            object[name] = .object(payload)
        default:
            if fields.isEmpty && children.isEmpty {
                switch arguments.count {
                case 0: object[name] = .object([:])
                case 1: object[name] = arguments[0].value.json
                default: object[name] = .array(arguments.map(\.value.json))
                }
            } else {
                guard arguments.isEmpty else {
                    throw KDLError("\(name) takes its value as an argument or as properties, not both; "
                                   + "beside other properties, write value=…", at: arguments[0].position)
                }
                // Properties and child nodes are the payload's fields, as any module option is.
                object[name] = KDLNode(name: name, properties: fields, children: children,
                                       position: position).json
            }
        }
        return .object(object)
    }

    /// One op of a canvas's display list, in order, which is what a JSON object of child nodes
    /// cannot keep ([12-canvas-node.md]). The op's name is its key. `fill`, `stroke` and `clip`
    /// take their path as child nodes, a command each (`line 4 8`), and the paint as an
    /// argument and properties (`stroke "accent" width=2`); `group` takes ops. Any other op
    /// takes its value as its argument, and its other fields as properties and child nodes, as
    /// content does: `image "gear" { rect 0 0 16 16 }`.
    private func canvasOp() throws -> JSONValue {
        var op: [String: JSONValue] = [:]
        switch name {
        case "fill", "stroke", "clip":
            var paint: [String: JSONValue] = [:]
            if let color = arguments.first { paint["color"] = color.value.json }
            for property in properties { paint[property.name] = property.value.json }
            var path: [JSONValue] = []
            for command in children {
                if command.name == "dash" {
                    paint["dash"] = .array(command.arguments.map(\.value.json))
                    continue
                }
                guard command.properties.isEmpty, command.children.isEmpty else {
                    throw KDLError("a path command is a name and its numbers, e.g. line 4 8",
                                   at: command.position)
                }
                path.append(.array([.string(command.name)] + command.arguments.map(\.value.json)))
            }
            guard arguments.count <= 1, name != "clip" || paint.isEmpty else {
                throw KDLError(name == "clip" ? "clip takes only a path, as nodes inside it"
                               : "\(name) takes one colour; give the rest as width=, cap= or join=",
                               at: position)
            }
            if name == "clip" {
                op[name] = .array(path)
            } else {
                op[name] = .object(paint)
                op["path"] = .array(path)
            }
        case "group":
            guard arguments.isEmpty, properties.isEmpty else {
                throw KDLError("group takes only ops, as nodes inside it", at: position)
            }
            op[name] = .array(try children.map { try $0.canvasOp() })
        default:
            switch arguments.count {
            case 0: op[name] = .object([:])
            case 1: op[name] = arguments[0].value.json
            default: op[name] = .array(arguments.map(\.value.json))
            }
            for property in properties { op[property.name] = property.value.json }
            for child in children { op[child.name] = child.json }
        }
        let json = JSONValue.object(op)
        // Checked now, so a mistake points at its line rather than warning at every layout; an
        // op with a slot in it is checked once it is filled.
        if try !template(of: json).hasSlots {
            do {
                _ = try CanvasOp.parse(json)
            } catch let error as CanvasError {
                throw KDLError(error.description, at: position)
            }
        }
        return json
    }
}

extension DecodingError {
    /// What the content decoder said, without the coding path it said it at.
    var contentMessage: String {
        switch self {
        case .dataCorrupted(let context), .keyNotFound(_, let context),
             .typeMismatch(_, let context), .valueNotFound(_, let context):
            return context.debugDescription
        @unknown default:
            return "\(self)"
        }
    }
}
