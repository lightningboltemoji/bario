# bario — implementation map

A very high level map of what exists and where. Details live in the numbered notes beside
this file; the plan lives in [00-roadmap.md](00-roadmap.md); the intent lives in
[DESIGN.md](../../DESIGN.md).

## Products

| product | what it is |
|---|---|
| `bario` | the bar. `bario --run` is the daemon, other verbs talk to it over the socket. |
| `BarioKit` | the library the executable is built from. |

## BarioKit

| area | holds |
|---|---|
| `Support/` | logging, `NSScreen` menu-bar and notch geometry, `Insets`, PNG dump, single-instance lock |
| `Capture/` | the ScreenCaptureKit backdrop strip, the wallpaper-file fallback, and the window shadows that cannot be photographed and are cast instead — see [19-window-shadows.md](19-window-shadows.md) |
| `Model/` | `JSONValue` (state), `Node`/`RenderResult` (content) |
| `Config/` | a KDL 2.0 reader, and the typed `Config` it builds |
| `Style/` | the CSS subset: parser, selectors, typed properties, cascade, the style stage (`Styler`), the default look |
| `Runtime/` | the `StateStore` actor, the `Module` protocol, format strings, content templates, the `EventBus`, `ModuleHost` |
| `Modules/` | the built-in modules: `text` `clock` `data` `front-app` `battery` `wifi` `volume` `net` `cpu` `mem` `exec` (`wasm` lives in `Wasm/`) |
| `Layout/` | `Metrics`, the flex solver, the `Scene`, the layout stage (`BarLayout`), and `SceneBuilder` (style + layout in one call) |
| `Paint/` | colour resolution, rounded rects, the backdrop cache, display lists and the canvas painter, rasters, offscreen rendering on `CARenderer` |
| `Compositor/` | each bar's layer tree and the commit stage: chrome as layers, raster keys, the node rasterizer, the hole as a mask, the window-shadow plane — see [18-compositor.md](18-compositor.md) |
| `Frame/` | the rendering pipeline of §10: `FrameLoop` (invalidation and the frame), `Bar`, the scheduler, the `Animator` (with the ghosts of items on their way out), the `Lens`, the `ModeTracker`, `Presentation` — see [17-frame-loop.md](17-frame-loop.md) and [21-sources-modes-arrivals.md](21-sources-modes-arrivals.md) |
| `App/` | options and theme loading, the cover window, the view, the controller (glue from AppKit to frame-loop inputs), events, `--shot` |
| `IPC/` | the socket protocol and its verbs (`BarioService`), the server, and the client the CLI uses |
| `Wasm/` | the `WasmEngine` seam, the WasmKit engine, host imports, permissions, the `wasm` module, the renderer registry |

Beside it, `Sources/CBarioShim` holds what Swift cannot reach: `shm_open`, which is variadic, and
the Mach hand-off of shared surfaces, since `bootstrap.h` is invisible to Swift and a message
carrying port rights cannot be built from it.

## The spine

```
providers → state store → render → style → layout → present → commit
                                      └──────── one frame ────────┘
```

Inputs only invalidate; a frame does all the work ([17-frame-loop.md](17-frame-loop.md)).

**All seven phases of DESIGN.md §12 are delivered.**

1. `bario --run` covers the menu bar with the photograph and paints its own bubbles on it,
   laid out by one flex pass that splits at the notch, with the hole cutting through them.
2. The built-in modules fill those bubbles; config and stylesheet reload on save; `bario.app`
   is what permissions attach to.
3. A Unix socket carries the protocol, and the `bario` CLI is a one-for-one wrapper.
4. WASM modules run on WasmKit behind a `WasmEngine` seam, with the bytes ABI, gated host
   imports and per-call budgets; `canvas` display lists are themed by the node's own style, so
   `currentColor` and `var()` mean what they say inside a drawing bario never wrote.
5. Holding Option over a bar closes its hole and lets items take clicks, scrolls and hover;
   `on-click` shortcuts run; styles and layout ease through `transition`.
6. Renderer modules register node types, measure and draw them, and `raster` nodes take
   finished pixels from memory, a file, inline PNG or shared memory.
7. Each bar is a Core Animation layer tree kept up to date by the frame's commit stage: a layer
   per item and node, a raster key per leaf, text and symbols as tinted masks, meters as
   layers, the hole as a mask, renderers drawn at commit per node, `transform` and `animation`
   run by the window server, and native processes' IOSurfaces shown with no copy
   ([18-compositor.md](18-compositor.md)).

What remains is what §12.8 lists as later: popovers, an overflow catch-all item,
`NSAccessibility`, and a Component Model binding.

**A frame draws what changed, and nothing else (§10).** Each bar is a tree of layers, one per
item and node, and commit draws a node's raster only when its raster key changed: moving the
hole sets the mask's properties, a colour change retints a mask, a layout transition moves
layers. Per-item dirty rects were tried in the first version and dropped because a region
reported by whoever changed something misses inputs; a key computed by the frame does not.

**Click-through, measured (increment 15):** a transparent pixel does *not* pass clicks through
on macOS 27 — a real click posted into a fully transparent hole still reaches the cover. So
the cover ignores mouse events except while Option is held over it, and without Option the bar
does not react to the pointer at all ([15-interaction.md](15-interaction.md)).

