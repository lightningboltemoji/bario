# 17 — The frame loop

DESIGN.md §10, rewritten around one rule: **inputs only invalidate, and a frame does all the
work.** The first implementation drew from wherever something changed — a scene rebuild on
hover, a repaint from the capture callback, a display link started by whichever path
remembered to — and every new input was a new route to the screen. This replaces all of them.

## The stages, as types

| stage | code | output |
|---|---|---|
| render | `ModuleHost.startRenders()`, async, one task per item | `ModuleHost.ItemState` |
| style | `Styler.style(bar:items:states:interaction:)` | `StyledBar` / `StyledItem` (content as unframed `SceneNode`s) |
| layout | `BarLayout.layout(_:on:)` | `Scene` |
| present | `Animator.presented(at:)`, `Lens.present(...)` | `Presentation` (scene + hole + reveal) |
| commit | `Bar.compositor.commit(presentation, inputs:, sceneChanged:)` | the bar's layer tree; see [18-compositor.md](18-compositor.md) |

`SceneBuilder` is style then layout in one call, for `--shot`, `--diagnose` and tests.

Style and layout are separate so that a layout invalidation — a display resizing, a menu bar
showing — never re-cascades. (A renderer's `request_frame()` used to be the hot case; it now
invalidates commit alone, and costs neither.) `:overflow` is the one input that crosses back: only
layout knows what did not fit, so it asks `Styler.restyle(_:adding:)` for those items.

## `Frame/`

| file | holds |
|---|---|
| `FrameLoop.swift` | `Stage`, `invalidate`, the inputs (config, stylesheet, live style, dark, banner, pointer, pressed, reveal latch), and `frame()` |
| `Bar.swift` | one bar's pipeline state, `BarSurface`, `ItemRef` |
| `FrameScheduler.swift` | the protocol, and `RunLoopScheduler`: a run-loop observer for the end of a turn, an `NSScreen` display link for refreshes |
| `Animator.swift` | target scene + per-property and per-frame tweens; sampled, never stepped |
| `Lens.swift` | pointer → hole; the click reveal and the hole closing for Option, as exponential eases in time |
| `Presentation.swift` | what commit gets: the scene, the `Hole`, the reveal, and whether the scene is moving |

`App/BarController.swift` is only glue now: AppKit notifications, monitors, timers, the
socket and the file watcher, each turned into a frame-loop input. `BarView` hosts the bar's
layer tree and never draws; `BarCover` is the window-backed `BarSurface`.

## Scheduling

- The end of a turn is a `CFRunLoopObserver` on before-waiting and exit, order 1,000,000.
  Measured on macOS 27: the only other observers on the main loop are an entry tap (order 0)
  and Core Animation's commit (order 2,000,000, same activities), and AppKit's
  `needsDisplay` is drawn inside that commit — measured, a view invalidated from an observer
  at 1,000,000 draws 0.6ms later in the same pass, with nothing else waking the loop.
- A frame that asks for another end of turn from inside the observer wakes the run loop,
  or it would sleep on it.
- Refreshes come from `NSScreen.displayLink(target:selector:)` on the fastest screen, not a
  view's link: measured, a screen link keeps ticking with no window on screen, and a bar waits
  off screen for its first frame. It is paused, not torn down, between animations.
- The loop keeps at most one frame pending. While refreshes are coming, invalidations wait for
  the next one instead of adding a frame.

## Rules that are easy to break

- **An item that has never rendered is not laid out.** `ItemState.rendered == false` means
  nothing to show; `rendered` with nil content is `:empty` and is laid out. This is what lets a
  reload or a new display never show placeholders.
- **A module's first render is held** until its first poll lands, a write lands under its key,
  or 250ms pass (`ModuleHost.firstStateDeadline`, counted from the load, not from when modules finished starting) — at startup and for every module a reload
  starts. A restarted module's instance inherits the previous result so the bubble does not
  vanish meanwhile.
- **A render that finishes with its item dirty again asks for a frame** even when its result
  did not change; otherwise a write that landed mid-render is lost until something else
  happens to cause a frame. (The test for this uses a module whose output never changes, since
  a changing result starts the next render through the style invalidation and hides the bug.)
