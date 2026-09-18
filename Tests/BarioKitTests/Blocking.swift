import Foundation
@testable import BarioKit

// Blocking calls, kept off the cooperative pool.
//
// `SocketClient` and the surface hand-off are synchronous on purpose: a CLI has a main thread and
// nothing better to do than wait for its answer. A test is not a CLI. Its body runs on Swift's
// cooperative pool, and that pool has exactly as many threads as the machine has cores — three, on
// a hosted CI runner. A `poll()` loop inside an `async` test pins one of them for as long as its
// timeout, and `SocketServer` answers requests from `Task { await handler(...) }`, on that same
// pool. Pin enough threads and the reply a blocked client is waiting for can never be scheduled:
// every socket test times out at once, and the tests that merely time themselves fail alongside
// them, starved of a thread while they were supposed to be running.
//
// So the blocking waits here happen on queues of our own, and the test awaits them instead.

/// Runs a blocking call on a global queue and suspends until it answers.
func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: body()) }
    }
}

/// `SocketClient`, driven from a thread of its own: one queue per client, so a call that blocks
/// blocks only that client, and the clients a test drives in parallel really are parallel.
final class TestClient: @unchecked Sendable {
    private let client: SocketClient
    private let queue = DispatchQueue(label: "zip.tanner.bario.test.client")

    init(path: String) {
        client = SocketClient(path: path)
    }

    func connect() async throws {
        try await offQueue { try self.client.connect() }
    }

    /// Only after the last `await` has come back: nothing may be in flight on the queue.
    func close() {
        client.disconnect()
    }

    @discardableResult
    func send(_ op: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue? {
        try await offQueue { try self.client.send(op, fields) }
    }

    func watch(_ topics: [String], timeout: Double,
               onEvent: @escaping @Sendable (JSONValue) -> Bool) async throws {
        try await offQueue { try self.client.watch(topics, timeout: timeout, onEvent: onEvent) }
    }

    private func offQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
