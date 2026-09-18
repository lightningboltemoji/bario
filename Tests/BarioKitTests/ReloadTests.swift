import Foundation
import Testing
@testable import BarioKit

@Suite("File watching")
struct FileWatcherTests {
    func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bario-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A counter a watcher callback can bump from its own queue.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }

        func waitFor(_ target: Int, timeout: Double = 2) async -> Int {
            let deadline = Date().addingTimeInterval(timeout)
            while count < target, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return count
        }
    }

    @Test("a write fires once")
    func writes() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("config.kdl")
        try "a 1".write(to: file, atomically: false, encoding: .utf8)

        let counter = Counter()
        let watcher = FileWatcher(url: file) { counter.bump() }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 100_000_000)
        try "a 2".write(to: file, atomically: false, encoding: .utf8)
        #expect(await counter.waitFor(1) >= 1)
    }

    @Test("an atomic replace fires, which is how every real editor saves")
    func atomicReplace() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("style.css")
        try "item { color: red }".write(to: file, atomically: false, encoding: .utf8)

        let counter = Counter()
        let watcher = FileWatcher(url: file) { counter.bump() }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 100_000_000)
        try "item { color: blue }".write(to: file, atomically: true, encoding: .utf8)
        #expect(await counter.waitFor(1) >= 1)
    }

    @Test("a file that does not exist yet is still watched")
    func creation() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("later.kdl")

        let counter = Counter()
        let watcher = FileWatcher(url: file) { counter.bump() }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 100_000_000)
        try "bar { }".write(to: file, atomically: true, encoding: .utf8)
        #expect(await counter.waitFor(1) >= 1)
    }

    @Test("a file in a directory that does not exist yet is still watched")
    func missingDirectory() async throws {
        let base = try temporaryDirectory()
        let directory = base.appendingPathComponent(".config/bario")
        let file = directory.appendingPathComponent("config.kdl")

        let counter = Counter()
        let watcher = FileWatcher(url: file) { counter.bump() }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 100_000_000)
        // What someone setting bario up for the first time does.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "bar { }".write(to: file, atomically: true, encoding: .utf8)
        #expect(await counter.waitFor(1) >= 1)

        // And once it exists, it is watched like any other file.
        try? await Task.sleep(nanoseconds: 300_000_000)
        try "bar { gap 2 }".write(to: file, atomically: true, encoding: .utf8)
        #expect(await counter.waitFor(2) >= 2)
    }

    @Test("two writes in quick succession are one reload")
    func debounce() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("config.kdl")
        try "a 1".write(to: file, atomically: false, encoding: .utf8)

        let counter = Counter()
        let watcher = FileWatcher(url: file, debounce: 0.3) { counter.bump() }
        defer { watcher.stop() }

        try? await Task.sleep(nanoseconds: 100_000_000)
        try "a 2".write(to: file, atomically: false, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 30_000_000)
        try "a 3".write(to: file, atomically: false, encoding: .utf8)
        _ = await counter.waitFor(1, timeout: 2)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(counter.count == 1, "expected one reload, got \(counter.count)")
    }
}

@Suite("Theme loading")
struct ThemeTests {
    func write(_ config: String, _ style: String?) throws -> (config: URL, style: URL?) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bario-theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.kdl")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        var styleURL: URL?
        if let style {
            styleURL = directory.appendingPathComponent("style.css")
            try style.write(to: styleURL!, atomically: true, encoding: .utf8)
        }
        return (configURL, styleURL)
    }

    @Test("the user's stylesheet cascades on top of the built-in one")
    func layering() throws {
        let files = try write(#"bar { item "a" module="clock" }"#, "item { color: #ff0000 }")
        let theme = try Theme.load(configPath: files.config.path, stylePath: files.style?.path)
        let result = Cascade(stylesheet: theme.stylesheet)
            .style(for: [StyleNode(type: "bar"), StyleNode(type: "item", id: "a")],
                   inheriting: Cascade(stylesheet: theme.stylesheet).style(for: [StyleNode(type: "bar")]).style)
        #expect(result.style.color == .rgba(RGBA(r: 1, g: 0, b: 0)))
        // The built-in rules are still underneath: an item still has bario's padding.
        #expect(result.style.padding != .zero)
    }

    @Test("a broken config reports the line, and does not half-apply")
    func brokenConfig() throws {
        let files = try write("bar {\n  item \"a\"\n}", nil)
        var message = ""
        do {
            _ = try Theme.load(configPath: files.config.path)
        } catch {
            message = "\(error)"
        }
        #expect(message.contains(":2:"))
        #expect(message.contains("needs module="))
    }

    @Test("a broken stylesheet reports the line too")
    func brokenStyle() throws {
        let files = try write(#"bar { item "a" module="clock" }"#, "item {\n  colour: red;\n}")
        var message = ""
        do {
            _ = try Theme.load(configPath: files.config.path, stylePath: files.style?.path)
        } catch {
            message = "\(error)"
        }
        #expect(message.contains(":2:"))
        #expect(message.contains("did you mean 'color'"))
    }

    @Test("with no files at all there is still a bar")
    func defaults() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bario-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("BARIO_CONFIG_DIR", directory.path, 1)
        defer { unsetenv("BARIO_CONFIG_DIR") }
        let theme = try Theme.load()
        #expect(theme.configURL == nil)
        #expect(!theme.config.bars.isEmpty)
        #expect(!theme.stylesheet.rules.isEmpty)
    }
}
