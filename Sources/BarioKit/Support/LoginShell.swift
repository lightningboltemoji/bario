import Foundation

/// The environment a terminal would have given bario, for a bario that launchd started.
///
/// Run from a terminal, bario inherits the shell's environment. Opened from Finder, with `open`, or
/// at login, launchd starts it with next to none: `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`, so a
/// command from Homebrew, cargo or anywhere else is not found. An `exec` item or a `source` that
/// works under `bario --run` then fails under Bario.app, silently when it is a source, and an
/// override like `BARIO_SOCK` that the CLI sees, the bar does not.
///
/// So a bario that launchd started asks the user's login shell for its environment, once, and takes
/// it on before anything reads it. Every process bario starts inherits it, and so do bario's own
/// lookups of `BARIO_CONFIG`, `BARIO_SOCK` and the rest. A new terminal window does the same thing,
/// and editors opened from the Dock do it for the same reason.
public enum LoginShell {
    /// Take on the login shell's environment. Call before anything reads the environment or starts
    /// a thread: `setenv` is safe alongside neither.
    public static func adopt(timeout: Double = 5) {
        let shell = path
        guard let environment = environment(shell: shell, timeout: timeout) else {
            warn("could not read \(shell)'s environment within \(Int(timeout))s; commands run with "
                 + "PATH=\(ProcessInfo.processInfo.environment["PATH"] ?? "")")
            return
        }
        for (key, value) in environment where !bookkeeping.contains(key) {
            setenv(key, value, 1)
        }
    }

    /// The user's login shell: `SHELL`, which launchd sets from the user's record, or the record.
    static var path: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], shell.hasPrefix("/") { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    /// Variables that describe the shell that printed them, not a process it would start.
    static let bookkeeping: Set<String> = ["_", "SHLVL", "PWD", "OLDPWD"]

    /// The environment `shell` sets up as a login shell and an interactive one, which is what a
    /// terminal window runs: login reads `.zprofile` and `.bash_profile`, and interactive reads
    /// `.zshrc` and `.bashrc`, where most people set `PATH`. Nil if the shell cannot start, or has
    /// not printed it within `timeout`.
    ///
    /// Read up to the closing marker, not to the end of output. A startup file can leave something
    /// running that keeps stdout open, like an agent or a prompt's daemon, and then the end never
    /// comes. Startup files can print too, which is why there are markers at all.
    static func environment(shell: String, timeout: Double) -> [String: String]? {
        let marker = "bario-environment-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf %s \(marker); /usr/bin/env -0; printf %s \(marker)"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        let output = MarkedOutput(marker: Data(marker.utf8))
        out.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }

        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        let body = output.wait(timeout)
        out.fileHandleForReading.readabilityHandler = nil
        // SIGKILL: an interactive shell ignores SIGTERM.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return body.flatMap(parse)
    }

    /// `env -0`'s output: `NAME=value` entries, each ended by a NUL, so a value can hold anything
    /// but a NUL, newlines included.
    static func parse(_ body: Data) -> [String: String]? {
        var environment: [String: String] = [:]
        for entry in body.split(separator: 0) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")), equals > entry.startIndex else { continue }
            environment[String(decoding: entry[..<equals], as: UTF8.self)]
                = String(decoding: entry[(equals + 1)...], as: UTF8.self)
        }
        return environment.isEmpty ? nil : environment
    }

    /// What was printed between the first two markers, or nil before the second one arrives.
    static func between(_ output: Data, marker: Data) -> Data? {
        guard let open = output.range(of: marker),
              let close = output.range(of: marker, in: open.upperBound..<output.endIndex)
        else { return nil }
        return output[open.upperBound..<close.lowerBound]
    }
}

/// A shell's stdout, collected until the environment between the markers is complete or the
/// output ends.
private final class MarkedOutput: @unchecked Sendable {
    private let marker: Data
    private let lock = NSLock()
    private var data = Data()
    private var body: Data?
    private var finished = false
    private let done = DispatchSemaphore(value: 0)

    init(marker: Data) { self.marker = marker }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        data.append(chunk)
        body = LoginShell.between(data, marker: marker)
        if body != nil || chunk.isEmpty {
            finished = true
            done.signal()
        }
    }

    /// The environment's bytes, or nil if the output ended without it or it took too long.
    func wait(_ timeout: Double) -> Data? {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        finished = true
        return body
    }
}
