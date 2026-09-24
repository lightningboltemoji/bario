import AppKit
import CBarioShim
import CoreVideo
import IOSurface
import Testing
@testable import BarioKit

/// Shared surfaces (DESIGN.md §9.3, PLAN.md step 3c): a pair handed over under a name, `frame`
/// naming the one just drawn, and a layer that shows it with nothing drawn or copied.
@Suite("Shared surfaces")
@MainActor
struct SurfaceTests {
    static func surface(_ blue: UInt8, _ green: UInt8, _ red: UInt8, topHalf: (UInt8, UInt8, UInt8)? = nil,
                        width: Int = 20, height: Int = 20) -> IOSurface {
        let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                             .pixelFormat: UInt32(kCVPixelFormatType_32BGRA)])!
        surface.lock(options: [], seed: nil)
        let pixels = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let colour = row < height / 2 ? (topHalf ?? (blue, green, red)) : (blue, green, red)
            for column in 0..<width {
                let i = row * surface.bytesPerRow + column * 4
                pixels[i] = colour.0; pixels[i + 1] = colour.1; pixels[i + 2] = colour.2; pixels[i + 3] = 255
            }
        }
        surface.unlock(options: [], seed: nil)
        return surface
    }

    func scene(_ source: String) throws -> Scene {
        let node = Node(.raster(RasterNode(width: 20, height: 20, source: .object(["surface": .string(source)]))))
        let config = try ConfigLoader.parse(#"bar { item "gpu" module="data" }"#)
        let sheet = try Stylesheet.parse("bar { padding: 0; background: none } item { padding: 0; background: none }")
        let display = DisplayInfo(displayID: 1, name: "T", frame: CGRect(x: 0, y: 0, width: 40, height: 900),
                                  scale: 2, stripHeight: 24)
        return SceneBuilder(cascade: Cascade(stylesheet: sheet), metrics: FixedMetrics())
            .build(bar: config.bars[0], display: display, items: config.bars[0].items,
                   states: ["gpu": ModuleHost.ItemState(result: RenderResult(content: node), rendered: true)])
    }

    @Test("frame round-trips over the protocol")
    func verb() async throws {
        let service = BarioService(store: StateStore())
        var framed: [(String, Int?)] = []
        service.onFrame = { framed.append(($0, $1)) }
        let ok = await service.handle(SocketRequest(id: .number(1), op: "frame",
                                                    fields: .object(["surface": .string("gpu"), "index": .number(1)])))
        #expect(ok.ok)
        let swap = await service.handle(SocketRequest(op: "frame", fields: .object(["surface": .string("gpu")])))
        #expect(swap.ok)
        #expect(framed.map(\.0) == ["gpu", "gpu"] && framed[0].1 == 1 && framed[1].1 == nil)
        let missing = await service.handle(SocketRequest(op: "frame", fields: .object([:])))
        #expect(missing.error?.contains("needs \"surface\"") == true)
        #expect(CLI.isVerb("frame"))

        let surfaces = SharedSurfaces()
        #expect(throws: ProtocolError.self) { try surfaces.frame("nothing") }
        #expect(surfaces.register("gpu", surfaces: [Self.surface(0, 0, 255), Self.surface(255, 0, 0)]) == .accepted)
        #expect(throws: ProtocolError.self) { try surfaces.frame("gpu", index: 2) }
        #expect(surfaces.register("one", surfaces: [Self.surface(0, 0, 255)]) == .invalid, "a pair, or nothing")
    }

    @Test("a source naming a surface nothing handed over shows nothing, and says so once")
    func unknown() throws {
        let surfaces = SharedSurfaces()
        let compositor = Compositor(host: CALayer())
        let scene = try scene("nowhere")
        for _ in 0..<3 {
            compositor.commit(Presentation(scene: scene),
                              inputs: Compositor.Inputs(backdrop: BackdropImage(), resolver: ColorResolver(),
                                                        scale: 2, surfaces: surfaces),
                              sceneChanged: true)
        }
        #expect(compositor.node(.node(item: "gpu", key: .path([])))?.leaf?.contents == nil)
        #expect(surfaces.unknown == ["nowhere"])
    }

    @Test("frame changes a layer's contents to the other surface, and draws nothing")
    func frames() throws {
        let surfaces = SharedSurfaces()
        let red = Self.surface(0, 0, 255), blue = Self.surface(255, 0, 0)
        #expect(surfaces.register("gpu", surfaces: [red, blue]) == .accepted)
        let compositor = Compositor(host: CALayer())
        let scene = try scene("gpu")
        func commit() -> CommitReport {
            compositor.commit(Presentation(scene: scene),
                              inputs: Compositor.Inputs(backdrop: BackdropImage(), resolver: ColorResolver(),
                                                        scale: 2, surfaces: surfaces),
                              sceneChanged: true)
        }
        #expect(commit().rasters == 0)
        let layer = try #require(compositor.node(.node(item: "gpu", key: .path([])))?.leaf)
        #expect(layer.contents as AnyObject === red)
        try surfaces.frame("gpu")
        #expect(commit().rasters == 0)
        #expect(layer.contents as AnyObject === blue)
        try surfaces.frame("gpu", index: 1)
        commit()
        #expect(layer.contents as AnyObject === blue, "naming the one showing keeps it")
    }

    @Test("a frame commits the bar without laying it out")
    func frameLoop() async throws {
        let h = try Harness(#"item "gpu" module="echo-test""#)
        #expect(h.loop.surfaces.register("gpu", surfaces: [Self.surface(0, 0, 255), Self.surface(255, 0, 0)]) == .accepted)
        await h.start()
        h.loop.setBackdrop(FrameLoopTests.checker, for: 1)
        await h.settle()
        var lines: [String] = []
        h.loop.trace = { lines.append($0) }
        try h.loop.surfaces.frame("gpu")
        #expect(h.scheduler.pending == .turn)
        h.scheduler.run()
        #expect(lines.count == 1 && lines[0].contains("commit laid out 0"), "\(lines)")
    }

    @Test("a surface is shown the right way up")
    func orientation() throws {
        let surfaces = SharedSurfaces()
        // Red in the top half of memory, blue below.
        #expect(surfaces.register("gpu", surfaces: [Self.surface(255, 0, 0, topHalf: (0, 0, 255)),
                                                    Self.surface(0, 0, 0)]) == .accepted)
        let image = try #require(Offscreen.render(try scene("gpu"), backdrop: BackdropImage(),
                                                  resolver: ColorResolver(), scale: 2, surfaces: surfaces))
        let size = CGSize(width: 40, height: 24)
        // The 20×20 node is centred: y 2…22.
        let top = Offscreen.pixel(image, atPoint: CGPoint(x: 10, y: 18), size: size)
        let bottom = Offscreen.pixel(image, atPoint: CGPoint(x: 10, y: 6), size: size)
        #expect(top?.isClose(to: Offscreen.Pixel(r: 1, g: 0, b: 0, a: 1), tolerance: 0.05) == true, "\(String(describing: top))")
        #expect(bottom?.isClose(to: Offscreen.Pixel(r: 0, g: 0, b: 1, a: 1), tolerance: 0.05) == true, "\(String(describing: bottom))")
    }
}

