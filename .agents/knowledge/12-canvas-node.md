# 12 — The `canvas` node

DESIGN.md §9.1, the first and cheapest of the three escape hatches. A render result may carry
a `canvas` node holding a vector display list, which the host paints with CoreGraphics — so
it is resolution independent and Retina is free.

```json
{ "canvas": { "width": 28, "ops": [
    { "stroke": { "color": "var(--track)", "width": 3 },
      "path": [["arc", 14, 12, 9, 0, 360]] },
    { "stroke": { "color": "currentColor", "width": 3, "cap": "round" },
      "path": [["arc", 14, 12, 9, -90, 162]] },
    { "text": "70", "at": [14, 12], "align": "center", "font": "9pt monospace" }
] } }
```

Because a display list is data, it moves through every channel the content tree already uses:
JSON over the socket, JSON bytes through WASM memory, a Swift value from a built-in. It is
cached like every other render, so it costs nothing while idle.

## The op set

| op | shape |
|---|---|
| `fill` | `{ "fill": <paint>, "path": [...] }` |
| `stroke` | `{ "stroke": <paint>, "path": [...] }` — paint may add `width`, `cap`, `join`, `dash` |
| `text` | `{ "text": "70", "at": [x, y], "align": "start\|center\|end", "valign": "top\|middle\|bottom\|baseline", "font": "9pt monospace", "color": … }` |
| `image` | `{ "image": "gear" \| {"file": …}, "rect": [x, y, w, h] }` or `at` + `size` |
| `clip` | `{ "clip": [...] }` — a path, for the rest of the group |
| `transform` | `{ "transform": [a,b,c,d,tx,ty] }` or `{ "translate": …, "rotate": deg, "scale": … }` |
| `opacity` | `{ "opacity": 0.5 }` — for the rest of the group |
| `group` | `{ "group": [ops…] }` — saved and restored state around nested ops |

Path commands are arrays: `["move", x, y]`, `["line", x, y]`,
`["curve", c1x, c1y, c2x, c2y, x, y]`, `["quad", cx, cy, x, y]`, `["arc", cx, cy, r, from, to]`,
`["rect", x, y, w, h]`, `["round-rect", x, y, w, h, r]`, `["close"]`.

Coordinates are points, **origin top-left** of the node's frame, as the design says, which is
not the coordinate system the painter draws in. The canvas painter flips the CTM once and
counter-flips the text matrix, so geometry reads top-down and glyphs still come out upright.
Arc angles are degrees with 0 at three o'clock, increasing clockwise on screen, which is what
makes the design's `-90 → 162` mean "70% of a ring, starting at the top".

## Theming reaches it

This is what makes a display list feel native rather than pasted on (§9, "what makes them feel
native"). Every colour in an op is a CSS colour *string*, resolved against the node's own
resolved style: `currentColor` is that node's `color`, `var(--track)` is whatever cascaded to
it, `accent` is the user's accent, `system(labelColor)` follows the appearance. Fonts are the
CSS `font` shorthand over the node's font as a base, so `"9pt monospace"` and plain
`"semibold"` both work.

So a ring drawn by a script is themed by `#ring { --ring-width: 3pt; color: accent }`, without
the script knowing anything about it.

## Parsed once, not per frame

`DisplayList.parse` runs when the scene is built and the parsed form is carried on the
`SceneNode`, because layout runs only when something invalidates it while painting happens
on every hole movement. A malformed op is dropped with a warning naming the
op index — one bad op does not lose the whole drawing, and never takes the bar down.

## Tests

The design document's ring example parses op for op. Every op and every path command round
trips from JSON to geometry. Colour strings resolve through `currentColor`, `var()` and
`accent`. Then pixels: a filled rect lands where the top-left coordinate system says it
should, a `currentColor` stroke comes out the item's text colour, and text drawn upside-down
would be caught by comparing the ink above and below the anchor.
