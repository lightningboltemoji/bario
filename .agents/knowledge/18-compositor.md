# 18 — The compositor

DESIGN.md §9 and §10, and PLAN.md, which has the steps and the numbered decisions (D1–D16)
this note refers to. The painter drew the whole bar on every frame that touched it; this
replaces it with a tree of Core Animation layers per bar, brought up to date by a last stage
of the frame, **commit**, which rasterizes only what changed.

## The shape

```
FrameLoop.frame()
  render → style → layout → present                      unchanged
  commit   bar.compositor.commit(presentation, inputs:, sceneChanged:)
             └─ changes a CALayer tree hung from bar.surface.hostLayer
```

`Bar` owns the compositor; a surface only hosts a layer (D1). `BarView` is layer-hosting and
never draws. `Offscreen` renders the same tree with `CARenderer`, so `--shot`, the pixel tests
and the screen share one renderer.

## `Compositor/`

| file | holds |
|---|---|
| `Compositor.swift` | one bar's tree, `commit`, `CommitReport` |
| `LayerRecord.swift` | `LayerID` (an item's name; a node's `id` or index path) and the layers kept per identity |
| `Chrome.swift` | a `Style` as shadow, fill and border layers |
| `RasterKey.swift` | everything a raster depends on, and `RasterStyle`, a style's raster rows |
| `NodeRasterizer.swift` | draws content into an image |
| `HoleMask.swift` | the lens image cache, the four bands and the strength layer |

## Measured before building (September 2026, macOS 27)

A throwaway program checked every orientation the plan was unsure of, with `CARenderer` into
a Metal texture:

- **`CARenderer` needs its tree attached before the transaction flushes.** A tree committed
  and then handed to a renderer renders, but its animations do not run and are dropped. So
  `Offscreen` hangs the compositor's root from the renderer's layer first, then commits.
- **Its texture's row 0 is the bottom of the layer.** `Offscreen` flips rows into the
  `CGImage`, whose row 0 is the top.
- **The renderer's queue is the one to wait on.** Pass `kCARendererMetalCommandQueue` and
  wait on a command buffer from that queue, or the texture is read before anything is drawn.
- **An explicit `beginTime` is honoured offscreen.** `beginFrame(atTime: t)` samples an
  animation whose `beginTime` is `t0` at `t − t0`; with `beginTime` 0, Core Animation fills
  in the media time of the commit.
- **`contentsRect` is y-up**, like the layer: a slice of the backdrop is the node's frame over
  the bar's size, with no flip.
- **`CAGradientLayer`'s `startPoint` y 0 is the bottom.** CSS's 180deg, top to bottom, starts
  at (0.5, 1).
- **`shadowRadius` is CSS blur ÷ 2**, fitted against CoreGraphics' `setShadow(blur:)` at
  scale 1: a 4pt blur and radius 2 differ by at most 2 of 255 along a profile. A positive
  offset moves the shadow up in both. (The painter's shadows were in device pixels, because
  CoreGraphics does not scale shadow offsets and blurs with the CTM: half size on Retina.)
- **A `mask` clips a layer's shadow**, which is how an outer shadow is kept out from under a
  translucent bubble, as CSS draws it.
- **Group opacity works in `CARenderer`** with `allowsGroupOpacity`.
- **Text coverage depends on the ink.** With font smoothing on, the macOS default, CoreText
  draws white text about 15% heavier than black on a transparent context; with it off, alpha
  is identical for every colour, and lighter than either. A coverage raster (step 2) is drawn
  with smoothing on, in black or white, whichever side of mid-luminance the text's colour
  falls: a tint within a side draws nothing, and crossing sides draws once.

## The tree, as built through step 2

```
host layer (the surface's)
└─ root              bounds = scene.bounds; opacity = 1 − reveal; mask = the hole, nil when not visible
   ├─ bar chrome     the bar's background, hidden while there is no backdrop
   └─ item           bounds = item.frame; opacity, as a group
      ├─ chrome      shadow, fill, border, in margin.inset(frame)
      ├─ content     masksToBounds, rounded like the fill
      │  └─ node     bounds = node.frame; opacity, as a group; its own background (fill only)
      │     ├─ leaf  one of the roles below
      │     └─ node  a row's or column's children
      └─ item        a group's children
```

| role (`LeafRole`) | nodes | layers | what redraws it |
|---|---|---|---|
| container | row, column | none of its own | nothing |
| coverage | text, monochrome icons | a tint (`backgroundColor`) masked by a coverage raster | text, font, letter spacing, transform, ink side; a symbol's name, size, weight |
| image | graphs, canvases, renderer drawings, other renderings of symbols | a raster | its payload and its resolved colours |
| pixels | `raster`, a renderer's raster | the image as `contents` | a new image (identity) |
| meter | meter | a rounded track with `masksToBounds`, and a fill whose width is the value | nothing |

Identity is `LayerID`: `.item(name)`, with an occurrence suffix for names that repeat
(spacers are named by position, so `spacer-2` can appear at the top level and in a group), and
`.node(item:, key:)` with the node's `id` the first time it appears in the item and its index
path otherwise. A record whose role changes is replaced.

`contrast` is resolved per item from the backdrop, as the painter did, and every node inside
takes its colour: a tint for coverage, a key input for images.

## Renderers draw at commit (step 3a)