/// Real time: a real Mach port and a producer that blocks on its answer, so this is in the
/// Makefile's `REAL_TIME` and runs in the serial pass.
@Suite("Shared surfaces over Mach")
@MainActor
struct SurfaceHandOffTests {
    @Test("a producer hands surfaces over a Mach port; its name is its own; its surfaces go with it")
    func handOff() async throws {
        let surfaces = SharedSurfaces()
        let service = "zip.tanner.bario.test.\(UUID().uuidString.prefix(8))"
        let listener = try SurfaceListener(service: service, surfaces: surfaces)
        defer { listener.stop() }

        let pair = [SurfaceTests.surface(0, 0, 255), SurfaceTests.surface(255, 0, 0)]
        func owner() -> mach_port_t {
            var port = mach_port_t(MACH_PORT_NULL)
            mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
            return port
        }
        func handOff(_ name: String, _ owner: mach_port_t) async -> Int32 {
            let ports = pair.map { IOSurfaceCreateMachPort($0) }
            defer { ports.forEach { mach_port_deallocate(mach_task_self_, $0) } }
            let (a, b) = (ports[0], ports[1])
            // Off the main actor, and off the cooperative pool: the hand-off blocks until the
            // listener answers, and the listener needs a thread to answer on. See Blocking.swift.
            // It answers from a queue of its own, not the main one, so the timeout is for a
            // busy machine, not for a backlog of `@MainActor` tests.
            return await offPool { bario_surfaces_hand_off(service, name, a, b, owner, 30_000) }
        }

        let first = owner(), second = owner()
        #expect(await handOff("gpu", first) == BARIO_SURFACES_ACCEPTED)
        // The registry hears of it on the main actor, after the producer has its answer.
        #expect(await eventually { surfaces.entries["gpu"] != nil })
        let entry = try #require(surfaces.entries["gpu"])
        #expect(entry.surfaces.map { IOSurfaceGetID($0) } == pair.map { IOSurfaceGetID($0) },
                "the same surfaces, across a port")
        #expect(await handOff("gpu", second) == BARIO_SURFACES_TAKEN, "one producer per name")
        #expect(await handOff("gpu", first) == BARIO_SURFACES_ACCEPTED, "and that producer may hand over again")

        // The producer goes: its port dies, and bario hears of it.
        mach_port_mod_refs(mach_task_self_, first, MACH_PORT_RIGHT_RECEIVE, -1)
        #expect(await eventually { surfaces.entries["gpu"] == nil })
        #expect(await handOff("gpu", second) == BARIO_SURFACES_ACCEPTED, "the name is free again")
        mach_port_mod_refs(mach_task_self_, second, MACH_PORT_RIGHT_RECEIVE, -1)
    }
}
