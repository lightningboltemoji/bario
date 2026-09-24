import Foundation

// Waiting on the real world.
//
// A test that drives a kernel watch, a process, a socket or a Mach port cannot move a clock by
// hand; the thing it waits for happens when it happens. What it must never do is wait a fixed
// time and then look — "30ms apart", "within 400ms" — because a hosted CI runner is several times
// slower than a laptop, and a test run shares it with every other test in the run. A sleep that is
// ample here is a coin toss there.
//
// So such a test waits *for* what it expects, and gives up only at a ceiling set for the slowest
// machine that runs us. The ceiling costs nothing on a run that passes: the wait ends the moment
// the condition holds.

/// Waits until `condition` holds, looking every 10ms, for at most `seconds`. True if it held.
func eventually(within seconds: Double = 30, isolation: isolated (any Actor)? = #isolation,
                _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
        if try await condition() { return true }
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
