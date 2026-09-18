import Foundation

/// A blocking request/response client. A CLI has nothing better to do while it waits, and
/// the framing is one line out, one line back.
public final class SocketClient {
    public let path: String
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextID = 1

    public init(path: String? = nil) {
        self.path = path ?? SocketServer.defaultPath()
    }

    deinit { disconnect() }

    public func connect() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("could not create a socket: \(errnoText())") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw SocketError("the socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw SocketError("no bario is listening on \(path). Start one with `bario --run`.")
        }
        self.fd = fd
    }

    public func disconnect() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    /// Send a request and wait for its reply. Omitting `id` means fire and forget.
    @discardableResult
    public func send(_ op: String, _ fields: [String: JSONValue] = [:],
                     expectReply: Bool = true, timeout: Double = 5) throws -> JSONValue? {
        var object = fields
        object["op"] = .string(op)
        var id: Int?
        if expectReply {
            id = nextID
            object["id"] = .number(Double(nextID))
            nextID += 1
        }
        try writeLine(JSONValue.object(object))
        guard expectReply else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while let line = try readLine(until: deadline) {
            // Events can arrive between a request and its reply; skip to the one we asked for.
            guard line["id"]?.intValue == id else { continue }
            if line["ok"]?.boolValue == true { return line["value"] ?? .object([:]) }
            throw SocketError(line["error"]?.stringValue ?? "the bar refused that")
        }
        throw SocketError("no answer from \(path) after \(Int(timeout))s")
    }

    /// Subscribe and hand every matching event to `onEvent` until it returns false, or until
    /// `timeout` passes with nothing arriving. `bario watch` uses no timeout; tests do.
    public func watch(_ topics: [String], timeout: Double = .infinity,
                      onEvent: (JSONValue) -> Bool) throws {
        try send("subscribe", ["topics": .array(topics.map(JSONValue.string))])
        let deadline = timeout.isFinite ? Date().addingTimeInterval(timeout) : Date.distantFuture
        while true {
            guard let line = try readLine(until: deadline) else { return }
            guard line["event"] != nil else { continue }
            if !onEvent(line) { return }
        }
    }

    private func writeLine(_ value: JSONValue) throws {
        guard fd >= 0 else { throw SocketError("not connected") }
        var data = value.encoded()
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    throw SocketError("the connection closed while writing")
                }
                offset += written
            }
        }
    }

    private func readLine(until deadline: Date) throws -> JSONValue? {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                guard !line.isEmpty else { continue }
                return try JSONValue(Data(line))
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = deadline == .distantFuture ? 1000 : Int32(min(1000, remaining * 1000) + 1)
            let ready = Darwin.poll(&poll, 1, milliseconds)
            if ready == 0 { continue }
            guard ready > 0 else {
                if errno == EINTR { continue }
                throw SocketError("the connection failed: \(errnoText())")
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
