import BarioWasm
import Foundation

/// The `WasmEngine` on wasmtime's Pulley interpreter, through bariowasm's C ABI (`Engine/`).
/// Everything runtime-specific lives here; the rest of bario talks to the protocol.
///
/// Pulley runs bytecode Cranelift compiles a module to, so there is no executable memory and
/// nothing the hardened runtime refuses; and a call that runs past its instance's deadline is
/// interrupted where it stands. See .agents/knowledge/23-wasmtime.md.
public final class WasmtimeEngine: WasmEngine, @unchecked Sendable {
    /// One per process will do: an engine is a compiler configuration and the thread that ticks
    /// for deadlines, and nothing in it belongs to a module.
    public static let shared = WasmtimeEngine()

    private let raw: Result<OpaquePointer, WasmError>

    public init() {
        var error: UnsafeMutablePointer<CChar>?
        if let raw = bw_engine_new(&error) {
            self.raw = .success(raw)
        } else {
            self.raw = .failure(WasmError("wasmtime did not start: \(take(error))"))
        }
    }

    deinit {
        if case .success(let raw) = raw { bw_engine_free(raw) }
    }

    public func instantiate(wasm: [UInt8], imports hostFunctions: [WasmHostFunction],
                            memoryLimitBytes: Int) throws -> any WasmInstance {
        let engine = try raw.get()
        let binary = try WasmtimeEngine.binary(wasm)
        var error: UnsafeMutablePointer<CChar>?
        guard let module = binary.withUnsafeBufferPointer({
            bw_module_compile(engine, $0.baseAddress, $0.count, &error)
        }) else {
            throw WasmError("not a valid WebAssembly module: \(take(error))")
        }
        defer { bw_module_free(module) }
        return try WasmtimeInstance(engine: self, raw: engine, module: module,
                                    imports: hostFunctions, memoryLimit: memoryLimitBytes)
    }

    /// A `.wasm` binary starts with `\0asm`; anything else is assumed to be WebAssembly text
    /// and assembled here, so a module can be dropped in as `.wat` with no toolchain at all.
    static func binary(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 4, Array(bytes.prefix(4)) != [0x00, 0x61, 0x73, 0x6D] else {
            return bytes
        }
        do {
            return try wat2wasm(String(decoding: bytes, as: UTF8.self))
        } catch {
            throw WasmError("not WebAssembly: \(error)")
        }
    }
}

/// WebAssembly text assembled into a binary module.
func wat2wasm(_ text: String) throws -> [UInt8] {
    let source = Array(text.utf8)
    var bytes: UnsafeMutablePointer<UInt8>?
    var count = 0
    var error: UnsafeMutablePointer<CChar>?
    let status = source.withUnsafeBufferPointer {
        bw_wat2wasm($0.baseAddress, $0.count, &bytes, &count, &error)
    }
    guard status == BW_OK, let bytes else { throw WasmError(take(error)) }
    defer { bw_bytes_free(bytes, count) }
    return Array(UnsafeBufferPointer(start: bytes, count: count))
}

/// A message bariowasm handed over, which is ours to free.
private func take(_ error: UnsafeMutablePointer<CChar>?) -> String {
    guard let error else { return "unknown error" }
    defer { bw_string_free(error) }
    return String(cString: error)
}

public final class WasmtimeInstance: WasmInstance, @unchecked Sendable {
    private let raw: OpaquePointer
    /// Kept for as long as the instance: the engine's ticker is what interrupts its calls.
    private let engine: WasmtimeEngine
    /// What its host imports call back into, through the C callback's context.
    private let imports: Imports

    init(engine: WasmtimeEngine, raw rawEngine: OpaquePointer, module: OpaquePointer,
         imports hostFunctions: [WasmHostFunction], memoryLimit: Int) throws {
        let imports = Imports(hostFunctions)
        self.engine = engine
        self.imports = imports

        // The names and types only have to last the call: bariowasm copies them into its linker.
        let names = hostFunctions.map { strdup($0.name) }
        defer { names.forEach { free($0) } }
        var types: [bw_type] = []
        var spans: [(params: Int, results: Int)] = []
        for function in hostFunctions {
            spans.append((types.count, types.count + function.parameters.count))
            types += (function.parameters + function.results).map(WasmtimeInstance.type)
        }

        let callback: bw_host_fn = { context, index, caller, arguments, count, results, resultCount in
            guard let context, let caller else { return false }
            let imports = Unmanaged<Imports>.fromOpaque(context).takeUnretainedValue()
            return imports.call(index, caller: caller,
                                arguments: Array(UnsafeBufferPointer(start: arguments, count: count)),
                                results: UnsafeMutableBufferPointer(start: results, count: resultCount))
        }
        var error: UnsafeMutablePointer<CChar>?
        let made = types.withUnsafeBufferPointer { types -> OpaquePointer? in
            let declared = zip(hostFunctions, zip(names, spans)).map { function, entry in
                bw_import(name: UnsafePointer(entry.0),
                          params: types.baseAddress.map { $0 + entry.1.params },
                          nparams: function.parameters.count,
                          results: types.baseAddress.map { $0 + entry.1.results },
                          nresults: function.results.count)
            }
            return declared.withUnsafeBufferPointer {
                bw_instance_new(rawEngine, module, UInt64(max(0, memoryLimit)), $0.baseAddress, $0.count,
                                callback, Unmanaged.passUnretained(imports).toOpaque(), &error)
            }
        }
        guard let made else { throw WasmError("could not instantiate: \(take(error))") }
        raw = made
    }

