import CBarioShim
import Foundation
import CoreVideo
import IOSurface

/// Where native processes hand bario their surfaces (DESIGN.md §9.3): a Mach port published under
/// a name in the login session. An IOSurface crosses processes only as a Mach port, and an app a
/// user opens has no launchd-given name to listen on, so the name is published with
/// `bootstrap_register`, the one deprecated call in this path. The rest of it — the registry,
/// `frame`, the `surface` source — does not depend on how surfaces arrive.
public final class SurfaceListener: @unchecked Sendable {
    public let service: String
    private let port: mach_port_t
    private let source: DispatchSourceMachReceive
    private let queue = DispatchQueue(label: "bario.surfaces")

    /// `BARIO_SURFACES`, or the bundle identifier's `.surfaces`.
    public static func defaultService() -> String {
        if let override = ProcessInfo.processInfo.environment["BARIO_SURFACES"], !override.isEmpty {
            return override
        }
        return "zip.tanner.bario.surfaces"
    }

    @MainActor
    public init(service: String = SurfaceListener.defaultService(), surfaces: SharedSurfaces) throws {
        self.service = service
        var error: kern_return_t = KERN_SUCCESS
        port = bario_surfaces_listen(service, &error)
        guard port != mach_port_t(MACH_PORT_NULL) else {
            throw SocketError("could not publish \(service) for surfaces (kern_return_t \(error))")
        }
        source = DispatchSource.makeMachReceiveSource(port: port, queue: queue)
        source.setEventHandler(handler: SurfaceListener.receive(on: port, into: WeakSurfaces(surfaces)))
        source.resume()
    }

    private struct WeakSurfaces: @unchecked Sendable {
        weak var value: SharedSurfaces?
        init(_ value: SharedSurfaces) { self.value = value }
    }

    /// Runs on the listener's own queue, and a producer is answered there: who holds which name
    /// is decided from `owners`, which lives on this queue, and never waits for the main thread.
    /// Were the answer the main actor's to give, a producer starting up would stall behind
    /// whatever the main thread was busy with — past its timeout, on a busy enough machine. The
    /// registry, which is the main actor's, is told afterwards, in the order things happened.
    private nonisolated static func receive(on port: mach_port_t,
                                            into surfaces: WeakSurfaces) -> @Sendable () -> Void {
        let owners = Owners()
        return {
            var event = bario_surfaces_event()
            while bario_surfaces_receive(port, &event) == 1 {
                let received = Received(event)
                switch received.kind {
                case BARIO_SURFACES_HANDOFF:
                    let outcome = owners.claim(received.name, surfaces: received.surfaces,
                                               owner: received.owner, listener: port)
                    if outcome == .accepted {
                        // Queued before the answer goes: by the time the producer hears it, the
                        // main thread has the surfaces coming.
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                _ = surfaces.value?.register(received.name, surfaces: received.surfaces,
                                                             owner: received.owner)
                            }
                        }
                    }
                    let status: Int32
                    switch outcome {
                    case .accepted: status = BARIO_SURFACES_ACCEPTED
                    case .taken: status = BARIO_SURFACES_TAKEN
                    case .invalid: status = BARIO_SURFACES_INVALID
                    }
                    bario_surfaces_answer(received.reply, status)
                case BARIO_SURFACES_OWNER_GONE:
                    owners.drop(received.owner)
                    // The name may be reused from here on; `drop` below is queued ahead of any
                    // hand-off that could reuse it.
                    mach_port_deallocate(mach_task_self_, received.owner)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { surfaces.value?.drop(owner: received.owner) }
                    }
                default:
                    break
                }
            }
        }
    }

    public func stop() {
        source.cancel()
        bario_surfaces_close(port)
    }

    /// Which producer holds which name, as far as hand-offs go. Only ever touched on the
    /// listener's queue. It applies the rule `SharedSurfaces.register` does — a name is one
    /// producer's for as long as it runs — and is kept in step with the registry, which only
    /// ever learns of a producer from here.
    private final class Owners: @unchecked Sendable {
        private var byName: [String: mach_port_t] = [:]

        func claim(_ name: String, surfaces: [IOSurface], owner: mach_port_t,
                   listener: mach_port_t) -> SharedSurfaces.Outcome {
            guard surfaces.count == 2, !name.isEmpty else {
                mach_port_deallocate(mach_task_self_, owner)
                return .invalid
            }
            if let held = byName[name], held != owner {
                mach_port_deallocate(mach_task_self_, owner)
                return .taken
            }
            // One reference to each producer's port is kept, with a notification for when it
            // dies; a second hand-off from a producer already known gives its reference back.
            let known = byName.values.contains(owner)
            byName[name] = owner
            if known {
                mach_port_deallocate(mach_task_self_, owner)
            } else {
                bario_surfaces_watch(listener, owner)
            }
            return .accepted
        }

        func drop(_ owner: mach_port_t) {
            byName = byName.filter { $0.value != owner }
        }
    }

    /// One message off the port, with its surfaces looked up.
    private struct Received: @unchecked Sendable {
        var kind: bario_surfaces_event_kind
        var name: String
        var surfaces: [IOSurface]
        var owner: mach_port_t
        var reply: mach_port_t

        init(_ event: bario_surfaces_event) {
            kind = event.kind
            var raw = event.name
            name = withUnsafeBytes(of: &raw) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            owner = event.owner
            reply = event.reply
            surfaces = []
            guard kind == BARIO_SURFACES_HANDOFF else { return }
            for port in [event.surfaces.0, event.surfaces.1] {
                if let surface = IOSurfaceLookupFromMachPort(port) { surfaces.append(surface) }
                mach_port_deallocate(mach_task_self_, port)
            }
        }
    }
}

