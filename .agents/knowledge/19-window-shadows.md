# 19 — Window shadows

DESIGN.md §7. The bar covers a strip the system draws as **transparent**, and paints a
photograph of the desktop there instead. Everything the window server puts into that strip from
below is therefore erased, and the common case is a window shadow: with a window near the top of
the screen, the real shadow darkens the gap below the bar, stops dead at the bar's bottom edge,
and the bar carries on showing clean wallpaper. That step is the seam.

## Why it has to be cast rather than captured

Two walls, and the second is the one that decides the design.

**Z-order.** A window's shadow is composited with the window, at the window's level. The cover
sits at `statusWindow + 1` because it has to cover the menu bar (24) and status items (25).
Nothing lifts a level-0 shadow above level 26, and no API offers to.

**The photograph can never hold it.** ScreenCaptureKit renders **no window shadows at all** in a
display filter. Measured against the real screen, not assumed: bario's own strip, captured with
`--no-window-shadows`, is byte-identical with a window 0pt below the bar and with it 40pt away,
and identical again to the strip with no window near the top at all. `capturesShadowsOnly` and
`ignoreShadowsDisplay` change nothing. So moving the backdrop to a live `SCStream` — the obvious
"just show what is really there" fix — would not help at all.

That invariance is also what makes the shadow measurable in place: the photograph *is* the
"without" image, so dividing the real screen by bario's own strip leaves the shadow and nothing
else, at the exact place and size it has to be right.

## The shadow, measured

`Capture/Shadows.swift`.

| | opacity | σ | drop | reaches up |
|---|---|---|---|---|
| focused | 0.693 | 19.46 | 17.31 | 41pt |
| unfocused | 0.436 | 7.57 | 6.23 | 16pt |

**One Gaussian, not two.** A single blurred, dropped silhouette fits to rms 0.0013 over 395
samples. Given room for a second lobe an optimiser spends it on a σ 0.3 sliver at the very edge,
which is the window's own antialiasing rather than any part of its shadow, and which would cost
a whole extra layer per window to draw.

**Fitted to two profiles at once**, and that is what makes it well posed. Above a window's top
edge the shadow has fallen by `drop` before it was blurred, so that profile alone cannot tell a
wide shadow that dropped far from a narrow one that did not. Beside the edge the drop plays no
part and σ stands on its own. One shadow has to satisfy both or it is the wrong shape — however
well it happens to match the profile that lands in the bar.

**There are two shadows**, because macOS draws two, and the key window's is not a tweak apart:
σ 19.5 against σ 7.6, reaching 41pt where the other stops at 16. Which window is focused changes
the strip more than a window moving does.

### Measure shadows over a light background

This replaced a two-lobe fit, and the reason it was wrong is the most reusable thing here.

That fit was measured over a **dark** wallpaper, and a shadow's tail cannot survive one: over a
0.05 background an alpha of 0.09 moves the pixel by a single level, so the tail reads as zero.
The fit then chased a decay far too fast — it had the focused shadow finished by 14pt when it
actually carries to 40 — and needed a second, tighter lobe to put back the near-edge ink the
first had given up. On a dark desktop the result looked right. On a light one the same tail is
thirteen levels, and the bar was up to **0.047 alpha too light** through the middle of the
strip, which is the seam.

So: a dark background is not a neutral place to measure alpha, it is a place where alpha goes
missing. `ShadowTests` records the samples over a 0.85–0.91 background and says so, and a sample
there reading 0.000 is a real zero.

**Divided in encoded sRGB, not in linear light** — checked, not assumed. The same shadow was
recovered over backgrounds from 0.45 to 0.99: the encoded alpha held at 0.0436…0.0441 while the
linearised one drifted from 0.0907 to 0.0973. Encoded is the space that stays put, so it is the
space `shadowOpacity` means, and a model fitted there does not care what the wallpaper is.

### How it was measured

The rig is worth keeping, because the obvious staged version is wrong. A full-screen opaque
window of a known colour makes macOS switch the menu bar out of its transparent appearance, so
anything measured near the top of the screen is measured on a different desktop than the one
bario lives on. Instead:

- a real window (Safari) moved with Accessibility to a known place, at several distances;
- `screencapture` of the real screen, and of the same screen with bario running
  `--no-window-shadows` — the photograph, which never sees the window;
- divide, in the space the PNG stores, without converting out of the display's colour space;
- average each row across a span of x over flat wallpaper, which kills dither and sensor noise.

Two traps that cost real time: `screencapture` runs on the *terminal's* screen-recording grant,
so a helper that spawns it silently writes nothing; and the display going to sleep mid-run
leaves bario's backdrop captured against a half-drawn desktop, which shows up as a strip reading
0.61 where it should read 0.906. Sanity-check the "without" strip against known wallpaper before
trusting a run.

### Verified against the screen

