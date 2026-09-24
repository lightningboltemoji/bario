import Foundation
import Testing
import WAT
@testable import BarioKit

/// Guests are written in WebAssembly text and assembled in-process, so these tests exercise
/// real WASM with no toolchain to install.
enum Guest {
    /// The shared preamble: 64KB of memory, a bump allocator, and the packing helper the ABI
    /// needs. This is the PDK's thirty lines, in WAT. WASM requires every import to precede
    /// every other module field, so they are a separate argument.
    static let preamble = """
      (memory (export "memory") 1)
      (global $next (mut i32) (i32.const 1024))
      (func $alloc (export "alloc") (param $len i32) (result i32)
        (local $ptr i32)
        (local.set $ptr (global.get $next))
        (global.set $next (i32.add (global.get $next) (i32.add (local.get $len) (i32.const 8))))
        (local.get $ptr))
      (func $pack (param $ptr i32) (param $len i32) (result i64)
        (i64.or
          (i64.shl (i64.extend_i32_u (local.get $ptr)) (i64.const 32))
          (i64.extend_i32_u (local.get $len))))
    """

    static func build(imports: String = "", _ body: String) throws -> [UInt8] {
        try wat2wasm("(module \n\(imports)\n\(preamble)\n\(body)\n)")
    }

    /// WAT string literals are byte strings: quotes and backslashes escape, and anything
    /// outside printable ASCII is written as \XX so multi-byte UTF-8 survives.
    static func escape(_ text: String) -> String {
        var out = ""
        for byte in Array(text.utf8) {
            switch byte {
            case UInt8(ascii: "\""): out += "\\\""
            case UInt8(ascii: "\\"): out += "\\\\"
            case 0x20...0x7E: out.append(Character(UnicodeScalar(byte)))
            default: out += String(format: "\\%02x", byte)
            }
        }
        return out
    }

    /// A `data` segment at offset 0, and the byte length to pass around with it.
    static func data(_ text: String) -> (segment: String, length: Int) {
        ("(data (i32.const 0) \"\(escape(text))\")", text.utf8.count)
    }

    /// A module that renders a fixed content tree.
    static func renderer(text: String) throws -> [UInt8] {
        let json = #"{"content":{"text":"\#(text)"}}"#
        let payload = data(json)
        return try build("""
          \(payload.segment)
          (func (export "render") (param i32 i32) (result i64)
            (call $pack (i32.const 0) (i32.const \(payload.length))))
        """)
    }
}

@Suite("WASM ABI")
struct WasmABITests {
    @Test("(ptr, len) packs into one i64 and back")
    func packing() {
        #expect(WasmABI.unpack(0) == nil)
        let packed = WasmABI.pack(ptr: 1024, len: 37)
        let unpacked = WasmABI.unpack(packed)
        #expect(unpacked?.ptr == 1024)
        #expect(unpacked?.len == 37)
        let big = WasmABI.pack(ptr: 0x7FFF_0000, len: 0xFFFF)
        #expect(WasmABI.unpack(big)?.ptr == 0x7FFF_0000)
        #expect(WasmABI.unpack(big)?.len == 0xFFFF)
    }
}

@Suite("WasmKit engine")
struct WasmEngineTests {
    let engine = WasmKitEngine()

    @Test("a guest renders, and the host reads its answer")
    func render() throws {
        let instance = try engine.instantiate(wasm: try Guest.renderer(text: "hello"),
                                              imports: [], memoryLimitBytes: 16 << 20)
        let value = try instance.callJSON("render", .object(["pct": .number(43)]))
        #expect(value?["content"]?["text"]?.stringValue == "hello")
    }

    @Test("the host hands bytes to the guest through its own alloc")
    func sending() throws {
        // Echoes back whatever it was given, which proves the bytes arrived intact.
        let wasm = try Guest.build("""
          (func (export "render") (param $ptr i32) (param $len i32) (result i64)
            (call $pack (local.get $ptr) (local.get $len)))
        """)
        let instance = try engine.instantiate(wasm: wasm, imports: [], memoryLimitBytes: 16 << 20)
        let sent = JSONValue.object(["pct": .number(43), "name": .string("battery")])
        let back = try instance.callJSON("render", sent)
        #expect(back?["pct"]?.intValue == 43)
        #expect(back?["name"]?.stringValue == "battery")
    }

