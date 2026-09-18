# Plan: the compositor

How DESIGN.md §12.7 gets built: the layer tree of §10 replaces the painter, and renderers move
onto it (§9). DESIGN.md is the what and the why; this is the how, written in September 2026
before any of it exists. When a step starts, its knowledge note
(`.agents/knowledge/18-compositor.md`) is written from the matching part of this file.

## Where we start

A frame ends in `FrameLoop.present(_:repaint:at:)`, which builds a `Presentation` and, if
anything changed, hands it to `BarSurface.paint(_:backdrop:resolver:)`. `BarCover` passes it to
`BarView.show`, which sets `needsDisplay`, and AppKit calls `BarView.draw(_:)`: `Painter` draws
the whole bar into the view's backing store, the bar's background, every item's chrome and
content, and the hole as a `destinationOut` pass inside one transparency layer. `Offscreen.render`
runs the same `Painter` into a bitmap for `--shot` and the pixel tests.

Renderers are called from layout. `BarLayout.measureNode` measures, `BarLayout.placeNode` calls
`draw` and keeps the display list or raster on the `SceneNode`, and `request_frame` sets a flag
on `RendererHost` that the loop reads after laying a bar out, invalidating layout for that bar.

## The shape of it

```
FrameLoop.frame()
  render → style → layout → present                      unchanged
  commit   bar.compositor.commit(presentation, …)        replaces surface.paint
             └─ changes a CALayer tree hung from bar.surface.hostLayer
```

| type | file | what it is |
|---|---|---|
| `Compositor` | `Compositor/Compositor.swift` | one bar's layer tree and its `commit`; owned by `Bar` |
| `LayerID`, `LayerRecord` | `Compositor/LayerRecord.swift` | a layer's identity, and the layers and last-applied values kept for it |
| `Chrome` | `Compositor/Chrome.swift` | a `Style` as shadow, fill and border layers |
| `RasterKey`, `RasterStyle` | `Compositor/RasterKey.swift` | everything a raster depends on |
| `NodeRasterizer` | `Compositor/NodeRasterizer.swift` | draws content into an image; the content half of today's `Painter` |
| `Motion` | `Compositor/Motion.swift` | a layer's `transform`, and the animations it was given (step 3b) |
| `HoleMask` | `Compositor/HoleMask.swift` | the lens image cache, the bands and the strength layer |
| `CommitReport` | `Compositor/Compositor.swift` | what a commit did: layers made and removed, rasters and draws, time, whether a node wants a frame |
| `Offscreen` | `Paint/Offscreen.swift` | rewritten on `CARenderer` |
| `Hole` | `Frame/Presentation.swift` | today's `Painter.Hole`, moved: it is a present-stage value |
| `Stage.commit` | `Frame/FrameLoop.swift` | replaces `Stage.paint` |
| `BarSurface` | `Frame/Bar.swift` | loses `paint`; gains `hostLayer` and `presented(_:)` |

## Decisions made while planning

Numbered so the steps and tests can point at them.

**D1. `Bar` owns the compositor; a surface only hosts a layer.** Commit is a stage of the frame:
it calls renderers, reports frame requests, and is what the frame-loop tests need to observe.
So `FrameLoop.addBar` makes `Bar.compositor` with the surface's `hostLayer`, and after each
commit tells the surface `presented(_:)`, which `BarView` keeps for hit testing and
`RecordingSurface` records.

**D2. Layers work in bar coordinates.** A container layer's `bounds` is its scene rectangle,
origin included, and its `position` is that rectangle's centre. Sublayers then take scene frames
as they are, with no conversion down the tree, and a `transform` turns about the centre. Shadow
paths and shape masks are built in the same space.

**D3. The loop says whether the scene changed.** `commit` takes `sceneChanged`: whether the bar
was laid out or commit-dirty this frame, or moving at the last one, which is the
`repaint || bar.moving` the loop computes today. When it is false, commit sets the hole mask and
the reveal and nothing else, and computes no raster keys. The frame derives it; nothing reports
it.

**D4. Identity.** An item is `.item(name)`, and names are unique in a config. A node is
`.node(item, key)`, where the key is its `id` if it has one and otherwise its index path within
the item's content. A record whose role changes (a node that was text is now a meter) is
replaced rather than reconfigured. Sublayer order is set from tree order whenever the scene
changed.

