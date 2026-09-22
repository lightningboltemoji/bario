import Foundation

/// A Unix domain socket carrying newline-delimited JSON. POSIX sockets on a dispatch queue
/// rather than Network.framework: a listener, an accept source and one read source per
/// connection is all this needs, and the framing stays honest. DESIGN.md §4.
public final class SocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (SocketRequest) async -> SocketReply

    public let path: String
    private let queue = DispatchQueue(label: "zip.tanner.bario.socket")
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: Connection] = [:]

    /// 8MB: enough for an inline PNG in a `raster` node, small enough that a runaway writer
    /// cannot exhaust memory.
    static let maximumLineBytes = 8 * 1024 * 1024

    public init(path: String? = nil, handler: @escaping Handler) {
        self.path = path ?? SocketServer.defaultPath()
        self.handler = handler
    }

    deinit { stop() }

    // MARK: - Path

    /// `$TMPDIR/bario/sock`, per-user and already mode 0700. `BARIO_SOCK` overrides it.
    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["BARIO_SOCK"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        let candidate = NSTemporaryDirectory() + "bario/sock"
        // sun_path is 104 bytes; a sandbox's TMPDIR can be long enough to matter.
        if candidate.utf8.count < 100 { return candidate }
        return "/tmp/bario-\(getuid())/sock"
    }

    // MARK: - Lifecycle

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try clearStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("could not create a socket: \(errnoText())") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw SocketError("the socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketError("could not bind \(path): \(errnoText())")
        }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else {
            close(fd)
            throw SocketError("could not listen on \(path): \(errnoText())")
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        lock.lock()
        let open = Array(connections.values)
        connections = [:]
        lock.unlock()
        open.forEach { $0.close() }
        unlink(path)
    }

    /// A socket file left behind by a crash is safe to remove; one a live bario is listening
    /// on is not, so probe it with a connect first.
    private func clearStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if SocketServer.isListening(at: path) {
            throw SocketError("another bario is already listening on \(path)")
        }
        unlink(path)
    }

    public static func isListening(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    // MARK: - Connections

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let connection = Connection(fd: fd, queue: queue, handler: handler) { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.connections.removeValue(forKey: ObjectIdentifier(connection))
            self.lock.unlock()
        }
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.resume()
    }

    /// Send an event to every connection that subscribed to a matching topic.
    public func broadcast(_ event: SocketEvent) {
        lock.lock()
        let open = Array(connections.values)
        lock.unlock()
        let line = event.line
        for connection in open where connection.isSubscribed(to: event.topic) {
            connection.write(line)
        }
    }

    public var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    final class Connection: @unchecked Sendable {
        private let fd: Int32
        private let queue: DispatchQueue
        private let handler: Handler
        private let onClose: (Connection) -> Void
        private var source: DispatchSourceRead?
        private var buffer = Data()
        private let lock = NSLock()
        private var topics: [SocketTopic] = []
        private var closed = false
        /// The request being handled, so the next one can queue behind it. Queue-confined.
        private var pending: Task<Void, Never>?

        init(fd: Int32, queue: DispatchQueue, handler: @escaping Handler,
             onClose: @escaping (Connection) -> Void) {
            self.fd = fd
            self.queue = queue
            self.handler = handler
            self.onClose = onClose
        }

        func resume() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            source.resume()
            self.source = source
        }

        func close() {
            lock.lock()
            guard !closed else { lock.unlock(); return }
            closed = true
            lock.unlock()
            source?.cancel()
            source = nil
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else {
                finish()
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > SocketServer.maximumLineBytes {
                write(SocketReply.failure(nil, "a line longer than 8MB; closing").line)
                finish()
                return
            }
            while let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else { continue }
                dispatch(Data(line))
            }
        }

        private func finish() {
            onClose(self)
            close()
        }

        private func dispatch(_ line: Data) {
            let request: SocketRequest
            do {
                request = try SocketRequest.decode(line)
            } catch {
                write(SocketReply.failure(nil, "\(error)").line)
                return
            }
            // The connection owns its own subscriptions; everything else goes to the service.
            switch request.op {
            case "subscribe":
                let added = SocketRequest.topics(of: request).map(SocketTopic.init)
                lock.lock(); topics.append(contentsOf: added); lock.unlock()
            case "unsubscribe":
                let removed = SocketRequest.topics(of: request)
                lock.lock()
                if removed.isEmpty { topics = [] }
                else { topics.removeAll { topic in removed.contains { SocketTopic($0) == topic } } }
                lock.unlock()
            default:
                break
            }

            let handler = self.handler
            // One at a time, in the order they arrived. Two lines can come off the socket in a
            // single read, and a task each would let the second be answered first — a client that
            // writes `set` and then `get` is entitled to read its own write back. `pending` is
            // only ever touched here, on the queue the read source runs on.
            let previous = pending
            pending = Task { [weak self] in
                await previous?.value
                let reply = await handler(request)
                // No id means no reply: a one-shot `set` is a write and a close.
                guard request.id != nil else { return }
                self?.write(reply.line)
            }
        }

        func isSubscribed(to topic: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return topics.contains { $0.matches(topic) }
        }

        func write(_ data: Data) {
            lock.lock()
            let isClosed = closed
            lock.unlock()
            guard !isClosed else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written <= 0 {
                        if errno == EINTR { continue }
                        return
                    }
                    offset += written
                }
            }
        }
    }
}

public struct SocketError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

func errnoText() -> String { String(cString: strerror(errno)) }