    deinit { bw_instance_free(raw) }

    public func setDeadline(after seconds: Double) {
        bw_instance_set_deadline(raw, seconds)
    }

    public func hasExport(_ name: String) -> Bool {
        bw_instance_func(raw, name, nil, nil)
    }

    @discardableResult
    public func call(_ name: String, _ arguments: [Int64]) throws -> [Int64] {
        var parameters = 0
        var results = 0
        guard bw_instance_func(raw, name, &parameters, &results) else {
            throw WasmError("the module exports no `\(name)`")
        }
        guard parameters == arguments.count else {
            throw WasmError("`\(name)` takes \(parameters) arguments, called with \(arguments.count)")
        }
        var out = [Int64](repeating: 0, count: results)
        var error: UnsafeMutablePointer<CChar>?
        let status = arguments.withUnsafeBufferPointer { arguments in
            out.withUnsafeMutableBufferPointer { out in
                bw_instance_call(raw, name, arguments.baseAddress, arguments.count,
                                 out.baseAddress, out.count, &error)
            }
        }
        switch status {
        case BW_OK:
            return out
        case BW_DEADLINE:
            _ = take(error)
            throw WasmError("`\(name)` ran past its budget and was interrupted")
        case BW_TRAP:
            throw WasmError("`\(name)` trapped: \(take(error))")
        default:
            throw WasmError(take(error))
        }
    }

    public func read(ptr: Int32, len: Int32) throws -> [UInt8] {
        try GuestMemory.read(ptr: ptr, len: len) { bw_instance_read(raw, $0, $1, $2, &$3) }
    }

    public func write(_ bytes: [UInt8], at ptr: Int32) throws {
        try GuestMemory.write(bytes, at: ptr) { bw_instance_write(raw, $0, $1, $2, &$3) }
    }

    static func type(_ type: WasmType) -> bw_type {
        switch type {
        case .i32: return BW_I32
        case .i64: return BW_I64
        }
    }

    /// The host functions, which bariowasm calls by their place in the list it was given.
    final class Imports: @unchecked Sendable {
        private let functions: [WasmHostFunction]

        init(_ functions: [WasmHostFunction]) { self.functions = functions }

        func call(_ index: Int, caller: OpaquePointer, arguments: [Int64],
                  results: UnsafeMutableBufferPointer<Int64>) -> Bool {
            do {
                let out = try functions[index].body(CallerMemory(caller: caller), arguments)
                for (slot, value) in zip(results.indices, out) { results[slot] = value }
                return true
            } catch {
                bw_caller_fail(caller, "\(error)")
                return false
            }
        }
    }

    /// The guest's memory as a host import sees it, for the length of the import.
    struct CallerMemory: WasmMemory {
        let caller: OpaquePointer

        func read(ptr: Int32, len: Int32) throws -> [UInt8] {
            try GuestMemory.read(ptr: ptr, len: len) { bw_caller_read(caller, $0, $1, $2, &$3) }
        }

        func write(_ bytes: [UInt8], at ptr: Int32) throws {
            try GuestMemory.write(bytes, at: ptr) { bw_caller_write(caller, $0, $1, $2, &$3) }
        }
    }
}

/// Copies in and out of guest memory, through whichever door bariowasm offers: the instance's
/// between calls, a host import's caller during one. bariowasm checks the range.
private enum GuestMemory {
    typealias Read = (UInt32, UnsafeMutablePointer<UInt8>?, Int, inout UnsafeMutablePointer<CChar>?) -> bw_status
    typealias Write = (UInt32, UnsafePointer<UInt8>?, Int, inout UnsafeMutablePointer<CChar>?) -> bw_status

    static func read(ptr: Int32, len: Int32, _ door: Read) throws -> [UInt8] {
        guard ptr >= 0, len >= 0 else { throw WasmError("a negative pointer or length") }
        guard len > 0 else { return [] }
        var error: UnsafeMutablePointer<CChar>?
        var status = BW_OK
        let bytes = [UInt8](unsafeUninitializedCapacity: Int(len)) { buffer, count in
            status = door(UInt32(ptr), buffer.baseAddress, buffer.count, &error)
            count = status == BW_OK ? buffer.count : 0
        }
        guard status == BW_OK else { throw WasmError(take(error)) }
        return bytes
    }

    static func write(_ bytes: [UInt8], at ptr: Int32, _ door: Write) throws {
        guard ptr >= 0 else { throw WasmError("a negative pointer") }
        guard !bytes.isEmpty else { return }
        var error: UnsafeMutablePointer<CChar>?
        let status = bytes.withUnsafeBufferPointer { door(UInt32(ptr), $0.baseAddress, $0.count, &error) }
        guard status == BW_OK else { throw WasmError(take(error)) }
    }
}