**D5. Rasters overhang their frames.** Glyphs, strokes and symbols draw past a node's frame, and
today only the item clips them. A raster is drawn into the node's frame outset by 2pt for icons,
by a quarter of the font size and at least 2pt for text (italics reach further as type grows),
by half the stroke width plus 1pt for graphs, and not at all for canvases and rasters, which
are clipped to their frames already. The raster's layer is outset to match.

**D6. Coverage masks.** Text and monochrome symbols are drawn on clear into a premultiplied
RGBA bitmap, which masks a layer whose `backgroundColor` is the resolved colour. An alpha-only
bitmap is an optimisation to measure later, not the starting point: CoreText into alpha-only
contexts is less travelled.

*Settled while building:* coverage is not independent of colour. With font smoothing on, the
macOS default, CoreText draws white text about 15% heavier than black on a transparent context,
which is how the system draws light text on dark. So text coverage is drawn in black or white,
whichever side of mid-luminance the text's colour falls, and that side is in its key: a tint
that stays on its side draws nothing, and one that crosses draws the text once. Symbols are
images, with no smoothing, and are drawn once for any tint.

**D7. Chrome is up to three layers,** made only when the style needs them:

- **shadow**: `shadowPath` and the shadow properties, no contents, masked to everything outside
  the shape, so a translucent bubble does not show its own shadow through itself, as CSS draws
  an outer shadow. `shadowRadius` is half the CSS blur, fitted against CoreGraphics;
- **fill**: a background colour, a `CAGradientLayer`, or the backdrop through `contentsRect`,
  with `masksToBounds`;
- **border**: the fill layer's own border when the corners allow, otherwise a stroked shape.

One radius, on all corners or on some, is `cornerRadius` with `maskedCorners`; y runs up, so
CSS's top-left is `layerMinXMaxYCorner`. Any other radii are a `CAShapeLayer` mask from
`RoundedRect.path` and a stroked `CAShapeLayer` for the border.

**D8. A renderer's `draw` gets `x: 0, y: 0`.** Ops are node-local already (§9.1), `ring` ignores
both, and a drawing that depended on where its bubble sits would have to be drawn again on every
frame of a layout transition. This is an ABI clarification, said in `16-custom-renderers.md` and
the PDK comments.

**D9. Volatile raster sources.** `ptr` and `shm` pixels change under an unchanged descriptor.
They are read again when the bar is laid out or the node was drawn this commit, the same moments
they are read today, so the image read is part of their key, by identity: the key holds the
image, so its address cannot come round again for a different one. (Planned as the bar's scene
generation; identity says the same thing without a counter.)

**D10. `backdrop blur()` and `saturate()` do not animate.** Every distinct value is a Core Image
pass and a cached image, so an eased blur fills the cache a frame at a time. `Background.blend`
snaps them at the midpoint, as it already does for backgrounds of different kinds.

**D11. Hit testing ignores `transform`.** It is visual, like `animation`, and a node's rect is
the scene's (§9). Revisit if someone uses `transform` to move a bubble for real.

**D12. An `animation` is added once.** It is replaced only when its definition changes, so no
commit restarts a spinner. While it runs it wins over a `transition` of the same property, as in
CSS.

**D13. Offscreen renders in sRGB, at a scale and a time it is given.** `CARenderer` gets
`kCARendererColorSpace` sRGB, so the pixel tests keep comparing literal colours; the scale is the
root's `sublayerTransform`; `beginFrame(atTime:)` uses the time passed in, and animations added
offscreen begin at it, so a shot shows every `animation` at its start. The texture is cleared
before each render.

**D14. The old painter is the oracle until step 2 is done.** It moves to `Paint/Legacy/`
untouched, and a parity test renders fixture themes both ways and compares. Both are deleted in
the change that finishes step 2.

**D15. Rasters sit on the pixel grid.** A raster drawn at a fractional position is resampled by
the compositor and its glyphs blur, which parity at scale 1 showed at once. So a raster's image
starts on a device pixel, with the node drawn inside it at its exact position. Content that is
moving keeps the pixels it has, off the grid while it moves, so a layout transition draws
nothing; a scene at rest draws a raster again if it came to rest somewhere else on the grid.
`Presentation.isMoving` says which.

**D16. Two of the painter's habits are not kept.** It drew `raster` pixels upside down, with a
flip meant for a y-down context; row 0 of a raster is its top. And its linear gradients ran as
long as the rectangle's longer side in every direction, so a vertical gradient on a wide bubble
showed only its middle; the gradient line is CSS's, as long as the rectangle is in its direction.
Neither was in a parity fixture.