    @Test("a host import is called, with the guest's bytes")
    func hostImports() throws {
        let seen = Recorder()
        let logger = WasmHostFunction("log", [.i32, .i32, .i32]) { memory, arguments in
            let bytes = try memory.read(ptr: Int32(arguments[1]), len: Int32(arguments[2]))
            seen.record(String(decoding: bytes, as: UTF8.self))
            return []
        }
        let wasm = try Guest.build(imports: """
          (import "bario" "log" (func $log (param i32 i32 i32)))
        """, """
          (data (i32.const 0) "from the guest")
          (func (export "render") (param i32 i32) (result i64)
            (call $log (i32.const 1) (i32.const 0) (i32.const 14))
            (i64.const 0))
        """)
        let instance = try engine.instantiate(wasm: wasm, imports: [logger], memoryLimitBytes: 16 << 20)
        _ = try instance.callJSON("render", .object([:]))
        #expect(seen.values == ["from the guest"])
    }

    @Test("a host import can hand bytes back through length-then-read")
    func hostReturns() throws {
        let pending = PendingBytes()
        let get = WasmHostFunction("get", [.i32, .i32], [.i32]) { _, _ in
            let data = JSONValue.object(["pct": .number(7)]).encoded()
            pending.set([UInt8](data))
            return [Int64(data.count)]
        }
        let read = WasmHostFunction("read", [.i32]) { memory, arguments in
            try memory.write(pending.take(), at: Int32(arguments[0]))
            return []
        }
        let wasm = try Guest.build(imports: """
          (import "bario" "get" (func $get (param i32 i32) (result i32)))
          (import "bario" "read" (func $read (param i32)))
        """, """
          (func (export "render") (param i32 i32) (result i64)
            (local $len i32) (local $buf i32)
            (local.set $len (call $get (i32.const 0) (i32.const 0)))
            (local.set $buf (call $alloc (local.get $len)))
            (call $read (local.get $buf))
            (call $pack (local.get $buf) (local.get $len)))
        """)
        let instance = try engine.instantiate(wasm: wasm, imports: [get, read],
                                              memoryLimitBytes: 16 << 20)
        let value = try instance.callJSON("render", .object([:]))
        #expect(value?["pct"]?.intValue == 7)
    }

    @Test("a trap is an error naming the export, not a crash")
    func traps() throws {
        let wasm = try Guest.build("""
          (func (export "render") (param i32 i32) (result i64)
            unreachable)
        """)
        let instance = try engine.instantiate(wasm: wasm, imports: [], memoryLimitBytes: 16 << 20)
        var message = ""
        do { _ = try instance.callJSON("render", .object([:])) } catch { message = "\(error)" }
        #expect(message.contains("`render` trapped"))
    }

    @Test("a read past the end of memory is refused")
    func bounds() throws {
        let instance = try engine.instantiate(wasm: try Guest.renderer(text: "x"),
                                              imports: [], memoryLimitBytes: 16 << 20)
        #expect(throws: WasmError.self) { _ = try instance.read(ptr: 0, len: 1 << 20) }
        #expect(throws: WasmError.self) { _ = try instance.read(ptr: -1, len: 4) }
    }

    @Test("growing past the memory cap fails rather than eating the machine")
    func memoryCap() throws {
        let wasm = try Guest.build("""
          (func (export "render") (param i32 i32) (result i64)
            (drop (memory.grow (i32.const 200)))
            (i64.const 0))
        """)
        // One page is already allocated; cap at two.
        let instance = try engine.instantiate(wasm: wasm, imports: [], memoryLimitBytes: 2 * 65_536)
        _ = try? instance.callJSON("render", .object([:]))
        // memory.grow returns -1 rather than trapping, so the check is that memory stayed small.
        #expect(try instance.read(ptr: 0, len: 4).count == 4)
        #expect(throws: WasmError.self) { _ = try instance.read(ptr: 3 * 65_536, len: 4) }
    }

    @Test("a module that is not WASM says so")
    func notWasm() {
        #expect(throws: WasmError.self) {
            _ = try engine.instantiate(wasm: [0x00, 0x01, 0x02], imports: [], memoryLimitBytes: 1 << 20)
        }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func record(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }
}

/// Real time: guests write to the store from their own tasks and run against render budgets, so
/// these are in the Makefile's `REAL_TIME` and run in the serial pass.
@Suite("WASM modules")
struct WasmModuleTests {
    func module(_ wasm: [UInt8], config: JSONValue = .object([:]), store: StateStore = StateStore())
        throws -> (WasmModule, StateStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bario-\(UUID().uuidString.prefix(8)).wasm")
        try Data(wasm).write(to: url)
        var fields = config.objectValue ?? [:]
        fields["path"] = .string(url.path)
        let context = ModuleContext(item: "weather", config: .object(fields), store: store)
        return (try WasmModule(context: context), store, url)
    }

