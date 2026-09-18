import AppKit

/// The registry of node types a renderer module draws. DESIGN.md §9.2: the vocabulary grows
/// by dropping a `.wasm` in a directory.
///
/// Renderers are called from layout, to measure, and from commit, to draw, both synchronous on
/// the main actor, so each one is a locked instance rather than an actor, and its budget is
/// measured rather than enforced — WasmKit cannot interrupt a call, so a renderer that overruns
/// is dropped instead.
public final class RendererHost: @unchecked Sendable {
    private let lock = NSLock()
    private var renderers: [String: Renderer] = [:]
    public var budget: Double = 0.050

    public init() {}

    public var nodeTypes: [String] {
        lock.lock(); defer { lock.unlock() }
        return renderers.keys.sorted()
    }

    public func has(_ nodeType: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return renderers[nodeType] != nil
    }

    /// Whether a renderer is registered but currently in disgrace.
    public func isStale(_ nodeType: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return renderers[nodeType]?.disabled ?? false
    }

    public func load(_ configs: [RendererConfig], store: StateStore,
                     engine: (any WasmEngine)? = nil, events: EventBus = EventBus()) {
        lock.lock()
        let existing = renderers
        lock.unlock()

        var next: [String: Renderer] = [:]
        for config in configs {
            if let renderer = existing[config.nodeType], renderer.path == config.path {
                next[config.nodeType] = renderer
                continue
            }
            do {
                next[config.nodeType] = try Renderer(config: config, store: store,
                                                     engine: engine ?? WasmKitEngine(),
                                                     events: events)
                note("  renderer \(config.nodeType): \(config.path)")
            } catch {
                warn("renderer \(config.nodeType): \(error)")
            }
        }
        lock.lock()
        renderers = next
        lock.unlock()
    }

    /// The natural size of a custom node, from a `measure: true` draw. Asking for a frame while
    /// measuring means nothing: frames are for drawings.
    public func measure(_ nodeType: String, payload: JSONValue, style: Style,
                        resolver: ColorResolver, height: Double) -> CGSize? {
        guard let renderer = renderer(nodeType) else { return nil }
        let frame = CGRect(x: 0, y: 0, width: 0, height: height)
        let (answer, _) = call(renderer, nodeType: nodeType, payload: payload, style: style,
                               resolver: resolver, frame: frame, measure: true)
        guard let answer else { return nil }
        let width = answer["width"]?.doubleValue ?? 0
        return CGSize(width: width, height: answer["height"]?.doubleValue ?? height)
    }

    /// The drawing for a node of `size`, and whether the renderer asked, while drawing it, to
    /// be drawn again in the next frame. The frame it is given is node-local, at 0, 0
    /// (PLAN.md D8): ops are node-local already, and a drawing that depended on where its
    /// bubble sits would have to be drawn again on every frame of a layout transition.
    public func draw(_ nodeType: String, payload: JSONValue, style: Style,
                     resolver: ColorResolver, size: CGSize) -> (drawing: RendererDrawing?, wantsFrame: Bool) {
        guard let renderer = renderer(nodeType) else { return (nil, false) }
        let (answer, wantsFrame) = call(renderer, nodeType: nodeType, payload: payload, style: style,
                                        resolver: resolver, frame: CGRect(origin: .zero, size: size),
                                        measure: false)
        guard let answer else { return (nil, wantsFrame) }
        if let raster = answer["raster"] {
            return (.raster(raster, instance: renderer.instance), wantsFrame)
        }
        let ops = answer["ops"]?.arrayValue ?? answer.arrayValue ?? []
        let list = DisplayList.parse(ops)
        for problem in list.problems { warn("renderer \(nodeType): \(problem)") }
        return (.ops(list), wantsFrame)
    }

    private func renderer(_ nodeType: String) -> Renderer? {
        lock.lock(); defer { lock.unlock() }
        guard let renderer = renderers[nodeType], !renderer.disabled else { return nil }
        return renderer
    }