## Step 1: layers for the bar, one raster per item

The goal: a pointer move draws nothing. Content stays coarse.

```
host layer (the surface's)
└─ root           bounds = scene.bounds; opacity = 1 − reveal; mask = the hole, nil when not visible
   ├─ bar chrome  the bar's background (D7); hidden while there is no backdrop, as today
   └─ item        bounds = item.frame (D2); opacity, as a group
      ├─ chrome   (D7), in margin.inset(frame)
      ├─ content  masksToBounds, rounded like the fill
      │  └─ raster   the item's whole content subtree as one image, at the display's scale
      └─ item     a group's children
```

Work, in order:

1. `Frame/Presentation.swift`: `Painter.Hole` becomes `Hole`. Mechanical; the tests follow.
2. `Paint/Legacy/`: `Painter.swift` and today's `Offscreen.swift`, moved unchanged (D14).
3. `Compositor/HoleMask.swift`: the lens image per radius, feather and scale, cached;
   `update(_ hole:, in bounds:)` places the lens, four bands and the strength in one pass, as the
   spike did.
4. `Compositor/Chrome.swift`: a `Style`, the resolver and the backdrop become the layers of D7.
   A property is set only when it differs from the record's last value, so a commit in which one
   thing moved sends one thing.
5. `Compositor/NodeRasterizer.swift`: today's `Painter.paint(_ node:…)` and its helpers (text,
   icon, meter, graph, canvas, raster, node backgrounds, `contrasted`), extracted to draw a
   subtree into a context whose origin is a given rectangle, with the drawing appearance set.
6. `Compositor/RasterKey.swift`, per item for now: the subtree's kinds and payloads, node frames
   relative to the content's origin, each node's `RasterStyle`, the display's scale and the
   appearance; the backdrop's generation if any node has a backdrop background; pixels read at
   layout by identity (D9).
7. `Compositor/Compositor.swift`: `commit(_ presentation:, inputs:, sceneChanged:) -> CommitReport`.
   One `CATransaction` with actions disabled: reconcile records by `LayerID` (D4); for each item,
   apply chrome, place the content, compare its key and draw it if the key changed; set the hole
   and the reveal.
8. `Frame/Bar.swift`: `BarSurface` is `frame`, `hostLayer`, `presented(_:)`, `setVisible` and
   `setTakesPointer`. `Bar` gains `compositor` and the last `CommitReport`.
9. `Frame/FrameLoop.swift`: `Stage.paint` becomes `.commit` and `Dirty.paint` becomes
   `Dirty.commit`. `present` commits, then tells the surface. A new backdrop and the first-frame
   deadline invalidate `.commit`. The trace line carries the `CommitReport`.
10. `App/BarView.swift`: layer-hosting (`layer = CALayer()` before `wantsLayer = true`), no
    `draw(_:)`, and a root delegate that returns `NSNull` for every action. `show` becomes
    `presented`. `--debug-tint` becomes a tinted sublayer.
11. `App/BarCover.swift`: `hostLayer` is the view's layer, resized in `fit(to:)`.
12. `Paint/Offscreen.swift`: new, on `CARenderer` (D13):
    `render(_ scene:, backdrop:, resolver:, hole:, reveal:, scale:, at:) -> CGImage?`, so each pixel
    test changes one line. `pixel(_:atPoint:size:)` stays.
13. `App/Shot.swift`: uses the new `Offscreen`.

`RasterStyle` is DESIGN §10's "raster rows" as a `Hashable` value: font, letter spacing, text
transform; icon size, weight, rendering and resolved colour; the resolved colour, fill and
track; stroke width and line cap; custom properties, for `var()` in ops; and the node's own
background. Not opacity, not transitions, not the box.

Tests:

- **`CompositorTests`**, new, on detached layer trees:
  - reconciliation keeps an item's layers across a re-render and across a transition, adds and
    removes by identity, and reorders;
  - a pointer move rasterizes nothing, and a hole-only commit changes only the mask;
  - changing text, font, scale or appearance draws the item again; an opacity transition does not;
  - the hole mask at both ends of the bar;
  - `8pt 0 0 8pt` uses `maskedCorners`, `8pt 4pt` a shape mask.