/// A native process's side of shared surfaces: two IOSurfaces handed to a running bar under a
/// name, and a socket to say which one it just drew. Draw into `next`, then `present()`.
public final class SurfaceProducer {
    public let name: String
    public let surfaces: [IOSurface]
    /// The one not showing, which is the one to draw into.
    public private(set) var nextIndex = 1
    private var owner: mach_port_t = mach_port_t(MACH_PORT_NULL)
    private let socket: SocketClient

    /// Premultiplied BGRA surfaces of `width` × `height` pixels.
    public init(name: String, width: Int, height: Int,
                service: String = SurfaceListener.defaultService(), socketPath: String? = nil) throws {
        self.name = name
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height, .bytesPerElement: 4,
            .pixelFormat: UInt32(kCVPixelFormatType_32BGRA),
        ]
        guard let first = IOSurface(properties: properties), let second = IOSurface(properties: properties) else {
            throw SocketError("could not make two \(width)×\(height) surfaces")
        }
        surfaces = [first, second]
        socket = SocketClient(path: socketPath)
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &owner) == KERN_SUCCESS else {
            throw SocketError("could not make a port to own the surfaces with")
        }
        let ports = surfaces.map { IOSurfaceCreateMachPort($0) }
        defer { ports.forEach { mach_port_deallocate(mach_task_self_, $0) } }
        let status = bario_surfaces_hand_off(service, name, ports[0], ports[1], owner, 2000)
        switch status {
        case BARIO_SURFACES_ACCEPTED: break
        case BARIO_SURFACES_TAKEN: throw SocketError("another process is drawing surface '\(name)'")
        case BARIO_SURFACES_INVALID: throw SocketError("bario could not use the surfaces handed over")
        default: throw SocketError("no bario is taking surfaces at \(service). Start one with `bario --run`.")
        }
        try socket.connect()
    }

    deinit {
        socket.disconnect()
        // Its death is how bario learns the surfaces are gone.
        mach_port_mod_refs(mach_task_self_, owner, MACH_PORT_RIGHT_RECEIVE, -1)
    }

    /// The surface to draw the next frame into.
    public var next: IOSurface { surfaces[nextIndex] }

    /// Show what was just drawn into `next`.
    public func present() throws {
        try socket.send("frame", ["surface": .string(name), "index": .number(Double(nextIndex))],
                        expectReply: false)
        nextIndex = 1 - nextIndex
    }
}
