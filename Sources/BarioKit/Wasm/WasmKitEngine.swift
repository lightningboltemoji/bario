@_spi(Fuzzing) import WasmKit
import WAT
import Foundation

/// The `WasmEngine` on WasmKit. Everything runtime-specific lives here; the rest of bario
/// talks to the protocol.
public final class WasmKitEngine: WasmEngine, @unchecked Sendable {
    public init() {}

    public func instantiate(wasm: [UInt8], imports hostFunctions: [WasmHostFunction],
                            memoryLimitBytes: Int) throws -> any WasmInstance {
        let module: WasmKit.Module
        do {
            module = try parseWasm(bytes: WasmKitEngine.binary(wasm))
        } catch {
            throw WasmError("not a valid WebAssembly module: \(error)")
        }

        let engine = Engine()
        let store = Store(engine: engine)
        store.resourceLimiter = MemoryCap(bytes: memoryLimitBytes)

        let instanceBox = InstanceBox()
        var imports = Imports()
        for function in hostFunctions {
            let body = function.body
            let name = function.name
            imports.define(
                module: "bario", name: name,
                WasmKit.Function(store: store,
                                 parameters: function.parameters.map(WasmKitEngine.type),
                                 results: function.results.map(WasmKitEngine.type)) { caller, arguments in
                    let memory = CallerMemory(caller: caller, fallback: instanceBox)
                    let values = arguments.map(WasmKitEngine.int64)
                    let results = try body(memory, values)
                    return zip(function.results, results).map(WasmKitEngine.value)
                })
        }

        let instance: Instance
        do {
            instance = try module.instantiate(store: store, imports: imports)
        } catch {
            throw WasmError("could not instantiate: \(error)")
        }
        let wrapper = WasmKitInstance(instance: instance, store: store)
        instanceBox.instance = wrapper
        return wrapper
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

    static func type(_ type: WasmType) -> ValueType {
        switch type {
        case .i32: return .i32
        case .i64: return .i64
        }
    }

    static func int64(_ value: Value) -> Int64 {
        switch value {
        case .i32(let raw): return Int64(Int32(bitPattern: raw))
        case .i64(let raw): return Int64(bitPattern: raw)
        default: return 0
        }
    }

    static func value(_ pair: (WasmType, Int64)) -> Value {
        switch pair.0 {
        case .i32: return .i32(UInt32(bitPattern: Int32(truncatingIfNeeded: pair.1)))
        case .i64: return .i64(UInt64(bitPattern: pair.1))
        }
    }

    /// 16MB per instance by default (DESIGN.md §5). WasmKit exposes this only as SPI.
    struct MemoryCap: ResourceLimiter {
        let bytes: Int
        func limitMemoryGrowth(to desired: Int) throws -> Bool { desired <= bytes }
        func limitTableGrowth(to desired: Int) throws -> Bool { desired <= 100_000 }
    }

    /// Lets a host function reach the instance's memory even before instantiation finishes.
    final class InstanceBox: @unchecked Sendable {
        var instance: WasmKitInstance?
    }

    struct CallerMemory: WasmMemory {
        let caller: Caller
        let fallback: InstanceBox

        private var memory: WasmKit.Memory? {
            if case .memory(let memory)? = caller.instance?.exports["memory"] { return memory }
            return fallback.instance?.memory
        }

        func read(ptr: Int32, len: Int32) throws -> [UInt8] {
            guard let memory else { throw WasmError("the module exports no memory") }
            return try WasmKitInstance.read(memory: memory, ptr: ptr, len: len)
        }

        func write(_ bytes: [UInt8], at ptr: Int32) throws {
            guard let memory else { throw WasmError("the module exports no memory") }
            try WasmKitInstance.write(memory: memory, bytes: bytes, at: ptr)
        }
    }
}

public final class WasmKitInstance: WasmInstance, @unchecked Sendable {
    let instance: Instance
    let store: Store

    init(instance: Instance, store: Store) {
        self.instance = instance
        self.store = store
    }

    var memory: WasmKit.Memory? {
        if case .memory(let memory)? = instance.exports["memory"] { return memory }
        return nil
    }

    public func hasExport(_ name: String) -> Bool {
        instance.exports[function: name] != nil
    }

    @discardableResult
    public func call(_ name: String, _ arguments: [Int64]) throws -> [Int64] {
        guard let function = instance.exports[function: name] else {
            throw WasmError("the module exports no `\(name)`")
        }
        let parameters = function.type.parameters
        guard parameters.count == arguments.count else {
            throw WasmError("`\(name)` takes \(parameters.count) arguments, called with \(arguments.count)")
        }
        let values = zip(parameters, arguments).map { type, value -> Value in
            type == .i64 ? .i64(UInt64(bitPattern: value))
                         : .i32(UInt32(bitPattern: Int32(truncatingIfNeeded: value)))
        }
        do {
            return try function.invoke(values).map(WasmKitEngine.int64)
        } catch {
            throw WasmError("`\(name)` trapped: \(error)")
        }
    }

    public func read(ptr: Int32, len: Int32) throws -> [UInt8] {
        guard let memory else { throw WasmError("the module exports no memory") }
        return try WasmKitInstance.read(memory: memory, ptr: ptr, len: len)
    }

    public func write(_ bytes: [UInt8], at ptr: Int32) throws {
        guard let memory else { throw WasmError("the module exports no memory") }
        try WasmKitInstance.write(memory: memory, bytes: bytes, at: ptr)
    }

    static func read(memory: WasmKit.Memory, ptr: Int32, len: Int32) throws -> [UInt8] {
        guard ptr >= 0, len >= 0 else { throw WasmError("a negative pointer or length") }
        guard len > 0 else { return [] }
        let data = memory.data
        let start = Int(ptr)
        let end = start + Int(len)
        guard end <= data.count else {
            throw WasmError("read of \(len) bytes at \(ptr) is past the end of a \(data.count) byte memory")
        }
        return Array(data[start..<end])
    }

    static func write(memory: WasmKit.Memory, bytes: [UInt8], at ptr: Int32) throws {
        guard ptr >= 0 else { throw WasmError("a negative pointer") }
        guard !bytes.isEmpty else { return }
        guard Int(ptr) + bytes.count <= memory.data.count else {
            throw WasmError("write of \(bytes.count) bytes at \(ptr) is past the end of memory")
        }
        memory.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: bytes.count) { buffer in
            bytes.withUnsafeBytes { source in
                buffer.copyMemory(from: source)
            }
        }
    }
}