- **Pixel tests** (`PaintTests`, `CanvasPaintTests`, `RendererTests.painted`,
  `RasterTests.inAScene`) move to the new `Offscreen` with their assertions unchanged. New ones:
  - a two-tone backdrop, which pins `contentsRect`'s orientation;
  - a gradient, which pins its direction;
  - the hole's feather and half strength;
  - content clipped to a rounded bubble.
- **`ParityTests`** (D14): the design document's example theme, the built-in theme, and one
  fixture each for every background kind, shadows, and per-corner radii, rendered both ways on
  the checkerboard. Per-pixel difference under a tolerance; on failure, both renders and their
  difference are written as PNGs.
- **`FrameTests`**: `paints` becomes `presentations` and `.paint` becomes `.commit`. New: a
  pointer move commits the bar and its `CommitReport` shows no rasters.

Done when the tests pass, `bario --run --trace-frames` shows no rasters while the pointer moves,
and the live profile from DESIGN §10, repeated on a release build while whipping the pointer
over the bar, has no `Painter` or `CUINamedVectorGlyph` frames and no main-thread wait in
`CABackingStoreGetFrontTexture`.

## Step 2: a layer per node

The goal: a colour transition, a clock tick or a hover draws only what changed, and usually
nothing.

```
content
└─ node          bounds = node.frame (D2); opacity; the node's own background (D7, no shadow
   │             or border, as today)
   ├─ raster     a leaf's image, outset (D5); for text and monochrome symbols, a colour layer
   │             masked by a coverage raster (D6)
   ├─ track, fill   a meter: two layers, and the value is the fill's width
   └─ node       a row's or column's children
```

Work:

1. `RasterKey` per node. A coverage leaf's key has no colour in it; a full-colour leaf's
   (non-monochrome symbols, graphs, canvases, renderer drawings, rasters) keeps its resolved
   colours.
2. `NodeRasterizer` draws one leaf. Node backgrounds leave it for chrome layers.
3. Meters as layers: the track rounded by half its shorter side with `masksToBounds`, and the
   fill inside it at `max(height, width × value)` wide, as `Painter.paintMeter` draws it.
4. `contrast` becomes the tint of every coverage leaf in its item.
5. With parity holding, delete `Paint/Legacy/`, `ParityTests`, and whatever of `Painter.swift`
   step 1 did not move.

Tests:

- a colour transition on text and an `icon-color` change on a monochrome symbol rasterize
  nothing, and a `contrast: auto` flip draws only the text whose ink changed side (D6); a node
  that changes role gets a new layer; a clock tick draws one node; a meter's value change
  draws nothing; a hierarchical symbol's colour change draws that symbol;
- pixels: text takes its tint; meters at 0, 0.5 and 1; a hierarchical symbol keeps its colours;
- the step 1 pixel tests, unchanged.

Done when the tests pass and parity holds, checked in the change that deletes the oracle.

## Step 3a: renderers draw at commit

The goal: an animated renderer costs its own `draw` and one raster a frame, and nothing else on
the bar.

Work:

1. `Layout/BarLayout.swift`: `placeNode` stops calling `draw`; `measureNode` still measures.
   `canvas` and `raster` nodes keep their display list and image on the `SceneNode`; custom nodes
   get theirs at commit.
2. `Wasm/RendererHost.swift`: `draw` returns the drawing and whether that call asked for a frame.
   The shared `frameRequested` flag and `takeFrameRequest` go. `frame` is sent as `x: 0, y: 0`
   (D8).
3. `Compositor`: a custom node's draw key is its payload, `RasterStyle`, size and scale. Commit
   calls `draw` when the key changed or the node asked for a frame at the last commit, and the
   drawing joins the node's raster key. `CommitReport.wantsFrame` is set if any node asked.
4. `FrameLoop`: `styleAndLayout` stops reading frame requests. A commit that wants a frame marks
   its bar `.commit`-dirty, not `.layout`, and the frame asks for a refresh.
5. Budgets are as they were: timed per call, three strikes.

Tests:

- `FrameTests.requestFrame`: the blink renderer gets exactly the frames it asks for, and after
  the first none of them lays the bar out;
- `RendererTests`: registration, the value reaching the ops, and theming read the drawing from
  the compositor's record rather than `SceneNode.displayList`;
- a renderer redrawing on one item leaves its neighbour's raster count at 0.

Done when the tests pass, and `16-custom-renderers.md`, the Rust and C PDK comments and
`examples/README.md` say `draw` happens at commit with a node-local frame.

## Step 3b: `transform` and `animation`

The goal: a spinner costs nothing per frame.

Work:

1. `Style/Properties.swift`: `Transform` (translation, rotation in degrees, scale), parsed from
   `translate()`, `rotate()` and `scale()` in any order. `StyleProperty.transform` and
   `.animation`. `transform` joins `animatable`, with `blend`, `differs` and `take` cases.
2. `Style/CSS.swift`: `@keyframes name { from {…} 40% {…} to {…} }`, whose declarations may only
   be `transform` and `opacity`; anything else is an error that says so. `Stylesheet.keyframes`
   by name, and in `appending` the later sheet wins. The unknown at-rule error names both
   at-rules.
3. `animation: name duration [easing] [delay] [count | infinite] [alternate]`, comma-separated.
   `Styler` resolves the names against the stylesheet into `Style.animations`, keyframes
   embedded, so the compositor never needs the stylesheet. An unknown name is a diagnostic.
4. `Compositor`: `transform` is the layer's `CATransform3D`, about its centre (D2). An
   `Animation` is a `CAKeyframeAnimation` per component key path (`transform.rotation.z`,
   `transform.scale.x`, `transform.translation.y`, `opacity`), because interpolating whole
   matrices turns a 360° spin into no spin at all. `repeatCount`, `autoreverses`, a
   `CAMediaTimingFunction` from the easing; keyed `bario.<name>.<path>` and added only when that
   key is missing or its definition changed (D12).
5. `Animator`: nothing. An `animation` never makes a bar `moving`, so it starts no frames.

Tests:

- `StyleTests`: `@keyframes` and `animation` parse; other properties in keyframes and unknown
  names are errors; `transform` parses and blends;
- `CompositorTests`: a layer carries its animation after a commit, the same animation object
  after ten more, and a new one when the duration changes; the frame loop stays idle with a
  spinner on the bar;
- pixels: rendered offscreen a quarter of the way into `rotate(360deg)`, the drawing has turned a
  quarter (D13).

Done when the tests pass and DESIGN §7's property table and `03-style-engine.md` match the
grammar as built.

## Step 3c: shared surfaces

Gated on a spike, because two things DESIGN §9 relies on are not known yet.

The spike:

1. **Can a double-clickable bario vend a Mach service?** A LaunchAgent in the bundle with a
   `MachServices` entry, registered through `SMAppService`, needs bario itself to be the job
   launchd starts. Find out whether that can keep "open the app, quit the app" working.
2. **What can a layer show without private API?** Whether `contents` takes an `IOSurface`, and
   whether new pixels in the same surface reach the screen when it is set again, or it takes a
   pair of surfaces swapped each frame, with `frame` naming the one just drawn.

If the first has no answer that keeps bario an ordinary app, 3c is deferred, DESIGN §9 and §13
say so, and `shm` stays the path for external processes.

If it passes:

1. `IPC/Protocol.swift`: the `frame` verb with a `surface` field, and `bario frame <name>`.
2. An XPC listener that takes a name and its surfaces from a native process: one owner per name,
   and the surfaces are dropped when the connection goes.
3. `Paint/Raster.swift`: a `{"surface": "name"}` source resolving to the surface `frame` named
   last; the compositor sets it as the layer's contents, and its key is which surface is current.
4. An example in `examples/`: a small Swift program that draws with Metal and sends `frame`.

Tests: the verb round-trips; a source naming an unknown surface draws nothing and warns once;
surfaces handed over in-process change a layer's contents on `frame`, with no raster.

Done when the example runs against a live bar, and the README no longer calls a live raster the
expensive path.

### The spike, run in September 2026

1. **No.** `NSXPCListener` and `xpc_connection_create_mach_service` listen only on a name launchd
   gave the process. The supported way to get one is a LaunchAgent in the bundle with
   `MachServices`, registered through `SMAppService`, with bario as the job (so opening the app
   is no longer what runs it, and quitting it is undone by the next client that connects) or a
   helper as the job, brokering surfaces to an ordinary bario. Either is listed in Login Items
   and changes how bario installs. `bootstrap_register` does still work: a plain process
   registered a name, an unrelated process looked it up, and it went when the first exited. It
   has been deprecated since macOS 10.5, and XPC cannot listen on it, so it would mean
   hand-written Mach messages and dead-name notifications, which is what was built (below).
