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

    @Test("a watch that has gone quiet does not hold up another watch's lines")
    func quietNeighbour() async throws {
        let (quiet, _, _) = try module("""
        item "q" module="exec" interval="watch" { command "echo quiet; sleep 30" }
        """)
        let (ticker, store, name) = try module("""
        item "t" module="exec" interval="watch" {
          command "sleep 0.3; for i in 1 2 3; do echo line-$i; sleep 0.1; done; sleep 30"
        }
        """)
        await quiet.start()
        let changes = await store.changes(matching: name)
        await ticker.start()
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
        // Three lines 100ms apart; the quiet watch says nothing more for 30s.
        let ceiling = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); reader.cancel() }
        let seen = await reader.value
        ceiling.cancel()
        await quiet.stop()
        await ticker.stop()
        #expect(seen.last == "line-3", "\(seen)")
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

    @Test("max-backoff takes a duration or seconds, and nothing else")
    func maxBackoff() throws {
        #expect(try ExecModule.seconds(nil, default: 30, option: "max-backoff") == 30)
        #expect(try ExecModule.seconds(.string("5s"), default: 30, option: "max-backoff") == 5)
        #expect(try ExecModule.seconds(.string("500ms"), default: 30, option: "max-backoff") == 0.5)
        #expect(try ExecModule.seconds(.number(2), default: 30, option: "max-backoff") == 2)
        #expect(throws: ModuleError.self) {
            _ = try ExecModule.seconds(.string("soon"), default: 30, option: "max-backoff")
        }
        #expect(throws: ModuleError.self) {
            _ = try ExecModule.seconds(.number(0), default: 30, option: "max-backoff")
        }
        // Read from the config, where a bad one fails the item rather than the restart loop.
        #expect(throws: ModuleError.self) {
            _ = try module(#"item "a" module="exec" interval="watch" max-backoff="soon" { command "true" }"#)
        }
    }

    @Test("a watch that fails fast is retried at max-backoff, and picks up within it")
    func maxBackoffRetries() async throws {
        // `emira watch` with the daemon down: exit 69 at once, until the file says it is up.
        let up = NSTemporaryDirectory() + "bario-exec-test-\(getpid()).up"
        try? FileManager.default.removeItem(atPath: up)
        let (module, store, name) = try module("""
        item "a" module="exec" interval="watch" max-backoff="100ms" {
          command "test -e \(up) || exit 69; echo up; sleep 30"
        }
        """)
        let changes = await store.changes(matching: name)
        await module.start()
        // Down long enough that the default backoff would be 2s from its next try, by now;
        // each failed run's exit has to be seen for the next one to start at all.
        try await Task.sleep(nanoseconds: 1_600_000_000)
        #expect(await store.value(at: name)?["exit-code"]?.intValue == 69)
        FileManager.default.createFile(atPath: up, contents: nil)
        let back = Date()
        let reader = Task {
            for await change in changes where change.value["text"]?.stringValue == "up" { return true }
            return false
        }
        let ceiling = Task { try? await Task.sleep(nanoseconds: 30_000_000_000); reader.cancel() }
        let pickedUp = await reader.value
        let took = Date().timeIntervalSince(back)
        ceiling.cancel()
        await module.stop()
        try? FileManager.default.removeItem(atPath: up)
        #expect(pickedUp)
        // 100ms of backoff and a shell's start, not the 1.9s the default ceiling leaves.
        #expect(took < 1, "picked up \(took)s after the command came back")
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

    @Test("a pipe's bytes become whole lines, however they are cut")
    func lineSplitting() {
        let splitter = LineSplitter()
        #expect(splitter.append(Data("{\"a\"".utf8)).isEmpty)
        #expect(splitter.append(Data(": 1}\nnext\r\nhalf".utf8)) == [#"{"a": 1}"#, "next"])
        #expect(splitter.append(Data("\n\n".utf8)) == ["half", ""])
        #expect(splitter.append(Data("tail".utf8)).isEmpty)
        #expect(splitter.rest() == "tail")
        #expect(splitter.rest() == nil)
    }
}
