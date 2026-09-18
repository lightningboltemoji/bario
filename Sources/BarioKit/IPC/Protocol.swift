import Foundation

/// One line from a client. DESIGN.md §4.
public struct SocketRequest: Sendable {
    public var id: JSONValue?
    public var op: String
    public var fields: JSONValue

    public init(id: JSONValue? = nil, op: String, fields: JSONValue = .object([:])) {
        self.id = id
        self.op = op
        self.fields = fields
    }

    public subscript(key: String) -> JSONValue? { fields[key] }

    /// `topics` takes one string or a list of them.
    public static func topics(of request: SocketRequest) -> [String] {
        switch request["topics"] {
        case .some(.string(let one)): return [one]
        case .some(.array(let list)): return list.compactMap(\.stringValue)
        default: return []
        }
    }

    public static func decode(_ line: Data) throws -> SocketRequest {
        let json = try JSONValue(line)
        guard case .object(let fields) = json else {
            throw ProtocolError("each line must be a JSON object")
        }
        guard let op = fields["op"]?.stringValue else {
            throw ProtocolError("missing \"op\"; the verbs are \(SocketVerb.names)")
        }
        return SocketRequest(id: fields["id"], op: op, fields: json)
    }
}

public struct SocketReply: Sendable {
    public var id: JSONValue?
    public var ok: Bool
    public var value: JSONValue?
    public var error: String?
    public var extra: [String: JSONValue] = [:]

    public static func ok(_ id: JSONValue?, _ value: JSONValue? = nil,
                          extra: [String: JSONValue] = [:]) -> SocketReply {
        SocketReply(id: id, ok: true, value: value, error: nil, extra: extra)
    }

    public static func failure(_ id: JSONValue?, _ message: String) -> SocketReply {
        SocketReply(id: id, ok: false, value: nil, error: message)
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["ok": .bool(ok)]
        if let id { object["id"] = id }
        if let value { object["value"] = value }
        if let error { object["error"] = .string(error) }
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    public var line: Data {
        var data = json.encoded()
        data.append(0x0A)
        return data
    }
}

/// A line bario sends to a subscriber.
public struct SocketEvent: Sendable {
    /// `state`, `click`, `scroll`, `hover`, `system`, or the name an `emit` gave it.
    public var kind: String
    /// The topic it is matched against: `state:battery.pct`, `click:volume`, `event:refresh`.
    public var topic: String
    public var fields: [String: JSONValue]

    public init(kind: String, topic: String, fields: [String: JSONValue] = [:]) {
        self.kind = kind
        self.topic = topic
        self.fields = fields
    }

    public var json: JSONValue {
        var object = fields
        object["event"] = .string(kind)
        object["topic"] = .string(topic)
        return .object(object)
    }

    public var line: Data {
        var data = json.encoded()
        data.append(0x0A)
        return data
    }

    public static func state(path: String, value: JSONValue) -> SocketEvent {
        SocketEvent(kind: "state", topic: "state:\(path)",
                    fields: ["target": .string(path), "value": value])
    }
}

/// A subscription pattern: `state:battery.*`, `click:volume`, `system:wake`, `*`. The kind
/// before the colon and a dotted glob after it, matched against an event's own topic.
public struct SocketTopic: Sendable, Hashable {
    public var kind: String
    public var path: TopicPattern

    public init(_ pattern: String) {
        let parts = pattern.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            kind = String(parts[0])
            path = TopicPattern(parts[1].isEmpty ? "*" : String(parts[1]))
        } else {
            // A bare pattern is a kind: `*` is everything, `click` is every click.
            kind = String(parts[0])
            path = TopicPattern("*")
        }
    }

    public func matches(_ topic: String) -> Bool {
        let parts = topic.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let otherKind = String(parts.first ?? "")
        let otherPath = parts.count == 2 ? String(parts[1]) : ""
        guard kind == "*" || kind == otherKind else { return false }
        return path.matches(otherPath)
    }
}

public struct ProtocolError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum SocketVerb: String, CaseIterable, Sendable {
    case set, content, emit, get, subscribe, unsubscribe, style, reload, ping, frame

    public static var names: String {
        allCases.map(\.rawValue).sorted().joined(separator: ", ")
    }
}