    private func call(_ renderer: Renderer, nodeType: String, payload: JSONValue, style: Style,
                      resolver: ColorResolver, frame: CGRect, measure: Bool) -> (JSONValue?, Bool) {
        let request = JSONValue.object([
            "type": .string(nodeType),
            "node": payload,
            "measure": .bool(measure),
            "frame": .object(["x": .number(frame.minX), "y": .number(frame.minY),
                              "width": .number(frame.width), "height": .number(frame.height)]),
            "style": style.json(resolver: resolver),
        ])
        let started = CFAbsoluteTimeGetCurrent()
        let answer: JSONValue?
        do {
            answer = try renderer.draw(request)
        } catch {
            warn("renderer \(nodeType): \(error)")
            disgrace(nodeType)
            return (nil, renderer.takeFrameRequest())
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        if elapsed > budget {
            warn(String(format: "renderer %@ took %.0fms, over its %.0fms budget",
                        nodeType, elapsed * 1000, budget * 1000))
            disgrace(nodeType)
        }
        return (answer, renderer.takeFrameRequest())
    }

    /// Three overruns and the renderer is dropped; its nodes wear `.stale` from then on.
    private func disgrace(_ nodeType: String) {
        lock.lock(); defer { lock.unlock() }
        guard let renderer = renderers[nodeType] else { return }
        renderer.strikes += 1
        if renderer.strikes >= 3 { renderer.disabled = true }
    }
}

public enum RendererDrawing {
    case ops(DisplayList)
    /// A raster descriptor, plus the instance whose memory a `{ptr, len}` source points into.
    case raster(JSONValue, instance: any WasmInstance)
}

/// One registered renderer.
final class Renderer: @unchecked Sendable {
    let nodeType: String
    let path: String
    let instance: any WasmInstance
    private let lock = NSLock()
    private let control = WasmModule.Control()
    var strikes = 0
    var disabled = false

    init(config: RendererConfig, store: StateStore, engine: any WasmEngine,
         events: EventBus = EventBus()) throws {
        nodeType = config.nodeType
        path = config.path
        guard let data = FileManager.default.contents(atPath: config.path) else {
            throw WasmError("no renderer at \(config.path)")
        }
        let permissions = try WasmPermissions.parse(config.options)
        // Renderers are ordinary modules: the same imports, their own subtree of the store.
        let imports = WasmHost.imports(store: store, item: "renderer.\(config.nodeType)",
                                       permissions: permissions, pending: PendingBytes(),
                                       control: control, events: events)
        instance = try engine.instantiate(wasm: [UInt8](data), imports: imports,
                                          memoryLimitBytes: 16 * 1024 * 1024)
        if instance.hasExport("init") {
            _ = try? instance.callJSON("init", config.options)
        }
        guard instance.hasExport("draw") else {
            throw WasmError("a renderer must export `draw`")
        }
    }

    func draw(_ request: JSONValue) throws -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        return try instance.callJSON("draw", request)
    }

    func takeFrameRequest() -> Bool {
        guard control.wantsFrame else { return false }
        control.wantsFrame = false
        return true
    }
}

extension Style {
    /// The node's resolved style, as a renderer sees it. Colours arrive resolved so a renderer
    /// needs no colour engine; custom properties arrive as source text so `var(--x)` is
    /// readable as whatever it is. DESIGN.md §9.
    public func json(resolver: ColorResolver) -> JSONValue {
        let colors = resolver.with(current: resolver.resolve(color))
        func hex(_ value: Color) -> JSONValue {
            let rgba = colors.resolve(value)
            let byte = { (channel: CGFloat) in Int((min(1, max(0, channel)) * 255).rounded()) }
            return .string(String(format: "#%02x%02x%02x%02x",
                                  byte(rgba.r), byte(rgba.g), byte(rgba.b), byte(rgba.a)))
        }
        var custom: [String: JSONValue] = [:]
        for (name, components) in self.custom { custom[name] = .string(components.text) }

        return .object([
            "color": hex(color),
            "fill": hex(fill),
            "track": hex(track),
            "border-color": hex(borderColor),
            "opacity": .number(opacity),
            "stroke-width": .number(strokeWidth),
            "line-cap": .string(lineCap.rawValue),
            "icon-size": .number(effectiveIconSize),
            "icon-color": hex(effectiveIconColor),
            "font": .object([
                "family": .string(font.family.name),
                "size": .number(font.size),
                "weight": .number(font.weight),
            ]),
            "padding": .object(["top": .number(padding.top), "right": .number(padding.right),
                                "bottom": .number(padding.bottom), "left": .number(padding.left)]),
            "custom": .object(custom),
        ])
    }
}

extension FontFamily {
    public var name: String {
        switch self {
        case .system: return "system"
        case .systemUI: return "system-ui"
        case .monospace: return "monospace"
        case .named(let name): return name
        }
    }
}
