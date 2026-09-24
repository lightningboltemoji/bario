import Foundation
import Testing
@testable import BarioKit

/// Real time: these wait on the kernel's file events, so they are in the Makefile's `REAL_TIME`
/// and run in the serial pass.
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
    }

    /// Debounce timers the test fires by hand. Two writes "in quick succession" in real time are
    /// only as quick as a busy machine lets the test make them; with these, nothing reloads
    /// until the test says the quiet period is over.
    final class ManualDelays: @unchecked Sendable {
        private let lock = NSLock()
        private var scheduled: [(seconds: Double, work: DispatchWorkItem)] = []

        func delay(_ seconds: Double, _ work: DispatchWorkItem) {
            lock.lock(); scheduled.append((seconds, work)); lock.unlock()
        }

        var seconds: [Double] { lock.lock(); defer { lock.unlock() }; return scheduled.map(\.seconds) }
        var live: Int { lock.lock(); defer { lock.unlock() }; return scheduled.filter { !$0.work.isCancelled }.count }

        /// The quiet period ends for every reload check still coming.
        func fire() {
            lock.lock()
            let due = scheduled.map(\.work).filter { !$0.isCancelled }
            lock.unlock()
            due.forEach { $0.perform() }
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
        #expect(await eventually { counter.count >= 1 })
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
        #expect(await eventually { counter.count >= 1 })
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
        #expect(await eventually { counter.count >= 1 })
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
        #expect(await eventually { counter.count >= 1 })

        // And once it exists, it is watched like any other file.
        try? await Task.sleep(nanoseconds: 300_000_000)
        try "bar { height 30 }".write(to: file, atomically: true, encoding: .utf8)
        #expect(await eventually { counter.count >= 2 })
    }

    @Test("two writes in quick succession are one reload")
    func debounce() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("config.kdl")
        try "a 1".write(to: file, atomically: false, encoding: .utf8)

        let counter = Counter()
        let delays = ManualDelays()
        let watcher = FileWatcher(url: file, debounce: 0.3, delay: delays.delay) { counter.bump() }
        defer { watcher.stop() }

        // Each change puts the reload off again: of the checks asked for — arming's own, and one
        // per change — only the last is still coming.
        watcher.schedule()
        watcher.schedule()
        #expect(delays.seconds == [0.3, 0.3, 0.3])
        #expect(delays.live == 1)

        // Two real writes. However the kernel reports them, nothing reloads until the quiet
        // period ends, and then once: both writes are in the file by the time anything looks.
        try "a 2".write(to: file, atomically: false, encoding: .utf8)
        try "a 3".write(to: file, atomically: false, encoding: .utf8)
        #expect(await eventually { delays.seconds.count > 3 }, "the watcher heard the writes")
        #expect(counter.count == 0)
        #expect(await eventually { delays.fire(); return counter.count > 0 })
        // A check that runs later, for an event that was still on its way, finds nothing new.
        delays.fire()
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
