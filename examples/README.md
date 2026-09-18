# Examples

Everything here runs as-is: bario assembles a `.wat` file at load, so nothing in this
directory needs a toolchain installed. The Rust versions in `../pdk/rust` are what you would
actually write; these are the same contracts with the sugar taken off.

| file | what it shows |
|---|---|
| `counter.wat` | the whole module lifecycle: `init`, `poll`, `set_timer`, `render` |
| `ring.wat` | a renderer module that registers a node type, measures it, and draws it |
| `weather/` | the design's worked example, in Rust: `http`, permissions, state, render |
| `surface/` | a native process drawing into shared IOSurfaces with Metal, shown with no copy |

## counter.wat

```kdl
item "ticks" module="wasm" path="~/.config/bario/modules/counter.wat" interval="1s"
```

Counts its own polls, writes the count into the state store (`bario get ticks`), asks to be
polled again a second later with `set_timer`, and renders a timer icon beside the number.

## ring.wat

```kdl
renderer "ring" path="~/.config/bario/renderers/ring.wat"
```

From then on any module's content tree may say `{"ring": {"value": 0.7}}`, including from a
shell script:

```sh
bario content cpu '{"ring": {"value": 0.7}}'
```

and it is themed entirely from the outside, by a stylesheet the renderer knows nothing about:

```css
#cpu ring  { color: system(systemGreenColor); stroke-width: 3pt; }
:root      { --track: rgba(255, 255, 255, 0.22); }
```

`draw` is called by two stages: layout calls it with `"measure": true` for the natural width,
and commit calls it for the drawing, with the node's size in a frame at 0, 0. Commit calls it
again only when the payload, the node's style or its size changes, or when the renderer called
`request_frame()` while it drew; otherwise its last drawing stays on screen, however much moves
around it. The colours it names (`currentColor`, `var(--track)`) are resolved against that
node's own style when the host rasterizes them.

## weather

```sh
rustup target add wasm32-unknown-unknown
cd weather && ./build.sh
```

```kdl
item "weather" module="wasm" path="~/.config/bario/modules/weather.wasm" interval="10m" {
  permissions "net"
  config city="Vancouver" units="metric"
}
```

Fetches through the gated `http` import and writes what it found into the store; `render`
reads the store, so a failed fetch still shows the last good reading, marked `.stale`. It
never touches the filesystem, a socket or a process — `permissions "net"` is all it asks for
and all it gets.

## surface

```kdl
item "wave" module="data" {
  content {
    raster width=80 height=20 {
      source surface="wave"
    }
  }
}
```

```sh
swift run surface-example wave 30
```

The item's content is in the config, so it survives a restart. (`bario content wave` with the
same tree as JSON does the same thing for an item that has none, until bario restarts.)

A Swift program, built from this package, that hands a running bar two IOSurfaces under the
name `wave` and then draws a moving wave into them with Metal for thirty seconds. Each frame it
draws into the surface that is not showing and sends `frame` over the socket; bario makes that
surface the node's layer contents, so nothing is copied and nothing on the bar is drawn. When it
exits, its surfaces go with it.

`SurfaceProducer` in BarioKit is the whole producing side: `next` is the surface to draw into,
`present()` says it is drawn. A producer in another language sends the same Mach message
(`bario_surfaces_hand_off` in `Sources/CBarioShim` is the reference) and the same `frame` line.