/// Where the socket verbs are actually carried out. Separate from the transport so the whole
/// protocol is testable without a socket.
@MainActor
public final class BarioService {
    public let store: StateStore
    public weak var host: ModuleHost?
    /// Set by the controller; the socket's `reload` and `style` verbs end up here.
    public var onReload: (() -> Void)?
    public var onStyle: ((String) throws -> Void)?
    /// A producer has drawn into one of a shared surface's pair (DESIGN.md §9.3).
    public var onFrame: ((String, Int?) throws -> Void)?
    /// How an event reaches the subscribers of a connection.
    public var publish: ((SocketEvent) -> Void)?

    public init(store: StateStore, host: ModuleHost? = nil) {
        self.store = store
        self.host = host
    }

    public func handle(_ request: SocketRequest) async -> SocketReply {
        guard let verb = SocketVerb(rawValue: request.op) else {
            return .failure(request.id, "unknown op '\(request.op)'; the verbs are \(SocketVerb.names)")
        }
        do {
            return try await perform(verb, request)
        } catch let error as ProtocolError {
            return .failure(request.id, error.description)
        } catch {
            return .failure(request.id, "\(error)")
        }
    }

    private func perform(_ verb: SocketVerb, _ request: SocketRequest) async throws -> SocketReply {
        switch verb {
        case .ping:
            return .ok(request.id, nil, extra: ["version": .string(barioVersion),
                                                "pid": .number(Double(getpid()))])

        case .set:
            let target = try string(request, "target")
            guard let data = request["data"] else {
                throw ProtocolError("set needs \"data\", the patch to merge into \(target)")
            }
            let dirty = await store.merge(data, at: target)
            host?.markDirty(dirty)
            return .ok(request.id)

        case .content:
            let target = try string(request, "target")
            guard let content = request["content"] else {
                throw ProtocolError("content needs \"content\", a content tree")
            }
            // Validate here rather than letting a bad tree fail silently at render time.
            _ = try JSONDecoder().decode(Node.self, from: content.encoded())
            var patch: [String: JSONValue] = ["content": content]
            if let classes = request["classes"] { patch["classes"] = classes }
            if let tooltip = request["tooltip"] { patch["tooltip"] = tooltip }
            if let visible = request["visible"] { patch["visible"] = visible }
            let dirty = await store.merge(.object(patch), at: target)
            host?.markDirty(dirty)
            return .ok(request.id)

        case .get:
            let target = request["target"]?.stringValue ?? ""
            let value = await store.value(at: target)
            guard let value else {
                throw ProtocolError("nothing is stored under '\(target)'")
            }
            return .ok(request.id, value)

        case .emit:
            let name = try string(request, "name")
            let payload = request["payload"] ?? .object([:])
            if let host {
                // Through the bus, so a socket `emit` and a module's `emit` are one path.
                host.events.post(ModuleEvent(name: name, payload: payload))
            } else {
                publish?(SocketEvent(kind: name, topic: "event:\(name)",
                                     fields: ["name": .string(name), "payload": payload]))
            }
            return .ok(request.id)

        case .style:
            let css = try string(request, "css")
            guard let onStyle else { throw ProtocolError("this bario has no stylesheet to change") }
            try onStyle(css)
            return .ok(request.id)

        case .reload:
            guard let onReload else { throw ProtocolError("this bario has nothing to reload") }
            onReload()
            return .ok(request.id)

        case .frame:
            let surface = try string(request, "surface")
            var index: Int?
            if let raw = request["index"] {
                guard let value = raw.intValue else {
                    throw ProtocolError("frame's \"index\" is 0 or 1, the surface just drawn into")
                }
                index = value
            }
            guard let onFrame else { throw ProtocolError("this bario takes no surfaces") }
            try onFrame(surface, index)
            return .ok(request.id)

        case .subscribe, .unsubscribe:
            // Handled by the connection, which owns the topic list.
            return .ok(request.id)
        }
    }

    private func string(_ request: SocketRequest, _ key: String) throws -> String {
        guard let value = request[key]?.stringValue else {
            throw ProtocolError("\(request.op) needs \"\(key)\"")
        }
        return value
    }
}