## Conventions

- One vocabulary: the content tree and the state patch are the same JSON in Swift, over the
  socket and through WASM memory. `schema/content.json` is the published contract; the Swift
  decoder is the enforcement point.
- Parsers are ours (KDL, CSS) because the error messages are the product: everything carries
  a line and column from the tokenizer to the typed model.
- Colours and fonts stay symbolic through the cascade and resolve at paint time, so the
  cascade is pure and `currentColor` can mean what it says inside a renderer.
- An option bario does not recognise on an item is not an error — it belongs to the module.
- `emit` and `subscribe` are one path whether they come from a socket client or a WASM
  module: both go through `EventBus`, and both reach the socket and the subscribed modules.
- A write is what it changed: one that changes no value invalidates and notifies nothing, and
  one that does dirties the readers of what changed, not of everything it wrote. Under an
  item's key, `content` is a tree and is replaced whole.
- A `source` is a module with no bubble, and a `mode` is a condition over the store and time
  that restyles every bar when it flips and decides what `when`/`unless` items are laid out.
  Items that come and go transition from `@starting-style` and to `:leaving`
  ([21-sources-modes-arrivals.md](21-sources-modes-arrivals.md)).
- Renders are cached against the state paths they read, so hover, animation and the hole
  never call a module. An item that has never rendered is not laid out. A module that throws or overruns keeps its last content and wears
  `.stale`; an overrun render still lands when it finishes, unless a newer one has.
- Modules push where the system lets them (`front-app`, `battery`, `volume` are notification
  driven) and poll only where a value must be sampled (`net`, `cpu`, `mem`). Each writes an
  `icon` key so `format="{icon} {pct}%"` needs no symbol names in anyone's config.
- Sampling is config, in durations: `interval` is the rate, and `windows` and `history` mean
  the same seconds whatever it is. A window is exact, the newest raw snapshot against one
  that many samples back ([20-stats-widgets.md](20-stats-widgets.md)).
- A `content` block whose strings name slots is a template, filled from state on every
  render and read-tracked like a format; every module that shows a format shows one.
- `Sources/BarioKit` is the only place with logic; the executables are thin.

## Building and looking at it

`make` and `make test` rather than `swift build` and `swift test` — on a Command Line Tools
install swift-testing's macro plugin needs an explicit `-load-plugin-library`, and SwiftPM
passes link flags for an Xcode-only directory that ld then warns about once per target. The
Makefile handles both; see its comments.

- `bario --run` runs the bar.
- `bario --shot out.png --width 900 --notch 120` renders one bar offscreen to a PNG, with no
  window and no permissions, through the same layer tree the screen shows (`CARenderer`). This
  is how rendering is verified without looking at a screen, and the pixel tests assert pixels
  from it.
- `bario --diagnose` prints the resolved scene as text: items, frames, classes, hole modes.
- `--mode <name>`, with `--shot` or `--diagnose`, holds a mode on, to see what it arranges.
- `bario --run --trace-frames` prints what every frame did; an idle bar prints nothing.
- `make app` builds `bario.app`, which is what Screen Recording and Location permissions
  attach to; `make install` puts it in `/Applications`, `make uninstall` removes it.
- `bario --version` prints the git tag `make app` stamped into the bundle, or `dev` when there
  is no bundle around the binary. Nothing in the tree carries a version number, so a release is
  `git tag v0.2.0 && make app` and nothing else.
- `bario set / content / emit / get / watch / style / reload / ping / frame` talk to a running
  bar over `$TMPDIR/bario/sock`.

Config and stylesheet are watched: a save reloads both, a broken one keeps the last good
theme and shows the message as a red bubble on the bar. `killall -HUP bario` does the same.

## Outside `Sources/`

| directory | holds |
|---|---|
| `pdk/rust`, `pdk/c`, `pdk/wat` | the bytes ABI in three languages |
| `examples/weather` | the design's worked example, in Rust |
| `examples/counter.wat` | the same lifecycle with no toolchain — bario assembles `.wat` at load |
| `examples/ring.wat` | the design's worked renderer, registering and drawing a `ring` node |
| `examples/surface` | a native producer drawing into shared IOSurfaces with Metal (`swift run surface-example`) |
| `examples/emira` | emira's names guide rolled in over the app name: a source, a mode, a stylesheet, and a Rust module (or a jq filter) rendering the row |
| `schema/content.json` | the published content-tree contract |
| `Resources/Info.plist` | the app bundle's plist; `make app` stamps the version into its copy |

## Gotchas that cost time once

- **Extending a type with a property it already has.** `extension CGColor { var components: … }`
  resolves to *itself* inside its own body and recurses until the stack gives out (SIGBUS, no
  warning). Give test helpers names the framework does not use.
- **`#expect` and `CGFloat`.** swift-testing's `#expect` compares a `CGFloat` against a
  `Double` expression as two unrelated types and fails *silently* — `#expect(w == 26.0)`
  passes while `#expect(w == 6 + 20)` does not, for the same `w`. Geometry assertions go
  through the `Double` accessors at the bottom of `LayoutTests.swift`.
