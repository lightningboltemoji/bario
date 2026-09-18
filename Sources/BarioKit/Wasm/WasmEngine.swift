import Foundation

/// The seam between bario and whichever WASM runtime it uses. WasmKit today; wasmtime's C API
/// if profiling or interruption ever demands it. DESIGN.md §5.
public protocol WasmEngine: Sendable {
    func instantiate(wasm: [UInt8], imports: [WasmHostFunction], memoryLimitBytes: Int)
        throws -> any WasmInstance
}

public enum WasmType: Sendable {
    case i32, i64
}

/// Guest memory, as a host function sees it during a call.
public protocol WasmMemory {
    func read(ptr: Int32, len: Int32) throws -> [UInt8]
    func write(_ bytes: [UInt8], at ptr: Int32) throws
}

public struct WasmHostFunction: Sendable {
    public var name: String
    public var parameters: [WasmType]
    public var results: [WasmType]
    public var body: @Sendable (any WasmMemory, [Int64]) throws -> [Int64]

    public init(_ name: String, _ parameters: [WasmType], _ results: [WasmType] = [],
                body: @escaping @Sendable (any WasmMemory, [Int64]) throws -> [Int64]) {
        self.name = name
        self.parameters = parameters
        self.results = results
        self.body = body
    }
}

public protocol WasmInstance: AnyObject {
    func hasExport(_ name: String) -> Bool
    @discardableResult
    func call(_ name: String, _ arguments: [Int64]) throws -> [Int64]
    func read(ptr: Int32, len: Int32) throws -> [UInt8]
    func write(_ bytes: [UInt8], at ptr: Int32) throws
}

public struct WasmError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - The bytes ABI

public enum WasmABI {
    /// The host imports, in namespace `bario`. One source of truth: the module defines
    /// exactly these, and the PDKs declare exactly these.
    public static let hostImports = [
        "log", "now", "set", "get", "read", "emit", "subscribe",
        "set_timer", "request_frame", "exec", "read_file", "http",
    ]

    /// What a guest may export. Only `render` is required.
    public static let guestExports = ["alloc", "dealloc", "init", "poll", "on_event", "render", "draw"]

    /// `(ptr, len)` packed into one i64: high 32 bits the pointer, low 32 the length. Core
    /// WASM's multi-value return is awkward to emit from several toolchains, and one integer
    /// is thirty lines in any language. See .agents/knowledge/13-wasm.md.
    public static func unpack(_ value: Int64) -> (ptr: Int32, len: Int32)? {
        guard value != 0 else { return nil }
        let bits = UInt64(bitPattern: value)
        return (Int32(truncatingIfNeeded: bits >> 32), Int32(truncatingIfNeeded: bits & 0xFFFF_FFFF))
    }

    public static func pack(ptr: Int32, len: Int32) -> Int64 {
        Int64(bitPattern: (UInt64(UInt32(bitPattern: ptr)) << 32) | UInt64(UInt32(bitPattern: len)))
    }
}

extension WasmInstance {
    /// Copy bytes into the guest by asking it for a buffer first.
    public func send(_ data: Data) throws -> (ptr: Int32, len: Int32) {
        guard !data.isEmpty else { return (0, 0) }
        guard hasExport("alloc") else {
            throw WasmError("the module exports no `alloc`, so the host cannot hand it bytes")
        }
        let results = try call("alloc", [Int64(data.count)])
        guard let first = results.first, first != 0 else {
            throw WasmError("alloc(\(data.count)) returned nothing")
        }
        let ptr = Int32(truncatingIfNeeded: first)
        try write([UInt8](data), at: ptr)
        return (ptr, Int32(data.count))
    }

    /// Call an export with a JSON payload and read a JSON answer back.
    public func callJSON(_ name: String, _ payload: JSONValue) throws -> JSONValue? {
        let (ptr, len) = try send(payload.encoded())
        let results = try call(name, [Int64(ptr), Int64(len)])
        if hasExport("dealloc"), ptr != 0 {
            _ = try? call("dealloc", [Int64(ptr), Int64(len)])
        }
        guard let raw = results.first, let out = WasmABI.unpack(raw) else { return nil }
        guard out.len > 0 else { return nil }
        let bytes = try read(ptr: out.ptr, len: out.len)
        let value = try JSONValue(Data(bytes))
        if hasExport("dealloc") {
            _ = try? call("dealloc", [Int64(out.ptr), Int64(out.len)])
        }
        return value
    }
}
