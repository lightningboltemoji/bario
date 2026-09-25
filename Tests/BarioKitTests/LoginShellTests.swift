import Foundation
import Testing
@testable import BarioKit

/// Real time: every test here but the parsing one runs a process, so they are in the Makefile's
/// `REAL_TIME` and run in the serial pass.
@Suite("login shell")
struct LoginShellTests {
    /// A script standing in for a login shell. It takes the arguments bario passes one, and runs
    /// `setup` where a shell would read its startup files.
    func shell(_ setup: String) throws -> (path: String, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bario-login-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("shell").path
        try """
        #!/bin/sh
        [ "$1 $2 $3" = "-l -i -c" ] || exit 64
        \(setup)
        exec /bin/sh -c "$4"
        """.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return (path, directory)
    }

    @Test("env -0 output: values keep their = signs and newlines, and a nameless entry is skipped")
    func parsing() {
        let body = Data("PATH=/opt/homebrew/bin:/usr/bin\0A=b=c\0MULTI=one\ntwo\0=junk\0".utf8)
        let environment = LoginShell.parse(body)
        #expect(environment == ["PATH": "/opt/homebrew/bin:/usr/bin", "A": "b=c", "MULTI": "one\ntwo"])
        #expect(LoginShell.parse(Data()) == nil)
    }

    @Test("the environment a login shell sets up, not what its startup files print or leave running")
    func environment() throws {
        let stub = try shell("""
        echo "Last login: yesterday"
        export PATH="/opt/stub/bin:$PATH" BARIO_STUB=yes
        sleep 60 &
        echo $! > "$(dirname "$0")/holder"
        """)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        defer {
            // The holder keeps stdout open for a minute; it is only there to be waited past.
            if let pid = try? String(contentsOf: stub.directory.appendingPathComponent("holder"), encoding: .utf8),
               let holder = Int32(pid.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(holder, SIGTERM)
            }
        }

        // The ceiling is under the holder's minute, so waiting for the output to end fails it.
        let environment = try #require(LoginShell.environment(shell: stub.path, timeout: 30))
        #expect(environment["PATH"]?.hasPrefix("/opt/stub/bin:") == true)
        #expect(environment["BARIO_STUB"] == "yes")
        #expect(environment.keys.allSatisfy { !$0.contains("Last login") })
    }

    @Test("a shell that never prints its environment gives nil, not a hang")
    func hung() throws {
        let stub = try shell("exec sleep 60")
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        #expect(LoginShell.environment(shell: stub.path, timeout: 0.5) == nil)
    }

    @Test("a shell that cannot start gives nil")
    func missing() {
        #expect(LoginShell.environment(shell: "/nonexistent/shell", timeout: 5) == nil)
    }
}
