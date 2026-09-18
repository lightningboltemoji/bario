# 16 — Custom renderers, and `raster`

DESIGN.md §9.2 and §9.3. A bar without an escape hatch pushes everyone with an unusual bubble
back to `exec` and a PNG, so BYO rendering is a first-class path. The `canvas` node (increment
12) was level 1; this is levels 2 and 3.

## Registering a node type

```kdl
renderer "ring" path="~/.config/bario/renderers/ring.wasm"
```

From then on any content tree from any module may use `{ "ring": { "value": 0.7 } }`, and the
decoder has already been keeping unknown node types as `.custom(type, payload)` since
increment 01 for exactly this reason.

## `draw`, which is also `measure`

```
draw(ptr, len) -> i64
```

in: `{ "type": "ring", "node": <payload>, "frame": {x, y, width, height}, "measure": bool,
       "style": {…} }`
out: `{ "ops": [...] }`, or `{ "width": …, "height": … }` when measuring, or
     `{ "raster": {…} }`

Two stages call it. Layout calls it with `measure: true` and the bar's content height, to learn
the natural width. Commit calls it for the drawing, with a node-local frame — `x` and `y` are 0,
`width` and `height` the node's size (PLAN.md D8) — and keeps what it returns per node
(`Compositor.Drawing`), keyed by the payload, the node's raster rows, its size and the scale.
Commit calls `draw` again only when that key changes or the renderer asked for a frame, so a
bubble sliding past or the hole moving over it asks nothing of the renderer. *(Until
[18-compositor.md](18-compositor.md) step 3a, the drawing call happened during layout, with the
node's frame in bar coordinates, and its result rode on the `SceneNode`.)*

## Theming reaches it

`style` is the node's own resolved style, which is what makes a renderer bario never wrote
themeable by `#ring { --ring-width: 3pt; color: accent }`:

```json
{ "color": "#ff3b30ff", "fill": "…", "track": "…", "opacity": 1,
  "font": { "family": "system", "size": 12, "weight": 500 },
  "stroke-width": 2, "line-cap": "round", "icon-size": 12,
  "custom": { "--ring-width": "3pt" } }
```

Colours arrive resolved, as `#rrggbbaa`, so a renderer needs no colour engine. Custom
properties arrive as their source text, so `var(--ring-width)` is readable as a number. And
because the returned ops go through the same painter as a `canvas` node, `currentColor` and
`var()` *inside* them resolve against that same style too.

## Synchronous, and honest about budgets

Renderers are called from layout and commit, which are synchronous, so a renderer is a locked instance
rather than an actor. The budget is therefore measured rather than enforced: each call is
timed, and a renderer that overruns three times is dropped and every node it drew wears
`.stale`. WasmKit cannot interrupt a call (§13), so this is the same trade the module budget
makes, stated plainly.

Renderers get the same twelve host imports modules get, with their own subtree of the store
under `renderer.<type>` — so a module compiled with a PDK links whichever tier it is loaded
into, and "renderers are ordinary modules with ordinary permissions" is true rather than
approximately true.

## `request_frame`

Nothing redraws by itself. A renderer that wants motion calls `request_frame()` while it draws;
`RendererHost.draw` returns whether that call asked, the node's drawing remembers it, and the
commit reports it. The frame loop marks that bar commit-dirty and asks for the next frame from
the display link — which commits the bar again, without laying it out, and calls that node's
`draw` again under the same budget. Its neighbours are not drawn. A request made while
measuring asks for nothing.

## `raster`

The expensive one, and opt-in (§9.3). A `raster` node, or a `draw` that returns one, names
pixels in one of four ways:

| source | meaning |
|---|---|
| `{"png": "<base64>"}` | inline bytes, for anything small and infrequent |
| `{"path": "…"}` | an image file |
| `{"shm": "/name", "width": …, "height": …}` | a shared-memory buffer, `shm_open`ed and reused frame to frame |
| `{"ptr": …, "len": …}` | premultiplied BGRA in the renderer's own WASM memory |
| `{"surface": "name"}` | a pair of IOSurfaces a native process handed over, shown as the layer's contents with no copy ([18-compositor.md](18-compositor.md)) |

The host says the size in points and the scale; the module returns premultiplied BGRA at that
size. Decoded images are cached by source, so a `path` or `png` that has not changed costs
nothing on the second frame; a `shm` or `ptr` source is read every time, which is what makes
it the expensive one.

## Hit testing and the hole

Neither needed anything new: a custom node's rect is its `SceneNode.frame`, which the existing
hit test already walks, and its layer sits under the bar's mask like every other, so the hole
cuts through it like any other bubble.

## Tests

A renderer written in WAT (no toolchain) registered as `ring`: it measures, it draws, its ops
reach the painter, and its colours resolve from the node's style. A renderer that overruns is
dropped and its nodes go `.stale`. A raster from inline PNG, from a file and from WASM memory
lands as pixels at the right place. An unregistered node type still takes no space and does
not break the bar.
