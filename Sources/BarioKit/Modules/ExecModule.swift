import Foundation

/// Runs a command on an interval, or keeps one running and reads its lines. DESIGN.md §3.
public actor ExecModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    private let command: Command
    private let interval: Interval
    private let timeout: Double
    private var watcher: Task<Void, Never>?
    private var running: Process?
    private var backoff: Double = 0.5

    enum Command: Sendable {
        /// An argv, executed directly.
        case argv([String])
        /// One string, through `/bin/sh -c`, because that is what people write.
        case shell(String)

        var launch: (path: String, arguments: [String])? {
            switch self {
            case .shell(let line):
                return ("/bin/sh", ["-c", line])
            case .argv(let words):
                guard let first = words.first else { return nil }
                return first.contains("/")
                    ? (first, Array(words.dropFirst()))
                    : ("/usr/bin/env", words)
            }
        }

        var description: String {
            switch self {
            case .shell(let line): return line
            case .argv(let words): return words.joined(separator: " ")
            }
        }
    }

    public init(context: ModuleContext) throws {
        self.context = context
        self.renderer = FormatRenderer(context, format: "{text}", fallback: "text")
        self.interval = context.interval ?? .seconds(context.double("interval", default: 5) ?? 5)
        self.timeout = context.double("timeout", default: 10) ?? 10

        let raw = context.config["command"] ?? context.config["exec"]
        switch raw {
        case .some(.string(let line)):
            command = .shell(line)
        case .some(.array(let words)):
            let argv = words.compactMap(\.stringValue)
            guard !argv.isEmpty else {
                throw ModuleError("exec item \"\(context.item)\" has an empty command")
            }
            command = .argv(argv)
        default:
            throw ModuleError("exec item \"\(context.item)\" needs a command, e.g. "
                              + "`command \"date\" \"+%H:%M\"` or `command \"date +%H:%M\"`")
        }
    }

    // MARK: - Lifecycle

    public func start() async {
        guard case .watch = interval else { return }
        watcher = Task { [weak self] in await self?.watch() }
    }

    public func stop() async {
        watcher?.cancel()
        watcher = nil
        terminate()
    }

    private func terminate() {
        guard let process = running, process.isRunning else { return }
        // Kill the group: a watched `sh -c` otherwise leaves its child behind.
        kill(-process.processIdentifier, SIGTERM)
        process.terminate()
        running = nil
    }

    public func poll() async -> PollResult {
        guard case .seconds(let seconds) = interval else { return PollResult() }
        let patch = await runOnce()
        return PollResult(patch: patch, nextIn: seconds)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        var classes = ExecModule.classes(from: state.value("class"))
        if (state.value("exit-code")?.intValue ?? 0) != 0 { classes.append("error") }
        let tooltip = state.value("tooltip")?.stringValue
            ?? state.value("stderr")?.stringValue?.trimmed.nonEmpty
        return RenderResult(content: try renderer.render(state), classes: classes, tooltip: tooltip)
    }

    // MARK: - Running

    private func runOnce() async -> JSONValue {
        guard let launch = command.launch else {
            return .object(["text": .string(""), "exit-code": .number(127),
                            "stderr": .string("empty command")])
        }
        let deadline = timeout
        let description = command.description
        let item = context.item

        let result: ExecResult
        do {
            result = try await withBudget(deadline) {
                try ExecModule.run(path: launch.path, arguments: launch.arguments, item: item)
            }
        } catch {
            return .object(["exit-code": .number(-1),
                            "stderr": .string("`\(description)` \(error)")])
        }
        return ExecModule.patch(stdout: result.stdout, stderr: result.stderr, status: result.status)
    }

    /// Keep the process running and read its lines. waybar's continuous `exec`.
    private func watch() async {
        while !Task.isCancelled {
            let started = Date()
            await runWatched()
            guard !Task.isCancelled else { return }
            // A process that stayed up has earned a fresh start.
            if Date().timeIntervalSince(started) > 10 { backoff = 0.5 }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(30, backoff * 2)
        }
    }

    private func runWatched() async {
        guard let launch = command.launch else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.path)
        process.arguments = launch.arguments
        process.environment = ExecModule.environment(item: context.item)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Its own group, so terminate() reaches the children too.
        process.qualityOfService = .utility

        do {
            try process.run()
        } catch {
            await context.store.merge(.object([
                "exit-code": .number(127),
                "stderr": .string("could not start `\(command.description)`: \(error.localizedDescription)"),
            ]), at: context.item)
            backoff = min(30, max(backoff, 5))
            return
        }
        running = process

        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard !Task.isCancelled else { break }
                await context.store.merge(ExecModule.patch(stdout: line, stderr: "", status: 0),
                                          at: context.item)
            }
        } catch {
            // A closed pipe is how this ends; it is not news.
        }
        process.waitUntilExit()
        running = nil
        if process.terminationStatus != 0, !Task.isCancelled {
            let stderr = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            await context.store.merge(.object([
                "exit-code": .number(Double(process.terminationStatus)),
                "stderr": .string(stderr.trimmed),
            ]), at: context.item)
        }
    }

    // MARK: - Output

    struct ExecResult: Sendable {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    static func environment(item: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["BARIO_ITEM"] = item          // one script can serve several items
        return environment
    }

    static func run(path: String, arguments: [String], item: String) throws -> ExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment(item: item)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let stderr = (try? err.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return ExecResult(stdout: String(decoding: stdout, as: UTF8.self),
                          stderr: String(decoding: stderr, as: UTF8.self),
                          status: process.terminationStatus)
    }

    /// Stdout is plain text, or JSON if it parses. A JSON object is the item's state; anything
    /// else is `text`. waybar's own keys keep their meaning, so its scripts work unchanged.
    static func patch(stdout: String, stderr: String, status: Int32) -> JSONValue {
        let trimmed = stdout.trimmed
        var patch: [String: JSONValue] = [
            "exit-code": .number(Double(status)),
            "stderr": stderr.trimmed.isEmpty ? .null : .string(stderr.trimmed),
        ]
        if let json = try? JSONValue(parsing: trimmed), case .object(let fields) = json {
            for (key, value) in fields { patch[key] = value }
            if patch["text"] == nil { patch["text"] = .string("") }
        } else {
            patch["text"] = .string(trimmed)
        }
        return .object(patch)
    }

    static func classes(from value: JSONValue?) -> [String] {
        switch value {
        case .some(.string(let one)): return one.split(separator: " ").map(String.init)
        case .some(.array(let list)): return list.compactMap(\.stringValue)
        default: return []
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
