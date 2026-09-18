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
/// `source surface="wave"`).
extension KDLNode {
    public func content() throws -> Node {
        let json = try contentJSON()
        do {
            return try JSONDecoder().decode(Node.self, from: json.encoded())
        } catch let error as DecodingError {
            throw KDLError(error.contentMessage, at: position)
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
                _ = try child.content()
                return try child.contentJSON()
            })
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
