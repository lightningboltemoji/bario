import Foundation
import Testing
@testable import BarioKit

/// Real time: every test here but the parsing one runs a process, so they are in the Makefile's
/// `REAL_TIME` and run in the serial pass.
@Suite("exec")
struct ExecTests {
    func module(_ kdl: String) throws -> (ExecModule, StateStore, String) {
        let config = try ConfigLoader.parse("bar { \(kdl) }")
        let item = config.bars[0].items[0]
        let store = StateStore()
        let context = ModuleContext(item: item.name, config: item.options, format: item.format,
                                    interval: item.interval, store: store)
        return (try ExecModule(context: context), store, item.name)
    }

    /// Poll once and render, the way the host does.
    func run(_ kdl: String) async throws -> (RenderResult, JSONValue) {
        let (module, store, name) = try module(kdl)
        await module.start()
        let poll = await module.poll()
        if let patch = poll.patch { await store.merge(patch, at: name) }
        let result = try await module.render(await store.reader(for: name))
        await module.stop()
        return (result, await store.value(at: name) ?? .null)
    }

    @Test("plain text output becomes the text slot")
    func plainText() async throws {
        let (result, state) = try await run(#"item "a" module="exec" { command "echo hello" }"#)
        #expect(state["text"]?.stringValue == "hello")
        #expect(result.content == .text("hello", classes: ["text"]))
        #expect(state["exit-code"]?.intValue == 0)
    }

    @Test("an argv list is executed directly, without a shell")
    func argv() async throws {
        let (_, state) = try await run("""
        item "a" module="exec" { command "printf" "%s-%s" "x" "y" }
        """)
        #expect(state["text"]?.stringValue == "x-y")
    }

    @Test("a JSON object is the item's state, key by key")
    func jsonOutput() async throws {
        let (_, state) = try await run("""
        item "a" module="exec" format="{temp}°" {
          command "echo '{\\"temp\\": 21, \\"city\\": \\"YVR\\"}'"
        }
        """)
        #expect(state["temp"]?.intValue == 21)
        #expect(state["city"]?.stringValue == "YVR")
    }

    @Test("a line carrying a whole content tree shows it")
    func contentTree() async throws {
        let (result, _) = try await run("""
        item "a" module="exec" {
          command "echo '{\\"content\\": {\\"row\\": {\\"children\\": [{\\"text\\": \\"x\\", \\"class\\": \\"focused\\"}]}}, \\"class\\": \\"on\\"}'"
        }
        """)
        #expect(result.content == .row([.text("x", classes: ["focused"])]))
        #expect(result.classes == ["on"])
    }

    @Test("waybar's own keys keep their meaning")
    func waybarShape() async throws {
        let (result, _) = try await run("""
        item "a" module="exec" {
          command "echo '{\\"text\\": \\"5\\", \\"tooltip\\": \\"five\\", \\"class\\": [\\"warn\\", \\"big\\"]}'"
        }
        """)
        #expect(result.content == .text("5", classes: ["text"]))
        #expect(result.tooltip == "five")
        #expect(result.classes == ["warn", "big"])
    }

    @Test("a non-zero exit adds .error and puts stderr in the tooltip")
    func failure() async throws {
        let (result, state) = try await run("""
        item "a" module="exec" { command "echo oops >&2; exit 3" }
        """)
        #expect(state["exit-code"]?.intValue == 3)
        #expect(result.classes.contains("error"))
        #expect(result.tooltip == "oops")
    }

    @Test("a command that does not exist is one error bubble, not a crash")
    func missingCommand() async throws {
        let (result, state) = try await run(#"item "a" module="exec" { command "definitely-not-a-command" }"#)
        #expect(state["exit-code"]?.intValue != 0)
        #expect(result.classes.contains("error"))
    }

    @Test("an exec item with no command is a config error with advice")
    func noCommand() throws {
        #expect(throws: ModuleError.self) {
            _ = try module(#"item "a" module="exec""#)
        }
    }

    @Test("watch mode reads lines as they arrive")
    func watching() async throws {
        let (module, store, name) = try module("""
        item "a" module="exec" interval="watch" {
          command "for i in 1 2 3; do echo line-$i; sleep 0.05; done"
        }
        """)
        // Subscribe rather than sample the store: every line the module writes is delivered, so a
        // machine too busy to be read in time cannot miss one — nor, once the finished command
        // has been restarted, see line-1 again and take it for the last line that arrived.
        let changes = await store.changes(matching: name)
        await module.start()
        let reader = Task {
            var seen: [String] = []
            for await change in changes {
                if let text = change.value["text"]?.stringValue, seen.last != text {
                    seen.append(text)
                }
                if seen.last == "line-3" { break }
            }
            return seen
        }
        // A ceiling, so a line that never arrives fails this test rather than hanging it. It is
        // for a slow machine, not for three lines 50ms apart: the reader leaves at line-3.
        let ceiling = Task { try? await Task.sleep(nanoseconds: 30_000_000_000); reader.cancel() }
        let seen = await reader.value
        ceiling.cancel()
        await module.stop()
        #expect(seen.contains("line-1"))
        #expect(seen.last == "line-3")
    }

    @Test("a watched command that exits is restarted")
    func restarts() async throws {
        let path = NSTemporaryDirectory() + "bario-exec-test-\(getpid()).count"
        try? FileManager.default.removeItem(atPath: path)
        let (module, _, _) = try module("""
        item "a" module="exec" interval="watch" {
          command "echo x >> \(path); echo tick"
        }
        """)
        func runs() -> Int {
            (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").count ?? 0
        }
        await module.start()
        // A second run, half a second of backoff after the first: waited for, not timed.
        let restarted = await eventually { runs() >= 2 }
        await module.stop()
        #expect(restarted, "expected the command to be restarted, ran \(runs()) times")
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("output parsing, without running anything")
    func parsing() {
        #expect(ExecModule.patch(stdout: " hi \n", stderr: "", status: 0)["text"]?.stringValue == "hi")
        #expect(ExecModule.patch(stdout: "[1,2]", stderr: "", status: 0)["text"]?.stringValue == "[1,2]")
        #expect(ExecModule.patch(stdout: "42", stderr: "", status: 0)["text"]?.stringValue == "42")
        let object = ExecModule.patch(stdout: #"{"a": 1}"#, stderr: "", status: 0)
        #expect(object["a"]?.intValue == 1)
        #expect(object["text"]?.stringValue == "")
        #expect(ExecModule.classes(from: .string("a b")) == ["a", "b"])
        #expect(ExecModule.classes(from: .array([.string("a")])) == ["a"])
        #expect(ExecModule.classes(from: nil).isEmpty)
    }
}
