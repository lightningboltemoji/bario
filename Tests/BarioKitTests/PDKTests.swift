import Foundation
import Testing
import WAT
@testable import BarioKit

/// The PDKs cannot be compiled here — Rust and the wasi-sdk are not installed — so the ABI
/// they implement is checked against the host's own list, and proved end to end against the
/// WAT example, which needs no toolchain at all.
@Suite("PDKs")
struct PDKTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // BarioKitTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // the repo

    func read(_ path: String) throws -> String {
        try String(contentsOf: PDKTests.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("the Rust PDK declares exactly the host's imports")
    func rustImports() throws {
        let source = try read("pdk/rust/src/lib.rs")
        guard let block = source.range(of: #"extern "C" {"#) else {
            Issue.record("no extern block"); return
        }
        let body = source[block.upperBound...].prefix(while: { $0 != "}" })
        for name in WasmABI.hostImports {
            #expect(body.contains("fn \(name)("), "the Rust PDK is missing `\(name)`")
        }
    }

    @Test("the C PDK declares exactly the host's imports")
    func cImports() throws {
        let header = try read("pdk/c/bario.h")
        for name in WasmABI.hostImports {
            #expect(header.contains("BARIO_IMPORT(\"\(name)\")"), "the C PDK is missing `\(name)`")
        }
    }

    @Test("every PDK exports alloc and packs (ptr, len) the same way")
    func exports() throws {
        let rust = try read("pdk/rust/src/lib.rs")
        #expect(rust.contains(#"#[no_mangle]"#))
        #expect(rust.contains("pub extern \"C\" fn alloc(len: i32) -> i32"))
        #expect(rust.contains("<< 32"))

        let c = try read("pdk/c/bario.h")
        #expect(c.contains("export_name(\"alloc\")"))
        #expect(c.contains("<< 32"))

        let wat = try read("pdk/wat/bario.wat")
        #expect(wat.contains("(func $alloc (export \"alloc\")"))
        #expect(wat.contains("i64.shl"))
    }

    @Test("the host defines every import a module can ask for")
    func hostDefinesThem() async throws {
        // A guest that imports all of them; if the host is missing one, this fails to link.
        let imports = WasmABI.hostImports.map { name -> String in
            switch name {
            case "log": return #"(import "bario" "log" (func (param i32 i32 i32)))"#
            case "now": return #"(import "bario" "now" (func (result i64)))"#
            case "read": return #"(import "bario" "read" (func (param i32)))"#
            case "set", "emit", "subscribe":
                return "(import \"bario\" \"\(name)\" (func (param i32 i32)))"
            case "set_timer": return #"(import "bario" "set_timer" (func (param i32) (result i32)))"#
            case "request_frame": return #"(import "bario" "request_frame" (func))"#
            default: return "(import \"bario\" \"\(name)\" (func (param i32 i32) (result i32)))"
            }
        }.joined(separator: "\n")

        let wasm = try Guest.build(imports: imports, """
          (func (export "render") (param i32 i32) (result i64) (i64.const 0))
        """)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bario-abi-\(UUID().uuidString.prefix(8)).wasm")
        try Data(wasm).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = StateStore()
        let module = try WasmModule(context: ModuleContext(
            item: "abi", config: .object(["path": .string(url.path)]), store: store))
        await module.start()
        let result = try await module.render(await store.reader(for: "abi"))
        #expect(result.content == nil)
    }
}

@Suite("The WAT example")
struct CounterExampleTests {
    static let path = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("examples/counter.wat").path

    func module() throws -> (WasmModule, StateStore) {
        let store = StateStore()
        let context = ModuleContext(item: "ticks",
                                    config: .object(["path": .string(CounterExampleTests.path)]),
                                    store: store)
        return (try WasmModule(context: context), store)
    }

    @Test("a .wat module is assembled and run with no toolchain")
    func lifecycle() async throws {
        let (module, store) = try module()
        await module.start()

        // poll counts, writes a patch, and asks for the next poll itself.
        let first = await module.poll()
        #expect(first.patch?["ticks"]?.intValue == 1)
        #expect(first.nextIn == 1)
        await store.merge(first.patch!, at: "ticks")

        let second = await module.poll()
        #expect(second.patch?["ticks"]?.intValue == 2)

        // render builds a content tree from what it counted.
        let result = try await module.render(await store.reader(for: "ticks"))
        guard case .row(let row)? = result.content?.kind else { Issue.record("not a row"); return }
        #expect(row.children.count == 2)
        #expect(row.children[0] == .icon("timer", classes: ["icon"]))
        #expect(row.children[1] == .text("2", classes: ["count"]))
    }

    @Test("a binary module is passed through, text is assembled")
    func sniffing() throws {
        let binary = try wat2wasm("(module)")
        #expect(try WasmKitEngine.binary(binary) == binary)

        let text = Array("(module)".utf8)
        let assembled = try WasmKitEngine.binary(text)
        #expect(Array(assembled.prefix(4)) == [0x00, 0x61, 0x73, 0x6D])

        #expect(throws: WasmError.self) {
            _ = try WasmKitEngine.binary(Array("(not wasm at all".utf8))
        }
    }

    @Test("the number formatting in the WAT PDK is right for more than one digit")
    func itoa() async throws {
        let (module, _) = try module()
        await module.start()
        for _ in 0..<11 { _ = await module.poll() }
        let store = StateStore()
        let result = try await module.render(await store.reader(for: "ticks"))
        guard case .row(let row)? = result.content?.kind else { Issue.record("not a row"); return }
        #expect(row.children[1] == .text("11", classes: ["count"]))
    }
}
