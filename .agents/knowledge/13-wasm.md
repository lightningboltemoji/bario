# 13 — WASM modules

DESIGN.md §5. User logic reachable from many languages through one small API, running without
being able to wreck anything. WASM gives the language independence and the sandbox; the API
surface is ours to keep small.

## Runtime

WasmKit (swiftwasm/WasmKit), pinned at 0.2.2: pure Swift, a SwiftPM dependency, an
interpreter. Zero build friction, and widget code is tiny. The `WasmEngine` protocol stands
between bario and it, so swapping in wasmtime's C API later — for JIT, fuel metering and
epoch interruption — is one file.

Two pins worth knowing about: WasmKit 0.3 requires macOS 15 and bario targets 14, and 0.2.2
predates swift-system 1.6's `Stat` rename, so `swift-system` is held at 1.5.0.

## The ABI, and two places it departs from §5

Core WASM, bytes in, bytes out, payloads are the same JSON documents the socket carries.

**Guest exports** (all optional except `render`):

```
alloc(len: i32) -> i32
init(ptr, len)
poll(ptr, len)     -> i64      state patch json
on_event(ptr, len) -> i64      event json in, state patch out
render(ptr, len)   -> i64      state json in, render result json out
draw(ptr, len)     -> i64      renderer modules (increment 16)
```

**Departure 1: `(ptr, len)` is packed into one `i64`**, high 32 bits the pointer, low 32 the
length. Core WASM's multi-value return is awkward to emit from several of the toolchains the
PDKs target, and one integer is thirty lines in any language. `0` means "nothing to say".

**Host imports**, namespace `bario`:

```
log(level: i32, ptr, len)
now() -> i64                       ms since epoch
set(ptr, len)                      state patch json, into this item's subtree
get(ptr, len) -> i32               key json in; returns the byte length of the answer
read(ptr)                          copies the pending answer into guest memory
emit(ptr, len)
subscribe(ptr, len)
set_timer(ms: i32) -> i32          next poll in ms; replaces the config interval
request_frame()
exec(ptr, len) -> i32              argv json in, {status, stdout, stderr} out   [gated]
read_file(ptr, len) -> i32                                                      [gated]
http(ptr, len) -> i32              {method, url, headers, body}                 [gated]
```

**Departure 2: a host import that produces bytes returns their length and stashes them**, and
the guest copies them out with `read(ptr)` once it has allocated a buffer. §5 writes these as
returning `(ptr, len)`, but handing bytes *back* into the sandbox means calling the guest's
`alloc` from inside a host call, and depending on interpreter re-entrancy is a bad bet to
build an ABI on. Two calls instead of one; the PDK hides both.

## Permissions

```kdl
item "weather" module="wasm" path="~/.config/bario/modules/weather.wasm" interval="10m" {
  permissions "net" "exec"
  fs "~/.cache/weather"
  config city="Vancouver" units="metric"
}
```

A gated import that was not granted is still *defined* — otherwise the module fails to
instantiate with a link error nobody can read — but calling it returns an error payload
saying which permission is missing. A module that asks for nothing can do nothing but
compute, which is the point.

`fs` grants are path prefixes, resolved and compared after symlinks, so `~/.cache/weather`
does not become a route to `~/.ssh`. `net` is host-level: `http` only, no sockets. `exec`
runs a command with the same budget an `exec` item gets.

## Budgets, and the honest limit

Each instance runs on its own actor with a per-call budget: 50ms for `render` and `draw`,
longer for `poll`. Over budget, the call is abandoned, the item keeps its last content plus
`.stale`, and the instance is dropped and rebuilt on the next call with backoff.

The honest part (DESIGN.md §13 anticipates it): WasmKit has no way to interrupt a running
call, so "abandoned" means the host stops waiting, not that the guest stops running. A module
in a genuinely infinite loop leaks one thread until bario exits. That is a leak, and it is the
reason the engine is behind a protocol; it must not also be a corruption, so an abandoned call
keeps its instance to itself. The instance is discarded before the next call starts, and the
bytes `get` stashes for `read` and the requests a guest makes (timer, frame, subscriptions)
belong to the instance, not the item, so a replacement shares nothing with the call it replaced.

Calls into one instance run one at a time, queued on the module. An instance is one thread's
worth of stack and heap, and the actor alone does not ensure that: it is re-entrant across
the `await` on a call's budget, so without the queue an event arriving mid-render ran in the
same instance at once. That showed up as a guest `out of bounds memory access` inside its own
allocator — two calls' `get`/`read` pairs crossed, and one wrote a longer answer into the
other's buffer — and as a segfault in WasmKit itself. A queued call's budget starts when it
does, not when it was asked for. Memory is capped at 16MB per instance through WasmKit's resource
limiter.

## Where the tiers meet

An external process and a WASM module use the same verbs. A WASM module is a provider that
happens to run in-process, sandboxed, with a `render` hook — so a bubble prototyped as a shell
script and `bario set` can be promoted without changing the item's config or its styling.

## Tests

Guests are written in WebAssembly text and assembled in-process with WasmKit's own `WAT`
module, so the tests exercise real WASM with no toolchain to install: a module that renders
text, one that reads state through `get`/`read`, one that writes state through `set`, one that
sets its own timer, one that traps, one that loops forever (budget), one that asks for a
gated import it was not granted, and one that tries to allocate past the memory cap.