With the window 0, 10, 20 and 40pt below the bar, bario's strip now differs from the real menu
bar by at most **0.0028** — under one 8-bit level — against 0.0471 before. `ShadowPixelTests`
holds the other half of it: what Core Animation actually draws matches the analytic sampler to
0.02, which is also what confirms `CALayer.shadowRadius` is σ and not some multiple of it.

## How it is drawn

`Compositor/ShadowPlane.swift`. One layer per caster, with a `shadowPath` and no contents — the
same way `Chrome` draws a bubble's shadow. Core Animation blurs it on the GPU, so a window being
dragged costs a `position` and a path per frame: no raster, no capture, and nothing keyed on the
backdrop invalidated.

- **The layer is sized to the shadow, not to the window.** Core Animation culls a layer whose
  *bounds* miss the clip, growing them by `shadowRadius` and the offset and no further — one σ,
  where the shadow is visible out to three. Every caster sits entirely below the bar, so on that
  estimate every one of them is culled and nothing is drawn at all. The bounds are grown by
  `3σ + |drop|`; bounds carry their origin (PLAN.md D2) so the path stays where it was.
- **The plane hangs under whatever is showing the backdrop**, as sublayers of the `Chrome` fill.
  The fill already clips to its outline and masks its bounds, so the bar's own chrome and a
  `background: backdrop` bubble both get a correctly-cut shadow with no special case.
- **A fill that is a colour or a gradient takes no shadow.** There is no desktop showing through
  it for one to fall on, and so no seam to carry across.

## `contrast: auto` reads it too

The field is analytic — `ShadowField.alpha(at:)` — not sampled back from pixels, because
`contrast: auto` runs before anything is drawn and because a field tracking a drag must not cost
a raster per frame. A Gaussian blur is separable and a rectangle is the product of two intervals,
so the blurred silhouette is exactly the product of two blurred steps, which is what Core
Animation draws, corners aside. The sampler and the layers therefore agree by construction rather
than by being tuned against each other, and `ShadowPixelTests` asserts it through the real
compositor.

`meanLuminance` is multiplied by `1 − meanAlpha` before the ink is chosen, so an item over the
dark band under a window gets the light ink the bare photograph would not have asked for. The
correction matters more than it used to: the band is now three times darker than the old model
believed.

## Where the geometry comes from, and what it costs

`Capture/WindowSurvey.swift`. Nothing announces another app's window moving — Accessibility
would, and bario needs it for nothing else — so this polls, and **the poll is the whole cost of
the feature**, so it is gated.

`CGWindowListCopyWindowInfo` needs no permission bario does not already have: geometry is public,
only a window's *title* is behind Screen Recording, and nothing here reads one. It costs about
0.8ms, near enough all of it the round trip rather than the windows.

`ShadowWatcher` samples four times a second on the housekeeping timer that already runs, which is
free. `poke()` — a mouse going down, an app coming forward, a space changing — starts it sampling
at the display's rate, and it keeps that up until the windows have held still for a third of a
second. The cost is paid while windows are moving, which is the only time a stale field shows.
This is the same shape as the backdrop's own unsettled decay in `BarController`.

**Layer 0 only.** A panel, a menu, a torn-off palette or a drag image either casts no shadow or
casts one of its own, and the list does not say which. A shadow bario invents is worse than one
it leaves out.

## Known limits

- **A window overlapping the strip** gets its shadow drawn with no window under it, because the
  photograph does not have the window either. That case is already wrong for the deeper reason,
  but it is worse than it was: the silhouette's interior is now 0.69 rather than 0.24, so what
  used to be a faint smudge is a near-black band. Culling it would pop the shadow off at the
  moment it is strongest, so the fix is probably to draw only the shadow *outside* the
  silhouette — not done.
- **The shadow is assumed not to depend on a window's size.** The profile above the edge was
  measured on a 2000×900 window and the one beside it on 1100×700, and one shape fits both, so
  any dependence is small over that range. Not tested at the extremes.
- **Anything that is not a layer-0 window casts nothing.** On a desktop running a window manager
  that draws its own decorations — emira's hoist panel, for one — the strip holds shadow bario
  does not model, and the match against the screen is correspondingly loose.
- **`--no-window-shadows`** turns the whole thing off, including the poll. It is also the
  measuring instrument: it is what makes bario's strip a clean "without".
- `bario --shot out.png --window <gap>` casts one full-width focused window that many points
  below the bar, which is the arrangement the feature exists for, so the seam can be looked at
  without a screen.

## The fast path that is not built

emira already knows, every frame, where each window is, which is focused, and what shadow it
draws — and bario has a socket. A `shadow-casters` message would be exact, would cost no polling
at all, and would let a window manager declare the decorations this survey cannot see. bario has
to be right standing alone, so the poll is the design and that would be an optimisation.
