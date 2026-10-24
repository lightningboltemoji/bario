# 23 — wasmtime

DESIGN.md §5's second candidate, and §13's trap: WasmKit could not interrupt a running call, so
a module in an infinite loop leaked a thread until bario exited, and a renderer in one would
have hung the main thread. The `WasmEngine` seam is unchanged; the engine behind it is now
wasmtime's Pulley interpreter, the same engine dock2 runs its plugins on.

## Why Pulley, not the JIT

Pulley is wasmtime's portable interpreter: Cranelift compiles a module to Pulley bytecode and
an interpreter loop runs it. There is no executable memory, so a Developer ID build under the
hardened runtime needs no `allow-jit` or `allow-unsigned-executable-memory` entitlement — the
Cranelift JIT would. dock2 measured that: the JIT was killed under the hardened runtime without
the entitlement, and Pulley ran in every configuration.

What it buys over WasmKit:

- **Interruption.** Epoch interruption against a wall-clock deadline: a guest past its budget
  stops where it stands, within a millisecond.
- **A memory cap through public API** (`ResourceLimiter`). WasmKit's was SPI
  (`@_spi(Fuzzing)`), which is why it was pinned to an exact version.
- **A runtime with a security process**: the Bytecode Alliance's reference engine, fuzzed
  continuously, with advisories.

What it costs:

- **Speed, on guest code that computes.** Measured on an M5 Pro, release builds, against
  WasmKit 0.4.2:

  | | WasmKit | Pulley |
  |---|---|---|
  | `roll.wasm` `draw` — a Rust renderer, serde_json both ways | 96µs | 175µs |
  | `counter.wat` `poll` + `render` — mostly host and JSON work | 47µs | 47µs |
  | a tight loop, 20M iterations | 35ms | 265ms |

  Most of the loop's cost is the deadline itself: epoch interruption puts a check at every
  loop back-edge and function entry, and Pulley interprets it like any other instruction.
  Without it the same loop takes 83ms. Widget-sized work stays far inside every budget; a
  module that crunches numbers is several times slower than it was on WasmKit.
- **A Rust toolchain** to build bario, and a cold engine build of about a minute.
- **About 0.7MB** on the release binary (the static library is 15MB, nearly all of it dropped
  at link).

Two ways to win speed back, neither taken. Pulley has a tail-call dispatch loop
(`--cfg pulley_assume_llvm_makes_tail_calls`), about 30% faster, which stable Rust does not
guarantee: if LLVM ever stops making the tail calls, a long loop overflows the stack.
And wasmtime's Cranelift JIT runs the loop in 9ms, but needs the hardened runtime's
`allow-unsigned-executable-memory` entitlement, which gives up its write-xor-execute
protection for all of bario.

## `Engine/`, and why not wasmtime's own C API

`Engine/` is the crate `bariowasm`: about six hundred lines of Rust exporting a narrow C ABI
(`include/bariowasm.h`), shaped like the `WasmEngine` protocol and nothing more. wasmtime's
general C API would have worked, at the cost of driving dozens of functions and its own value
and error types from Swift. The narrow one is dock2's pattern too, so the two engines read
alike: the same ticker, the same deadline callback, the same Cargo profile.

SwiftPM cannot run cargo, so `make engine` builds the static library and wraps it with its
header as `Frameworks/BarioWasm.xcframework`, which `Package.swift` names as a binary target.
`make build`, `make test` and `make release` run it first; a bare `swift build` works once it has
run. `Frameworks/` is not checked in.

The host imports stay in Swift (`WasmHost`). Swift declares each by name and type, and
bariowasm registers them in the `bario` namespace with one C callback for all of them, which
gets back an index into the list and a `bw_caller`: the guest's memory, borrowed for that one
import. Nothing calls back into the guest from inside an import (13-wasm.md's second
departure), so that memory cannot move under it.

## Deadlines

`WasmInstance.setDeadline(after:)` sets an absolute deadline for every call that follows, and
`callJSON(_:_:budget:)` sets one before it starts, so `alloc`, the export and both `dealloc`s
share one budget. A start function gets one second before anyone has set anything.

Underneath, the engine ticks wasmtime's epoch once a millisecond, but only while some call is
running, so an idle bar does not wake for it. At each tick a store whose deadline has passed is
interrupted; the call returns `BW_DEADLINE`, and Swift throws "`render` ran past its budget and
was interrupted".

Where budgets come from is unchanged: `render-budget` (50ms) for `render` and `on_event`,
`poll-budget` (2s) for `poll` and `init`, the renderer host's 50ms for `draw`, and a second for
a renderer's `init`.

## The limit that remains

An import is host code, and the engine interrupts only guest code. A guest blocked in `http`
(whose timeout the guest chooses), `exec`, or a `get` waiting on the store runs as long as the
import does. So the module keeps its old wall-clock guard: `WasmModule` still abandons the wait
at the same budget and discards the instance; the import finishes alone, and the guest is
interrupted as soon as it returns into WASM. The renderer host still times each draw, and a
draw that overran inside an import is a strike like an interrupted one.

That makes the leak bounded by the import's own timeout instead of by bario's lifetime. Closing
it means imports that do not block, which is an ABI change: dock2's answer is effects out and
results in as later events, never blocking inside a call.

## Tests

`WasmDeadlineTests` (in the Makefile's `REAL_TIME`) proves the interruption: a guest that loops
forever, called synchronously on the test's own thread, returns with the budget error at 50ms —
with WasmKit that call never returned — and a start function that never ends fails to
instantiate after its second. The rest of the WASM suites run on the new engine with only a
budget added to each call; guests are still written in WebAssembly text, now assembled by the `wat` crate inside bariowasm.
