# 14 — PDKs, and the worked example

DESIGN.md §5: "The bytes ABI is thirty lines in any language and we can ship those thirty
lines as a PDK for Rust, Zig, Go (TinyGo), AssemblyScript and C." This increment ships three
of them and the weather module the design names as the worked example.

```
pdk/rust/     a Cargo crate: the ABI, a content-tree builder, and the host imports
pdk/c/        bario.h and bario.c, plus a Makefile for the wasi-sdk
pdk/wat/      the ABI as a WebAssembly text preamble to paste in
examples/weather/   the design's worked example, in Rust
examples/counter.wat  the same lifecycle with no toolchain at all
```

## What a PDK actually hides

Three things, and they are the same three in every language:

1. **The packed `i64` return.** `(ptr << 32) | len`, and `0` for nothing.
2. **`alloc`, and who frees.** The guest owns its memory. The host calls `alloc` to hand
   bytes in; the guest allocates what it returns and the host calls `dealloc` if it is
   exported.
3. **Length-then-read for host answers.** `let n = get(...); let buf = alloc(n); read(buf)`.

Everything above that is JSON in and JSON out, which every language already has.

## Running a module with no toolchain

`WasmKitEngine` sniffs the first four bytes: a `.wasm` binary starts with `\0asm`, and
anything else is assembled as WebAssembly text at load. So `path="…/counter.wat"` works, and
`examples/counter.wat` is a real module that runs on a machine with nothing installed. That
is also how this increment is tested: the Rust and C PDKs cannot be compiled without their
toolchains, so the ABI they implement is proved against a WAT module that implements exactly
the same contract.

## The weather module

The design's example config:

```kdl
item "weather" module="wasm" path="~/.config/bario/modules/weather.wasm" interval="10m" {
  permissions "net"
  config city="Vancouver" units="metric"
}
```

`examples/weather` is that module in Rust. It reads `city` and `units` from `init`, fetches
from wttr.in through the gated `http` import on each `poll`, writes `temp`, `icon` and
`description` into the store with `set`, and renders a row of an icon and a temperature from
whatever state is there — so it still renders the last good reading when the network is down,
which is the whole reason render and poll are separate.

It is about eighty lines, and it never touches the filesystem, a socket, or a process. That
is what `permissions "net"` alone buys.

## Tests

The WAT example is run through the real `WasmModule`: `init` receives its config, `poll`
returns a patch and sets its own timer, and `render` builds a content tree from state. The
Rust and C PDKs are checked for the one thing that can be verified without compiling them —
that the ABI constants and function signatures in each match the host's, by parsing the
sources for the exported names.
