import Foundation

/// Runs a command on an interval, or keeps one running and reads its lines. DESIGN.md §3.
public actor ExecModule: Module {
    private let context: ModuleContext
    private let renderer: FormatRenderer
    private let command: Command
    private let interval: Interval
    private let timeout: Double
    /// The longest wait between restarts of a watched command.
    private let maxBackoff: Double
    private var watcher: Task<Void, Never>?
    private var running: Process?
    private var backoff: Double = 0.5
    /// For a watch with `running=`, whether it is switched on; nil for one that always runs.
    private var switchedOn: Bool?

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
        self.maxBackoff = try ExecModule.seconds(context.option("max-backoff"), default: 30,
                                                 option: "max-backoff")

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

        if let running = context.option("running") {
            guard case .watch = interval else {
                throw ModuleError("running= switches a held command on and off, so exec item "
                                  + "\"\(context.item)\" needs interval=\"watch\"")
            }
            guard let on = running.boolValue else {
                throw ModuleError("running= is #true or #false: whether the command starts out running")
            }
            switchedOn = on
        }
    }

    // MARK: - Lifecycle

    public func start() async {
        guard case .watch = interval else { return }
        if let switchedOn {
            await context.store.merge(.object(["running": .bool(switchedOn)]), at: context.item)
            guard switchedOn else { return }
        }
        watcher = Task { [weak self] in await self?.watch() }
    }

    /// `toggle`, `start` and `stop`, from `on-click`, switch a watch with `running=`. One without
    /// it ignores them, so another item's `on-click="emit stop"`, which reaches every module,
    /// cannot take down every watch at once.
    public func onEvent(_ event: ModuleEvent) async -> JSONValue? {
        guard let on = switchedOn else { return nil }
        let wanted: Bool
        switch event.name {
        case "toggle": wanted = !on
        case "start": wanted = true
        case "stop": wanted = false
        default: return nil
        }
        guard wanted != on else { return nil }
        switchedOn = wanted
        if !wanted { await stop() }
        // Written before a new run starts, so it cannot land on top of what that run says. How
        // the last run ended is no news to a command switched on or off since.
        await context.store.merge(.object([
            "running": .bool(wanted), "exit-code": .number(0), "stderr": .null,
        ]), at: context.item)
        // Unless another switch came in while that was written, and turned it back off.
        if wanted, switchedOn == true, watcher == nil {
            backoff = 0.5
            watcher = Task { [weak self] in await self?.watch() }
        }
        return nil
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
        return PollResult(patch: patch, every: seconds)
    }

    public func render(_ state: StateReader) async throws -> RenderResult {
        var classes = ExecModule.classes(from: state.value("class"))
        if (state.value("exit-code")?.intValue ?? 0) != 0 { classes.append("error") }
        if state.value("running")?.boolValue == true { classes.append("running") }
        let tooltip = state.value("tooltip")?.stringValue
            ?? state.value("stderr")?.stringValue?.trimmed.nonEmpty
        // A line carrying a whole content tree shows it, as one pushed to a `data` item does.
        if let tree = state.value("content"), !tree.isNull {
            do {
                let node = try JSONDecoder().decode(Node.self, from: tree.encoded())
                return RenderResult(content: node, classes: classes, tooltip: tooltip)
            } catch let error as DecodingError {
                throw ModuleError("content: \(error.contentMessage)")
            }
        }
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
            try? await Task.sleep(nanoseconds: UInt64(min(backoff, maxBackoff) * 1_000_000_000))
            backoff = min(maxBackoff, backoff * 2)
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
        let exited = ExecModule.termination(of: process)

        do {
            try process.run()
        } catch {
            await context.store.merge(.object([
                "exit-code": .number(127),
                "stderr": .string("could not start `\(command.description)`: \(error.localizedDescription)"),
            ]), at: context.item)
            backoff = min(maxBackoff, max(backoff, 5))
            return
        }
        running = process
        let pid = process.processIdentifier
        ExecModule.held.insert(pid)

        for await line in ExecModule.lines(of: out.fileHandleForReading) {
            guard !Task.isCancelled else { break }
            await context.store.merge(ExecModule.patch(stdout: line, stderr: "", status: 0),
                                      at: context.item)
        }
        let status = await ExecModule.status(exited)
        ExecModule.held.remove(pid)
        // A watch switched off and on again is already running its next process.
        if running === process { running = nil }
        if status != 0, !Task.isCancelled {
            let stderr = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            await context.store.merge(.object([
                "exit-code": .number(Double(status)),
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
        // Not waitUntilExit(); see termination(of:).
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let stdout = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let stderr = (try? err.fileHandleForReading.readToEnd()) ?? Data()
        exited.wait()
        return ExecResult(stdout: String(decoding: stdout, as: UTF8.self),
                          stderr: String(decoding: stderr, as: UTF8.self),
                          status: process.terminationStatus)
    }

    /// The process's exit, to await. Not `waitUntilExit()`: without a termination handler,
    /// Foundation hands the exit to the run loop of the thread that launched the process and
    /// waits there for it, and on a concurrency thread it can wait for good — a watch sat
    /// in it for minutes on an `emira watch` long since reaped. A handler is called from a
    /// dispatch queue instead. Set here, before `run()`, so an exit cannot come first.
    static func termination(of process: Process) -> AsyncStream<Int32> {
        AsyncStream { continuation in
            process.terminationHandler = { process in
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
        }
    }

    /// A pipe's lines as they arrive, ending when it closes. Not `FileHandle.bytes`: every
    /// `AsyncBytes` in a process reads on one serial queue, with a blocking `read`, so a watch
    /// that had gone quiet held every other watch's lines until it spoke again.
    static func lines(of handle: FileHandle) -> AsyncStream<String> {
        let splitter = LineSplitter()
        return AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    if let rest = splitter.rest() { continuation.yield(rest) }
                    continuation.finish()
                    return
                }
                for line in splitter.append(chunk) { continuation.yield(line) }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// The exit status, or -1 if the wait was cancelled first.
    static func status(_ exited: AsyncStream<Int32>) async -> Int32 {
        for await status in exited { return status }
        return -1
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

    /// A duration like `"5s"`, or a number of seconds.
    static func seconds(_ value: JSONValue?, default fallback: Double, option: String) throws -> Double {
        let seconds: Double?
        switch value {
        case nil, .null?: return fallback
        case .number(let number)?: seconds = number
        case .string(let raw)?: seconds = ConfigLoader.parseDuration(raw)
        default: seconds = nil
        }
        guard let seconds, seconds > 0 else {
            throw ModuleError("\(option) takes a duration like \"5s\"")
        }
        return seconds
    }

    static func classes(from value: JSONValue?) -> [String] {
        switch value {
        case .some(.string(let one)): return one.split(separator: " ").map(String.init)
        case .some(.array(let list)): return list.compactMap(\.stringValue)
        default: return []
        }
    }
}

extension ExecModule {
    /// Every watch's process, for the one moment `stop()` cannot reach them: bario quitting,
    /// when no task gets another turn. A watch that is quiet otherwise outlives bario until it
    /// next writes, and one held for what it does, like `caffeinate`, until it is killed.
    static let held = HeldProcesses()

    /// Ends every watch's process group. Synchronous, for `applicationWillTerminate` and signal
    /// handlers.
    public static func terminateHeld() {
        for pid in held.all { kill(-pid, SIGTERM) }
    }
}

final class HeldProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    func insert(_ pid: pid_t) { lock.withLock { _ = pids.insert(pid) } }
    func remove(_ pid: pid_t) { lock.withLock { _ = pids.remove(pid) } }
    var all: Set<pid_t> { lock.withLock { pids } }
}

/// Bytes in, whole lines out, without their `\n` or `\r\n`.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(LineSplitter.text(pending[pending.startIndex..<newline]))
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// What is left after the last newline: the last line of output that did not end in one.
    func rest() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { pending = Data() }
        return pending.isEmpty ? nil : LineSplitter.text(pending)
    }

    private static func text(_ bytes: Data) -> String {
        let line = bytes.last == 0x0D ? bytes.dropLast() : bytes
        return String(decoding: line, as: UTF8.self)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
