import Foundation
import Testing
@testable import BarioKit

@Suite("Socket protocol")
@MainActor
struct BarioServiceTests {
    func service() -> BarioService {
        BarioService(store: StateStore())
    }

    func request(_ json: String) throws -> SocketRequest {
        try SocketRequest.decode(Data(json.utf8))
    }

    @Test("set merges, get reads it back")
    func setAndGet() async throws {
        let service = self.service()
        let set = await service.handle(try request(#"{"op": "set", "target": "battery", "data": {"pct": 43}}"#))
        #expect(set.ok)

        let get = await service.handle(try request(#"{"id": 7, "op": "get", "target": "battery.pct"}"#))
        #expect(get.ok)
        #expect(get.id == .number(7))
        #expect(get.value?.intValue == 43)
        // The id is echoed on the wire too.
        #expect(get.json["id"]?.intValue == 7)
    }

    @Test("get with no target is the whole store")
    func getAll() async throws {
        let service = self.service()
        _ = await service.handle(try request(#"{"op": "set", "target": "a", "data": {"x": 1}}"#))
        let all = await service.handle(try request(#"{"id": 1, "op": "get"}"#))
        #expect(all.value?.value(at: "a.x")?.intValue == 1)
    }

    @Test("content validates the tree before storing it")
    func content() async throws {
        let service = self.service()
        let ok = await service.handle(try request("""
        {"id": 1, "op": "content", "target": "weather", "content": {"text": "21°"}, "classes": ["warm"]}
        """))
        #expect(ok.ok)
        #expect(await service.store.value(at: "weather.content.text")?.stringValue == "21°")

        let bad = await service.handle(try request("""
        {"id": 2, "op": "content", "target": "weather", "content": {"wat": 1, "text": "x"}}
        """))
        #expect(!bad.ok)
        #expect(bad.error?.contains("exactly one kind key") == true)
    }

    @Test("emit reaches subscribers")
    func emit() async throws {
        let service = self.service()
        nonisolated(unsafe) var published: [SocketEvent] = []
        service.publish = { published.append($0) }
        _ = await service.handle(try request(#"{"op": "emit", "name": "refresh", "payload": {"why": "test"}}"#))
        #expect(published.count == 1)
        #expect(published[0].topic == "event:refresh")
        #expect(published[0].json["payload"]?["why"]?.stringValue == "test")
    }

    @Test("style and reload call out to the controller")
    func styleAndReload() async throws {
        let service = self.service()
        nonisolated(unsafe) var reloads = 0
        nonisolated(unsafe) var css: String?
        service.onReload = { reloads += 1 }
        service.onStyle = { css = $0 }
        #expect(await service.handle(try request(#"{"id": 1, "op": "reload"}"#)).ok)
        #expect(await service.handle(try request(#"{"id": 2, "op": "style", "css": "item { color: red }"}"#)).ok)
        #expect(reloads == 1)
        #expect(css == "item { color: red }")
    }

    @Test("a style delta that does not parse is an error reply, not a broken bar")
    func badStyle() async throws {
        let service = self.service()
        service.onStyle = { css in _ = try Stylesheet.parse(css) }
        let reply = await service.handle(try request(#"{"id": 1, "op": "style", "css": "item { colour: red }"}"#))
        #expect(!reply.ok)
        #expect(reply.error?.contains("did you mean 'color'") == true)
    }

    @Test("ping says who is answering")
    func ping() async throws {
        let reply = await service().handle(try request(#"{"id": 1, "op": "ping"}"#))
        #expect(reply.ok)
        #expect(reply.json["version"]?.stringValue == barioVersion)
    }

    @Test("bad requests are told what is wrong")
    func errors() async throws {
        let service = self.service()
        #expect(throws: Error.self) { try request("not json") }
        #expect(throws: Error.self) { try request("[1, 2]") }
        #expect(throws: Error.self) { try request(#"{"target": "a"}"#) }

        let unknown = await service.handle(try request(#"{"id": 1, "op": "wat"}"#))
        #expect(unknown.error?.contains("unknown op 'wat'") == true)
        #expect(unknown.error?.contains("subscribe") == true)

        let noData = await service.handle(try request(#"{"id": 2, "op": "set", "target": "a"}"#))
        #expect(noData.error?.contains("\"data\"") == true)

        let missing = await service.handle(try request(#"{"id": 3, "op": "get", "target": "nope"}"#))
        #expect(missing.error?.contains("nothing is stored") == true)
    }
}

@Suite("Topics")
struct SocketTopicTests {
    @Test("kind and dotted glob")
    func matching() {
        #expect(SocketTopic("state:battery.*").matches("state:battery.pct"))
        #expect(SocketTopic("state:battery.*").matches("state:battery"))
        #expect(!SocketTopic("state:battery.*").matches("state:wifi.ssid"))
        #expect(!SocketTopic("state:battery.*").matches("click:battery"))
        #expect(SocketTopic("click:volume").matches("click:volume"))
        #expect(SocketTopic("click:*").matches("click:anything"))
        #expect(SocketTopic("*").matches("state:battery.pct"))
        #expect(SocketTopic("click").matches("click:volume"))
        #expect(!SocketTopic("click").matches("scroll:volume"))
    }
}

/// Real time: a real socket, answered from the main actor, so these are in the Makefile's
/// `REAL_TIME` and run in the serial pass.
@Suite("Socket server")
struct SocketServerTests {
    /// A minimal client: connect, write lines, read lines.
    final class Client: @unchecked Sendable {
        let fd: Int32
        var buffer = Data()

        init?(path: String) {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { Darwin.close(fd); return nil }
        }

        deinit { Darwin.close(fd) }

        func send(_ line: String) {
            let data = Data((line + "\n").utf8)
            data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
        }

        /// Reads one line, waiting up to `timeout` seconds — on a thread that is not the
        /// cooperative pool's, because the reply comes from a task that needs one. See
        /// Blocking.swift. `BarioService` is the main actor's, so that reply also waits behind
        /// every `@MainActor` test in the run: the timeout is for a busy machine, not for a
        /// round trip, which takes a millisecond.
        func line(timeout: Double = 30) async -> JSONValue? {
            await offPool { self.blockingLine(timeout: timeout) }
        }

        private func blockingLine(timeout: Double) -> JSONValue? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let index = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<index]
                    buffer.removeSubrange(buffer.startIndex...index)
                    return try? JSONValue(Data(line))
                }
                var chunk = [UInt8](repeating: 0, count: 4096)
                var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&poll, 1, 100) > 0 else { continue }
                let count = read(fd, &chunk, chunk.count)
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
            return nil
        }
    }

    func withServer(_ body: @escaping @Sendable (SocketServer, StateStore) async throws -> Void) async throws {
        let store = StateStore()
        let service = await MainActor.run { BarioService(store: store) }
        let path = NSTemporaryDirectory() + "bario-test-\(UUID().uuidString.prefix(8))/sock"
        let server = SocketServer(path: path) { request in
            await MainActor.run { service }.handle(request)
        }
        await MainActor.run { service.publish = { [weak server] in server?.broadcast($0) } }
        try server.start()
        defer { server.stop() }
        try await body(server, store)
    }

    @Test("a client sets a value and reads it back")
    func roundTrip() async throws {
        try await withServer { server, store in
            guard let client = Client(path: server.path) else { Issue.record("no connection"); return }
            client.send(#"{"op": "set", "target": "ci", "data": {"status": "green"}}"#)
            client.send(#"{"id": 1, "op": "get", "target": "ci.status"}"#)
            let reply = await client.line()
            #expect(reply?["ok"]?.boolValue == true)
            #expect(reply?["value"]?.stringValue == "green")
            #expect(await store.value(at: "ci.status")?.stringValue == "green")
        }
    }

    @Test("a request with no id gets no reply, so a one-shot set is a write and a close")
    func fireAndForget() async throws {
        try await withServer { server, _ in
            guard let client = Client(path: server.path) else { Issue.record("no connection"); return }
            client.send(#"{"op": "set", "target": "a", "data": {"x": 1}}"#)
            client.send(#"{"id": 9, "op": "ping"}"#)
            // The first line back is the ping's, not a reply to the set.
            #expect(await client.line()?["id"]?.intValue == 9)
        }
    }

    @Test("a subscriber receives matching events and nothing else")
    func subscriptions() async throws {
        try await withServer { server, _ in
            guard let watcher = Client(path: server.path),
                  let writer = Client(path: server.path) else { Issue.record("no connection"); return }
            // With an id, so there is an answer to wait for: the connection records its topics
            // before it answers, so once the answer is back the emit below cannot beat it.
            watcher.send(#"{"id": 0, "op": "subscribe", "topics": ["event:*"]}"#)
            #expect(await watcher.line()?["id"]?.intValue == 0)

            writer.send(#"{"op": "emit", "name": "refresh"}"#)
            let event = await watcher.line()
            #expect(event?["event"]?.stringValue == "refresh")
            #expect(event?["topic"]?.stringValue == "event:refresh")

            // The writer subscribed to nothing, so it hears nothing.
            writer.send(#"{"id": 1, "op": "ping"}"#)
            #expect(await writer.line()?["id"]?.intValue == 1)
        }
    }

    @Test("a malformed line is an error, and the connection stays usable")
    func malformed() async throws {
        try await withServer { server, _ in
            guard let client = Client(path: server.path) else { Issue.record("no connection"); return }
            client.send("this is not json")
            let error = await client.line()
            #expect(error?["ok"]?.boolValue == false)
            client.send(#"{"id": 2, "op": "ping"}"#)
            #expect(await client.line()?["id"]?.intValue == 2)
        }
    }

    @Test("a live socket is not stolen, a stale one is cleaned up")
    func staleSockets() async throws {
        try await withServer { server, _ in
            #expect(SocketServer.isListening(at: server.path))
            let second = SocketServer(path: server.path) { _ in .ok(nil) }
            #expect(throws: SocketError.self) { try second.start() }
        }
        // After the first server stops, the path is free again.
        let path = NSTemporaryDirectory() + "bario-stale-\(UUID().uuidString.prefix(8))/sock"
        let first = SocketServer(path: path) { _ in .ok(nil) }
        try first.start()
        first.stop()
        #expect(!SocketServer.isListening(at: path))
        let second = SocketServer(path: path) { _ in .ok(nil) }
        try second.start()
        second.stop()
    }

    @Test("the socket path stays inside sun_path even with a long TMPDIR")
    func pathLength() {
        setenv("BARIO_SOCK", "", 1)
        unsetenv("BARIO_SOCK")
        #expect(SocketServer.defaultPath().utf8.count < 104)
        setenv("BARIO_SOCK", "/tmp/custom-bario.sock", 1)
        #expect(SocketServer.defaultPath() == "/tmp/custom-bario.sock")
        unsetenv("BARIO_SOCK")
    }
}