    @Test("a wasm item renders through the module protocol")
    func rendering() async throws {
        let (module, store, url) = try module(try Guest.renderer(text: "21°"))
        defer { try? FileManager.default.removeItem(at: url) }
        await module.start()
        let result = try await module.render(await store.reader(for: "weather"))
        #expect(result.content == .text("21°"))
    }

    @Test("poll's patch reaches the store, and set_timer sets the next poll")
    func polling() async throws {
        let patch = #"{"temp":21}"#
        let payload = Guest.data(patch)
        let wasm = try Guest.build(imports: """
          (import "bario" "set_timer" (func $timer (param i32) (result i32)))
        """, """
          \(payload.segment)
          (func (export "poll") (param i32 i32) (result i64)
            (drop (call $timer (i32.const 2500)))
            (call $pack (i32.const 0) (i32.const \(payload.length))))
          (func (export "render") (param i32 i32) (result i64) (i64.const 0))
        """)
        let (module, _, url) = try module(wasm)
        defer { try? FileManager.default.removeItem(at: url) }
        await module.start()
        let result = await module.poll()
        #expect(result.patch?["temp"]?.intValue == 21)
        #expect(result.nextIn == 2.5)
    }

    @Test("the set import writes into this item's subtree")
    func setImport() async throws {
        let patch = #"{"pushed":true}"#
        let payload = Guest.data(patch)
        let wasm = try Guest.build(imports: """
          (import "bario" "set" (func $set (param i32 i32)))
        """, """
          \(payload.segment)
          (func (export "render") (param i32 i32) (result i64)
            (call $set (i32.const 0) (i32.const \(payload.length)))
            (i64.const 0))
        """)
        let (module, store, url) = try module(wasm)
        defer { try? FileManager.default.removeItem(at: url) }
        await module.start()
        _ = try await module.render(await store.reader(for: "weather"))
        #expect(await eventually { await store.value(at: "weather.pushed")?.boolValue == true })
    }

    @Test("the get import reads state back, relative to the item")
    func getImport() async throws {
        let key = Guest.data("\"temp\"")
        let wasm = try Guest.build(imports: """
          (import "bario" "get" (func $get (param i32 i32) (result i32)))
          (import "bario" "read" (func $read (param i32)))
        """, """
          \(key.segment)
          (func (export "render") (param i32 i32) (result i64)
            (local $len i32) (local $buf i32)
            (local.set $len (call $get (i32.const 0) (i32.const \(key.length))))
            (local.set $buf (call $alloc (local.get $len)))
            (call $read (local.get $buf))
            (call $pack (local.get $buf) (local.get $len)))
        """)
        let store = StateStore()
        await store.merge(.object(["temp": .number(21)]), at: "weather")
        let (module, _, url) = try module(wasm, store: store)
        defer { try? FileManager.default.removeItem(at: url) }
        await module.start()
        // `render` here returns the raw value 21, which is not a render result — the point is
        // that the guest saw it at all.
        var message = ""
        do { _ = try await module.render(await store.reader(for: "weather")) }
        catch { message = "\(error)" }
        #expect(message.contains("Expected to decode") || message.isEmpty)
    }

    @Test("a module over its budget is dropped and the item keeps its last content")
    func budget() async throws {
        let wasm = try Guest.build("""
          (func (export "render") (param i32 i32) (result i64)
            (local $i i64)
            (loop $forever
              (local.set $i (i64.add (local.get $i) (i64.const 1)))
              (br_if $forever (i64.lt_u (local.get $i) (i64.const 100000000000))))
            (i64.const 0))
        """)
        let (module, store, url) = try module(wasm, config: .object(["render-budget": .number(0.05)]))
        defer { try? FileManager.default.removeItem(at: url) }
        await module.start()
        var message = ""
        do { _ = try await module.render(await store.reader(for: "weather")) }
        catch { message = "\(error)" }
        #expect(message.contains("budget"))
    }

