import Foundation
import Testing
@testable import BarioKit

@Suite("Socket client")
struct SocketClientTests {
    func withServer(_ body: @escaping @Sendable (String, StateStore) async throws -> Void) async throws {
        let store = StateStore()
        let service = await MainActor.run { BarioService(store: store) }
        await MainActor.run {
            service.onReload = {}
            service.onStyle = { _ in }
        }
        let path = NSTemporaryDirectory() + "bario-cli-\(UUID().uuidString.prefix(8))/sock"
        let server = SocketServer(path: path) { request in
            await MainActor.run { service }.handle(request)
        }
        await MainActor.run { service.publish = { [weak server] in server?.broadcast($0) } }
        try server.start()
        // The controller wires this up for real; the harness needs it to see state events.
        let feed = Task { [weak server] in
            for await change in await store.changes(matching: "*") {
                server?.broadcast(.state(path: change.path, value: change.value))
            }
        }
        defer { feed.cancel(); server.stop() }
        try await body(path, store)
    }

    @Test("every verb goes out and comes back")
    func verbs() async throws {
        try await withServer { path, store in
            let client = TestClient(path: path)
            try await client.connect()
            defer { client.close() }

            try await client.send("set", ["target": .string("battery"), "data": .object(["pct": .number(43)])])
            #expect(try await client.send("get", ["target": .string("battery.pct")])?.intValue == 43)

            try await client.send("content", ["target": .string("weather"),
                                              "content": .object(["text": .string("21°")])])
            #expect(await store.value(at: "weather.content.text")?.stringValue == "21°")

            try await client.send("emit", ["name": .string("refresh")])
            try await client.send("style", ["css": .string("item { color: red }")])
            try await client.send("reload")
            _ = try await client.send("ping")
        }
    }

    @Test("an error from the bar becomes a thrown error with its message")
    func errors() async throws {
        try await withServer { path, _ in
            let client = TestClient(path: path)
            try await client.connect()
            defer { client.close() }
            var message = ""
            do {
                _ = try await client.send("get", ["target": .string("nope")])
            } catch {
                message = "\(error)"
            }
            #expect(message.contains("nothing is stored under 'nope'"))
        }
    }

    @Test("with nothing listening the message names the socket")
    func notRunning() throws {
        let client = SocketClient(path: NSTemporaryDirectory() + "bario-absent/sock")
        var message = ""
        do { try client.connect() } catch { message = "\(error)" }
        #expect(message.contains("no bario is listening"))
        #expect(message.contains("bario --run"))
    }

    @Test("watch receives what another connection writes")
    func watching() async throws {
        try await withServer { path, store in
            let received = Box()
            // The watch blocks on its own client's thread, so the test goes on writing while it
            // waits; the task here only holds the suspension.
            let watcher = TestClient(path: path)
            try await watcher.connect()
            let task = Task {
                try? await watcher.watch(["state:ci.*"], timeout: 5) { event in
                    received.set(event)
                    return false
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)

            let writer = TestClient(path: path)
            try await writer.connect()
            defer { writer.close() }
            try await writer.send("set", ["target": .string("ci"), "data": .object(["status": .string("green")])])

            // The store publishes, the server routes, the watcher prints.
            for _ in 0..<40 where received.value == nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            await task.value
            watcher.close()
            #expect(received.value?["event"]?.stringValue == "state")
            #expect(received.value?["target"]?.stringValue == "ci")
            _ = store
        }
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: JSONValue?
        func set(_ value: JSONValue) { lock.lock(); stored = value; lock.unlock() }
        var value: JSONValue? { lock.lock(); defer { lock.unlock() }; return stored }
    }
}

@Suite("CLI")
struct CLITests {
    @Test("the verbs are the socket's verbs")
    func verbs() {
        for verb in ["set", "content", "emit", "get", "watch", "style", "reload", "ping"] {
            #expect(CLI.isVerb(verb))
        }
        #expect(!CLI.isVerb("--run"))
        #expect(!CLI.isVerb("--shot"))
    }

    @Test("usage mentions every verb")
    func usage() {
        for verb in CLI.verbs {
            #expect(CLI.usage.contains("bario \(verb)"))
        }
    }
}
