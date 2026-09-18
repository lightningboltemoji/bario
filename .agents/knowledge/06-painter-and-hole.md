# 06 — The painter, the hole, and `bario --run`

The increment that makes phase 1 real: bubbles on the photographed backdrop, with the hole
cutting through them. DESIGN.md §8 and §10.

> **Superseded by [18-compositor.md](18-compositor.md)** for everything about how pixels reach
> the screen: the painter, the `destinationOut` hole and `BarView.draw` are gone, replaced by a
> layer tree per bar and the hole as its mask. What is still true here: `contrast: auto`, the
> backdrop cache, colour resolution, rounded rects, and `--shot`, which now renders with
> `CARenderer`.

## Keep the probe's pipeline

One layer-backed `NSView` per display, drawn with CoreGraphics and CoreText in `draw(_:)`,
with the hole as the final `destinationOut` pass inside a transparency layer. The probe
already proves the hole composites over *whatever* was painted before it, and that is the
whole trick — a `CALayer` tree would need an inverted mask to do the same.

Painting order:

```
setAlpha(1 - reveal)
beginTransparencyLayer
    backdrop strip                       the photograph
    items, in tree order                 bubbles are part of the cover
    destinationOut circle                the lens, through everything
endTransparencyLayer
```

The first version let an item opt out with `hole: keep` (painted after the cut) or `hole: dodge`
(faded near the hole). Both are gone: the bar only reacts to the pointer while Option is held,
and then the hole is closed ([15-interaction.md](15-interaction.md)).

## `Paint/`

| file | holds |
|---|---|
| `ColorResolver.swift` | `Color` → `RGBA`: `system(…)` through `NSColor` in the current appearance, `accent`, `currentColor`, and `mix` blended after both ends resolve |
| `RoundedRect.swift` | a per-corner rounded path, because `border-radius: 8pt 0 0 8pt` is in the design's own stylesheet |
| `Painter.swift` | the scene painter: backgrounds, borders, shadows, text, icons, meters, graphs |
| `Backdrop.swift` | the captured strip plus its blurred/saturated variants, cached per capture rather than per frame |

Text is `CTLine` drawn at a baseline centred on the node's box. Icons are
`NSImage(systemSymbolName:)` at the resolved size and weight: monochrome tints by clipping to
the image's alpha and filling, the other rendering modes hand the job to the matching
`NSImage.SymbolConfiguration`. A meter is a rounded track with a rounded fill; a graph is a
polyline stroked with `fill`, `stroke-width` and `line-cap`.

`contrast: auto` samples the backdrop under the item — mean luminance over the strip's pixels
in that rect, cached per capture — and picks light or dark text. This is the §13 open
question, answered in phase 1 as the design asks, because an invisible bar with bare text is
the look most people will want first.

## `App/`

| file | holds |
|---|---|
| `BarView.swift` | the `NSView`: holds the last `Presentation` a frame gave it; `draw(_:)` paints it whole |
| `BarCover.swift` | one window per display, the probe's window exactly: borderless, above status items, all spaces |
| `BarController.swift` | the app delegate: turns AppKit, the socket and the watcher into frame-loop inputs |

*Superseded by [17-frame-loop.md](17-frame-loop.md).* The first version drove painting from
each input directly — a state change rebuilt the scene, a pointer move repainted the hole, a
capture repainted the strip — with a display link started by whichever path was animating.
Every input now only invalidates, and the frame loop decides what to redo.

## `bario --run`, and a way to see the bar without a screen

`bario --run` is the daemon. `bario --shot out.png` renders one bar offscreen to a PNG at a
given width and height, with an optional backdrop image, and exits. That is not a toy: it is
how the layout and the painter get verified in a session with no way to look at a menu bar,
and it makes a visual regression a diff of two files.

`--config` and `--style` point at files; `--dark` forces the dark cascade; `--diagnose`
prints the resolved scene as text (items, frames, styles) which is the fastest way to answer
"why is that bubble there".

## Tests

The painter is exercised through `--shot` into a bitmap: a known config and stylesheet
produce a PNG whose pixels are asserted at chosen points (a bubble's background colour, the
gap between bubbles being transparent, the hole being transparent, a `keep` item still opaque
inside the hole). Colour resolution, the rounded-rect path and the contrast sampler are unit
tested directly.