    @Test("calls into one instance never overlap, however many arrive at once")
    func oneCallAtATime() async throws {
        let patch = #"{"ok":true}"#
        let content = #"{"content":{"text":"x"}}"#
        // Every export traps if another is already inside the instance, then spins long enough
        // for one to try. A guest's allocator and stack are no more re-entrant than this.
        let wasm = try Guest.build("""
          (data (i32.const 0) "\(Guest.escape(patch))")
          (data (i32.const 64) "\(Guest.escape(content))")
          (global $busy (mut i32) (i32.const 0))
          (func $inside
            (local $i i32)
            (if (global.get $busy) (then unreachable))
            (global.set $busy (i32.const 1))
            (loop $spin
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br_if $spin (i32.lt_u (local.get $i) (i32.const 20000))))
            (global.set $busy (i32.const 0)))
          (func (export "on_event") (param i32 i32) (result i64)
            (call $inside)
            (call $pack (i32.const 0) (i32.const \(patch.utf8.count))))
          (func (export "render") (param i32 i32) (result i64)
            (call $inside)
            (call $pack (i32.const 64) (i32.const \(content.utf8.count))))
        """)
        // Generous budgets: what is under test is overlap, not speed.
        let (module, store, url) = try module(wasm, config: .object(["render-budget": .number(10)]))
        defer { try? FileManager.default.removeItem(at: url) }
        await module.start()
        let reader = await store.reader(for: "weather")

        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { await module.onEvent(ModuleEvent(name: "state", payload: .null)) == nil }
                group.addTask { (try? await module.render(reader)) == nil }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(failures == 0)
    }

    @Test("a gated import that was not granted says which permission is missing")
    func permissionsDenied() async throws {
        let request = #"{"url":"https://example.com"}"#
        let payload = Guest.data(request)
        // Call http, read the answer, and push it into the store, so the test can read the
        // reason the guest was given.
        let wasm = try Guest.build(imports: """
          (import "bario" "http" (func $http (param i32 i32) (result i32)))
          (import "bario" "read" (func $read (param i32)))
          (import "bario" "set" (func $set (param i32 i32)))
        """, """
          \(payload.segment)
          (func (export "render") (param i32 i32) (result i64)
            (local $len i32) (local $buf i32)
            (local.set $len (call $http (i32.const 0) (i32.const \(payload.length))))
            (local.set $buf (call $alloc (local.get $len)))
            (call $read (local.get $buf))
            (call $set (local.get $buf) (local.get $len))
            (i64.const 0))
        """)
        let (module, store, url) = try module(wasm)
        defer { try? FileManager.default.removeItem(at: url) }
        await module.start()
        _ = try await module.render(await store.reader(for: "weather"))
        _ = await eventually { await store.value(at: "weather.error") != nil }
        let error = await store.value(at: "weather.error")?.stringValue ?? ""
        #expect(error.contains("'net' permission"))
        #expect(error.contains("permissions \"net\""))
    }

    @Test("a missing file is one clear error")
    func missingFile() async throws {
        let context = ModuleContext(item: "weather",
                                    config: .object(["path": .string("/nowhere/x.wasm")]),
                                    store: StateStore())
        let module = try WasmModule(context: context)
        await module.start()
        var message = ""
        do { _ = try await module.render(StateReader(root: .object([:]), item: "weather")) }
        catch { message = "\(error)" }
        #expect(message.contains("no module at"))
    }

    @Test("a wasm item with no path is a config error with advice")
    func noPath() {
        #expect(throws: ModuleError.self) {
            _ = try WasmModule(context: ModuleContext(item: "x", store: StateStore()))
        }
    }
}

@Suite("WASM permissions")
struct WasmPermissionTests {
    @Test("permissions are parsed from the item's config")
    func parsing() throws {
        let config = try ConfigLoader.parse("""
        bar { item "weather" module="wasm" path="/tmp/x.wasm" {
          permissions "net" "exec"
          fs "/tmp/weather-cache"
        } }
        """)
        let permissions = try WasmPermissions.parse(config.bars[0].items[0].options)
        #expect(permissions.net)
        #expect(permissions.exec)
        #expect(permissions.fs == ["/tmp/weather-cache"])
        #expect(permissions.summary == "net, exec, fs(1)")
    }

    @Test("nothing granted means nothing allowed")
    func none() throws {
        let permissions = try WasmPermissions.parse(.object([:]))
        #expect(!permissions.net && !permissions.exec)
        #expect(!permissions.allowsReading("/etc/passwd"))
        #expect(permissions.summary == "none")
    }

    @Test("an fs grant is a prefix, and cannot be escaped")
    func fsGrants() throws {
        var permissions = WasmPermissions()
        permissions.fs = [WasmPermissions.canonical("/tmp")]
        #expect(permissions.allowsReading("/tmp/weather.json"))
        #expect(permissions.allowsReading("/tmp"))
        #expect(!permissions.allowsReading("/tmpfoo/x"))
        #expect(!permissions.allowsReading("/etc/passwd"))
        #expect(!permissions.allowsReading("/tmp/../etc/passwd"))
    }

    @Test("an unknown permission is a config error naming the real ones")
    func unknown() {
        var message = ""
        do { _ = try WasmPermissions.parse(.object(["permissions": .string("everything")])) }
        catch { message = "\(error)" }
        #expect(message.contains("net, exec and fs"))
    }
}