- **A write to something a render reads for the first time** cannot dirty it — nothing
  recorded that read yet. `StateStore` stamps writes with a version and keeps the last 256;
  `recordReads(_:for:since:)` answers whether anything the render read was written after its
  snapshot, and the host renders it again if so. An abandoned render's reads are added too.
- **Modules start independently.** `load` never waits on a module's `start()` or `stop()`: a
  WASM `init` that never returns would otherwise hold up every later reload, since loads are
  serialised.
- **A bar that is not visible retargets without animation.** Its first frame is complete and
  still; a bar hidden by a full screen app does not come back mid-transition.
- **Commit only what changed.** A bar is committed if it was laid out, is commit-dirty, was
  moving at the last frame, or its hole or reveal differ; only the first three commit the scene
  (PLAN.md D3), and a hole alone sets the mask. Pointer moves far from every bar do not even
  schedule a frame. *(This rule was "repaint only what changed" while the painter drew the bar
  whole; see [18-compositor.md](18-compositor.md).)*
- **Hover is per bar** (`ItemRef`), and so is the click reveal (`revealed`). Two displays both
  showing `clock` must not hover together, and sliding onto the next display is not a click.
- **Taking the pointer is a frame output.** A bar is interactive while Option is held with the
  pointer on it; that and hover are decided from what is on screen, after pointer moves, Option
  changes *and* frames. Without Option nothing hovers and the bar takes no events.
- **A hole too far away to show does not ease closed.** It jumps; otherwise pressing Option
  anywhere (Option-arrow in a text field) would start frames on every bar.
- **What a frame invalidates itself waits for a refresh.** Hover changing under a still pointer
  is found at the end of a frame; if the stylesheet moves the item out from under it on hover,
  that flips every frame, and at end-of-turn pacing it would spin the CPU.

- **Content is clipped to its bubble.** While a bubble grows its content already has its final
  size; without the clip it paints across its neighbours for the first few frames.
- **A backdrop identical to the last is not new.** The capture of an unchanged desktop compares
  bytes, invalidates nothing and returns false, and that false is what ends the controller's
  run of captures while the desktop is changing.

## The capture filter

Every on-screen window below normal window level, `SCContentFilter(display:including:)`, built
fresh for each capture: the wallpaper and the underbelly shading, and nothing of bario's. It
replaced a filter excluding bario's covers by window ID plus everything at menu bar level, which
had to be built from off-screen windows too (covers waiting for their first frame were
otherwise photographed once shown), cached, and invalidated whenever covers came and went.

Captures are taken on events (a display appearing or changing, a space change, the appearance,
wake and unlock, WallpaperAgent's store file), then again a second later while each one finds
something new (at most ten in a row), and every `--refresh` seconds (60) for dynamic and
shuffled wallpapers. Window shadows are not tracked: measured, they reach the strip only from
windows within ~25pt of it and change it by a few levels, and tracking them was the reason for
the old once-a-second capture.

## Seeing it

`bario --run --trace-frames` prints one line per frame: what was dirty, how many bars were laid
out and committed, what each commit did (layers made and removed, rasters drawn, renderer
draws), and whether the next frame is a refresh, an end of turn, or nothing. An idle
bar prints nothing; a seconds clock prints two frames a second plus the layout transition when
its width changes.

## Tests

`FrameTests.swift` runs the loop headlessly with `ManualScheduler` (records requests, runs a
frame when told, fires `after` timers as a `TestClock` moves) and `RecordingSurface`: one frame
per turn however many invalidations; refresh frames while a transition runs and none after;
off-screen bars snap; a mid-render write renders again; ordered in only after a complete frame
on a backdrop, or at the deadline with the stand-in backdrop; pointer far costs nothing and
near commits one bar and draws nothing; identical backdrops; a WAT renderer that calls
`request_frame` gets exactly the frames it asked for without the bar being laid out, and one
drawing every frame draws nothing else; a spinner costs no frames; the reveal eases in and out. Each of the loop's
rules was checked by breaking it and watching the matching test fail.