2. **A pair.** `CALayer.h` documents `contents` as taking an `IOSurfaceRef`. Measured on screen,
   with a `ScreenCaptureKit` stream (which delivers a frame only when the window server
   recomposites): new pixels in the surface a layer shows produce no frame, and neither does
   setting that surface as `contents` again; setting the other surface of a pair produces one
   every time. A screenshot is not evidence here, because it re-reads the surface on request.

The gate's question was whether there is an answer that keeps bario an ordinary app, and there
is one: `bootstrap_register`, deprecated but present. 3c was at first deferred on the grounds
that a deprecated call is no foundation for a protocol; on reflection, the protocol does not
rest on it. What producers depend on is a Mach message and the socket verb, and only the
publishing of the port uses the old call, so that is what is isolated.

### As built

- `CBarioShim/surfaces.c`: `bario_surfaces_listen` publishes a receive right with
  `bootstrap_register`; the hand-off is one complex message carrying two IOSurface ports (copy
  send), a port naming the producer (make send) and a reply port (make send-once), answered
  with accepted, taken or invalid. bario requests a dead-name notification on the producer's
  port, and its death drops every surface it handed over. `bario_surfaces_hand_off` is the
  producer's side.
- `IPC/Surfaces.swift`: `SurfaceListener` takes messages off the port on its own queue, looks
  the surfaces up there, and tells the registry on the main actor; `SurfaceProducer` makes the
  pair, hands it over, and sends `frame` over the socket. The service name is
  `zip.tanner.bario.surfaces`, or `BARIO_SURFACES`.
- `Paint/SharedSurfaces.swift`: the registry. One producer per name while it runs, a pair per
  name, `frame(name, index:)` naming the one just drawn (or swapping), and a warning once per
  name a source asks for that nothing handed over.
- `IPC/Protocol.swift` and `App/CLI.swift`: `frame` with `surface` and an optional `index`, and
  `bario frame <surface> [index]`.
- `Compositor`: a `raster` whose source is `{"surface": name}` is a `pixels` leaf whose contents
  are the current surface; `frame` invalidates commit, and nothing is laid out or drawn.
- `examples/surface`: a Swift program drawing a moving wave with Metal into the pair, run with
  `swift run surface-example`.

Tests: the verb and its errors; an unknown source shows nothing and warns once; `frame`
changes a layer's contents with no raster; a frame commits without layout; a surface is the
right way up offscreen; and the real Mach hand-off in-process, with a name taken, handed over
again by its owner, and freed when the owner's port dies. The example ran against a live bar:
about 170 frames of commit with no layout and no raster, the wave moving on screen, and the
node empty once it exited.

## Risks

| risk | how it would show | what we do |
|---|---|---|
| `contentsRect` or gradient direction is flipped relative to the painter | step 1 pixel tests | fix it once in `Chrome`; the two-tone and gradient tests pin it |
| a layer's `shadowRadius` is not CoreGraphics' blur | parity | fit the factor against the oracle and write it down beside the code |
| text clipped at descenders or italics | parity | D5; the fixtures include descenders and bold italic |
| `CARenderer` and the window server disagree | offscreen passes, screen looks wrong | step 1 is not done until each fixture theme has been looked at on a live bar |
| many small layers cost WindowServer more than one bitmap did | WindowServer CPU while whipping the pointer | compare in Activity Monitor before and after; a bar is dozens of layers, not hundreds |
| an implicit animation somewhere in a hosted tree | things slide that should snap | actions disabled in every commit and in the root delegate; a test that a commit leaves no animations but `bario.*` ones |
| layer contents are sRGB and the display is P3 | colours shift on screen | Core Animation matches tagged images; tests are sRGB (D13); compare one swatch on screen |

## Docs, as we go

- **Step 1 starts:** `.agents/knowledge/18-compositor.md` from this file.
- **Step 2 ends:** the painting parts of `06-painter-and-hole.md` and `17-frame-loop.md` are
  marked superseded; `IMPLEMENTATION.md` gains `Compositor/` and loses the painting-order
  paragraph.
- **Step 3a:** `16-custom-renderers.md`, the PDK comments, `examples/README.md`.
- **Step 3b:** DESIGN §7 and `03-style-engine.md`, if the grammar settled differently.
- **Step 3c:** README, DESIGN §9 and §13.
- **When 3b is done:** DESIGN's status line says phase 7 is built, with 3c noted if it was
  deferred.

## Not in this plan

Rasterizing off the main actor, `CAShapeLayer` for graphs and display-list paths, handing layout
transitions to Core Animation, and shaders. Each fits on top of this, and none is needed for its
goals.
