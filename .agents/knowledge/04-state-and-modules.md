# 04 — The state store, the module protocol, and the first modules

## The idea being implemented

DESIGN.md's organising sentence: **content is a pure function of state.** Providers write
state; modules render state to content; push and pull become the same thing. This increment
builds the middle of that diagram and the two modules that need nothing from the system.

```
providers ─▶ StateStore ─▶ ModuleHost ─▶ RenderResult
             actor         one actor      cached per item
                           per module
```

## `StateStore`

An actor holding one `JSONValue` object: item name → that item's subtree, exactly the shape
the socket's `set`/`get` verbs address (`"battery"`, `"battery.pct"`).

- `merge(_ patch:at:)` — deep merge, `null` deletes; the one semantics from increment 01.
  Under an item's key, a `content` tree is replaced whole rather than merged.
- `replace(_ value:at:)` — what `content` and a module's own render output use.
- A write that changes no value is no write: no version, no notification, nothing dirty. One
  that changes something dirties the readers of the paths that changed
  ([21-sources-modes-arrivals.md](21-sources-modes-arrivals.md)).
- `value(at:)`, `snapshot()`.
- **Read tracking.** `render(state:)` is given a `StateReader` that records every path it
  touches. The store keeps those paths per item, so a write invalidates exactly the items
  that read it. This is the "renders are cached" requirement in §3, and it is what keeps a
  hovering pointer or an animation from ever calling a module.
- **Subscriptions.** `changes(matching:)` yields paths as they change, with `*` globbing, so
  the socket's `subscribe state:battery.*` and a module's own `subscribe` are one mechanism.
  `values(of:)` yields the values at some paths, now and after every write that changes one,
  in order; modes are decided from it.

A write returns the set of item names whose cached render is now stale; the host re-renders
exactly those.

## `Module`

One protocol, three backends (§3). Built-ins conform in Swift; `exec` conforms by running a
process (increment 08); WASM conforms by exporting functions (increment 13).

```swift
protocol Module: Actor {
  init(context: ModuleContext) throws          // config, item name, a handle to the store
  func poll() async -> JSONValue?              // a state patch, or nil
  func onEvent(_ event: ModuleEvent) async -> JSONValue?
  func render(_ state: StateReader) async throws -> RenderResult
}
```

Defaults make every method optional but `render`. `ModuleContext` carries the item's config
as `JSONValue` — the same bytes a WASM module gets from `init(ptr, len)`.

`ModuleHost` owns the instances: it runs each module's poll timer, feeds it events, calls
`render` when its state is dirty, and caches the last good `RenderResult`. A module that
throws or overruns keeps its last content and gains the `.stale` class; it never takes the
bar down. An overrun render is not thrown away: it lands when it finishes, unless a newer
render already has (renders are numbered as they start). Under memory pressure every render
can overrun, and discarding them froze an item on whatever it showed last.

Periodic polls keep one clock, `Tick`: an item polled every N seconds polls at the next
multiple of N on the wall clock, 5ms past it, so every item on one period polls at the same
moment and its changes reach the screen in one frame (see the refresh rule in
[17-frame-loop.md](17-frame-loop.md)). The clock item is one more item on the 1s tick, or the
60s one without seconds. `PollResult.every` asks for a tick; `nextIn` is an exact delay, for
backoff and anything else that is not a period; the configured interval is ticked too.

## Format strings

The waybar affordance, and the 80% case (§2). `format = "{icon} {pct}%"` compiles once into
a template of literals and slots, then renders against state:

- `{slot}` — a value from this item's state; a slot named `icon` expands to an `icon` node
  rather than text, so formats mix icons and text;
- `{slot:spec}` — a per-slot format: `{pct:%.1f}` for numbers, `{now:HH:mm}` for dates
  (`DateFormatter` patterns), `{name:20}` to truncate with an ellipsis;
- `{{` and `}}` are literal braces;
- a missing slot renders empty, and the template records which slots it read so the cache
  knows the dependency without running anything.

A format with exactly one text run produces a `text` node; a mixed one produces a `row`.
Slots keep their name as a class, so `#battery .pct` in the design's stylesheet works with no
extra configuration.

## The first two modules

- **`text`** — static content from config: `item "hello" module="text" text="hi"`. Also the
  module `data` items degrade to before anything is pushed.
- **`clock`** — a timer aligned to the next second or minute, writing `now` into the store.
  The alignment matters: a clock that ticks 0.5s late looks broken. Slots: `now` (the date,
  formatted by the format spec, default `HH:mm`), plus `epoch`.
- **`data`** — no source of its own; renders whatever was pushed under its key (§3), which
  is what makes `bario set ci '{"status": "green"}'` work with no module at all. It lands
  here because it is nothing but the store plus a format string.

## Tests

Store merge/replace/delete and path semantics; read tracking invalidates the right items and
only those; glob subscriptions; format string compilation, every spec form, missing slots,
literal braces; the clock's alignment maths; a module that throws keeps its last content and
gains `.stale`; an overrun render lands when it finishes, and never over a newer one.
