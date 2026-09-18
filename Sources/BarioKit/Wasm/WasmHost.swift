import Foundation

/// The host imports, in namespace `bario`. Built once and shared by modules and renderers, so
/// a module compiled with a PDK links either way and the two tiers really are the same API.
/// DESIGN.md §5, §9.2.
enum WasmHost {
    static func imports(store: StateStore, item: String, permissions: WasmPermissions,
                        pending: PendingBytes, control: WasmModule.Control,
                        events: EventBus = EventBus()) -> [WasmHostFunction] {


        /// Stash bytes for the guest to `read`, and return their length.
        @Sendable func stash(_ value: JSONValue) -> Int64 {
            let data = value.encoded()
            pending.set([UInt8](data))
            return Int64(data.count)
        }

        @Sendable func json(_ memory: any WasmMemory, _ arguments: [Int64]) throws -> JSONValue {
            let bytes = try memory.read(ptr: Int32(truncatingIfNeeded: arguments[0]),
                                        len: Int32(truncatingIfNeeded: arguments[1]))
            guard !bytes.isEmpty else { return .object([:]) }
            return try JSONValue(Data(bytes))
        }

        return [
            WasmHostFunction("log", [.i32, .i32, .i32]) { memory, arguments in
                let bytes = try memory.read(ptr: Int32(truncatingIfNeeded: arguments[1]),
                                            len: Int32(truncatingIfNeeded: arguments[2]))
                let text = String(decoding: bytes, as: UTF8.self)
                if arguments[0] >= 2 { warn("\(item): \(text)") } else { note("\(item): \(text)") }
                return []
            },

            WasmHostFunction("now", [], [.i64]) { _, _ in
                [Int64(Date().timeIntervalSince1970 * 1000)]
            },

            WasmHostFunction("set", [.i32, .i32]) { memory, arguments in
                let patch = try json(memory, arguments)
                Task { await store.merge(patch, at: item) }
                return []
            },

            WasmHostFunction("get", [.i32, .i32], [.i32]) { memory, arguments in
                let key = try json(memory, arguments)
                // Relative to this item unless the key names an absolute path.
                let path = key.stringValue ?? key["key"]?.stringValue ?? ""
                let absolute = (key["absolute"]?.boolValue ?? false) || path.isEmpty
                    ? path : "\(item).\(path)"
                let value = pending.syncGet(store: store, path: absolute)
                return [stash(value)]
            },

            WasmHostFunction("read", [.i32]) { memory, arguments in
                let bytes = pending.take()
                guard !bytes.isEmpty else { return [] }
                try memory.write(bytes, at: Int32(truncatingIfNeeded: arguments[0]))
                return []
            },

            WasmHostFunction("emit", [.i32, .i32]) { memory, arguments in
                let payload = try json(memory, arguments)
                let name = payload["name"]?.stringValue ?? payload.stringValue ?? "event"
                events.post(ModuleEvent(name: name, payload: payload["payload"] ?? .object([:])),
                            from: item)
                return []
            },

            WasmHostFunction("subscribe", [.i32, .i32]) { memory, arguments in
                let payload = try json(memory, arguments)
                let wanted: [String]
                if let topic = payload.stringValue { wanted = [topic] }
                else if let list = payload.arrayValue { wanted = list.compactMap(\.stringValue) }
                else { wanted = payload["topics"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
                for topic in wanted {
                    events.subscribe(item: item, topic: topic)
                    control.subscriptions.append(topic)
                }
                return []
            },

            WasmHostFunction("set_timer", [.i32], [.i32]) { _, arguments in
                control.timer = Double(arguments[0]) / 1000
                return [0]
            },

            WasmHostFunction("request_frame", []) { _, _ in
                control.wantsFrame = true
                return []
            },

            WasmHostFunction("exec", [.i32, .i32], [.i32]) { memory, arguments in
                guard permissions.exec else {
                    return [stash(WasmModule.denied("exec"))]
                }
                let payload = try json(memory, arguments)
                let argv = payload.arrayValue?.compactMap(\.stringValue)
                    ?? payload["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard let first = argv.first else {
                    return [stash(.object(["error": .string("exec needs an argv")]))]
                }
                do {
                    let result = try ExecModule.run(path: first.contains("/") ? first : "/usr/bin/env",
                                                    arguments: first.contains("/") ? Array(argv.dropFirst()) : argv,
                                                    item: item)
                    return [stash(.object(["status": .number(Double(result.status)),
                                           "stdout": .string(result.stdout),
                                           "stderr": .string(result.stderr)]))]
                } catch {
                    return [stash(.object(["error": .string("\(error)")]))]
                }
            },

            WasmHostFunction("read_file", [.i32, .i32], [.i32]) { memory, arguments in
                let payload = try json(memory, arguments)
                let path = payload.stringValue ?? payload["path"]?.stringValue ?? ""
                guard permissions.allowsReading(path) else {
                    return [stash(WasmModule.denied("fs", detail: path))]
                }
                guard let data = FileManager.default.contents(
                    atPath: (path as NSString).expandingTildeInPath) else {
                    return [stash(.object(["error": .string("no file at \(path)")]))]
                }
                return [stash(.object(["text": .string(String(decoding: data, as: UTF8.self))]))]
            },

            WasmHostFunction("http", [.i32, .i32], [.i32]) { memory, arguments in
                guard permissions.net else {
                    return [stash(WasmModule.denied("net"))]
                }
                let payload = try json(memory, arguments)
                return [stash(WasmModule.http(payload))]
            },
        ]
    }
}