Layout only measures. Commit keeps a `Drawing` per custom node, keyed by the renderer's type,
the payload, the node's raster rows, its size, the scale and the appearance, and calls `draw`
with a node-local frame (x and y 0) when that key changes or the last call asked for a frame.
`RendererHost.draw` returns whether the call asked; there is no shared flag to race. A commit
that wants a frame reports it, and the frame loop makes that bar commit-dirty, never
layout-dirty, so an animated renderer costs its `draw` and its node's raster and nothing else.
A request made while measuring asks for nothing.

## Transform and animation (step 3b)

`Motion` (in `Motion.swift`) is per layer, for items and nodes. `transform` is the layer's
`CATransform3D`: scale, then rotate, then translate, with CSS's y-down translation and
clockwise rotation turned into the layer's y-up space. An `animation` is one
`CAKeyframeAnimation` per component that moves (`transform.rotation.z`, `.scale.x`, `.scale.y`,
`.translation.x`, `.translation.y`, `opacity`), because a matrix eased from 0° to 360° does not
turn. Keys are `bario.<name>.<path>`.

- **Added once.** A layer's `Motion` remembers the `Animation` each key was added from, and adds
  it again only when the definition changes, or when Core Animation dropped it (a layer that
  moved to another parent) while it should still be running. A finite animation that has run
  its course is not restarted by the next commit; they are added with
  `isRemovedOnCompletion = false` so that "gone" means dropped rather than finished.
- **Begin time.** On screen, the commit's media time plus the delay. Offscreen, a fixed epoch
  (`Offscreen.epoch`), and `Offscreen.render(at:)` samples that far in: a shot shows each
  animation at its start, and a test can ask for a quarter of a turn.
- **Alternate.** A CSS alternate iteration runs one way; a Core Animation repeat that
  autoreverses runs there and back, so the repeat count is halved.
- **No frames.** An animation never makes a bar `moving`. A layer too faint to see is hidden,
  except when it animates, since the animation may be what shows it.

A layer whose style turns in depth (`rotateX`, `rotateY`, now or in a keyframe) is given
`zPosition` `Motion.lift`. Measured: siblings share one 3D space, and a box tipped out of the
bar's plane is otherwise cut where it passes behind the backdrop layer at z = 0
([21-sources-modes-arrivals.md](21-sources-modes-arrivals.md)).

## Shared surfaces (step 3c)

A native process draws with Metal into a pair of IOSurfaces and bario shows the one it drew
last as a node's layer contents: no raster, no copy. PLAN.md has the spike and the file-by-file
account; DESIGN.md §9.3 and §13 have the why.

- **A pair, measured.** New pixels in a surface a layer already shows never reach the screen,
  even with `contents` set to it again; a surface it is not showing does. So `frame` names the
  surface just drawn (or swaps), and the producer draws into the other.
- **The hand-off is Mach, and only the publishing is deprecated.** An ordinary app has no
  launchd-given name, so `bario_surfaces_listen` uses `bootstrap_register`. The message itself
  (two surface ports, a port naming the producer, a reply) and the dead-name notification are
  plain Mach. Everything in `CBarioShim/surfaces.c`; nothing else knows how surfaces arrive.
- **One producer per name, while it runs.** A dead-name notification on the producer's port
  drops its surfaces; one reference per producer is kept, and a second hand-off from a producer
  already known gives its extra reference back.
- **The listener's handler is not the main actor's.** Built inside a `@MainActor` initializer, a
  closure inherits that isolation and traps when a dispatch source runs it on its own queue;
  it is made in a `nonisolated static` function instead.
- **How the spike looked**, for whoever touches it: `layer.contents = surface` in a small
  window, then a `ScreenCaptureKit` *stream* over it, counting frames. A screenshot
  (`SCScreenshotManager`) shows new pixels in the same surface and misleads, because it re-reads
  the surface when asked; the stream gets no frame, which is what the screen does.

## Parity, as measured before the painter was deleted

The eight fixtures (the design document's theme light and dark, the built-in theme, colours,
gradients, backdrop with blur and saturate, shadows at scale 1, per-corner radii with borders)
matched with per-node layers at a mean difference under 0.01 and no fixture with more than 0.5%
of pixels off by more than a quarter. The residue, looked at rather than tuned away:

- **text**: the worst pixel 0.15 off, from coverage drawn in black or white ink and tinted
  rather than drawn in its own colour;
- **borders on large radii**: 0.24% of the corners fixture, where a layer's border follows
  `cornerRadius` inward and the painter stroked the outer path;
- **symbols at scale 1**: the compositor asks for the symbol at the context's scale, the
  painter drew a 2x one down.

The shadow fixture ran at scale 1 because the painter's shadows were not scaled with the CTM:
at scale 2 they were half size, which the compositor does not reproduce.

## Rules that are easy to break

- **Every compositor layer has a delegate that returns `NSNull` for every action**, and every
  commit is a transaction with actions disabled. The first alone would do; both, because a
  layer that animates implicitly slides where it should snap and nothing else notices.
- **A property is set only when it differs** from what the layer already holds, compared on
  the layer's model value.
- **Layers work in bar coordinates** (D2): a container's `bounds` is its scene rectangle with
  its origin, `position` its centre, so every frame from the scene is used as it is.
- **The raster key is the only thing that decides a redraw**, with one exception that is about
  where pixels sit rather than what they show: a raster that came to rest off the pixel grid is
  drawn again on it (PLAN.md D15). A stale pixel is an input missing from the key; add it
  there, never a flag set by whoever changed something.
- **Content moving is not content changing.** A layout transition moves node layers each frame;
  their frames relative to the node are unchanged, so nothing is drawn until it stops.
- **Colour is not in a coverage key**, and must not creep in through a field that happens to
  carry it (`custom`, the whole `Style`): hovering would draw every word on the bar.
