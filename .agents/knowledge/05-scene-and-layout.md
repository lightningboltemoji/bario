# 05 — Scene, flex layout, the notch, overflow

DESIGN.md §6. The bar is one horizontal flex row; `left / center / right` is not a concept,
it falls out of `[a spacer clock spacer b]`. On a notched display the row becomes two.

## The scene

The layout stage's output (§10), which the animator eases between and the painter paints.
Styles come from the style stage (`Styler` → `StyledBar`); `BarLayout` adds the rectangles.
See [17-frame-loop.md](17-frame-loop.md) for when either runs.

```
Scene
  display, frame, style (the bar's own)
  rows: [SceneRow]          one, or two with a notch between them
    items: [SceneItem]
      name, style, frame, states, tooltip
      content: SceneNode?   the rendered tree, each node with its own style and frame
      children: [SceneItem] for a group
  hidden: [SceneItem]       overflowed, kept so a catch-all item can list them later
```

Frames are in the cover view's coordinates, bottom-left origin, the same space the painter
draws in and the hit test will read.

## Measurement is injectable

`Metrics` is a protocol: `textSize`, `iconSize`, `lineHeight`. `CoreTextMetrics` is the real
one — CoreText for text, `NSImage(systemSymbolName:)` for SF Symbols at the resolved icon
size and weight, both cached by (string, font) because a clock re-measures the same six
glyphs every minute. `FixedMetrics` is a deterministic stand-in so the layout tests assert
exact numbers without a font on the machine deciding the answer.

Natural sizes:

| node | natural width | natural height |
|---|---|---|
| `text` | measured, plus letter-spacing | the font's line height |
| `icon` | the symbol's measured width at `icon-size` | `icon-size` |
| `meter` | `width` or 24pt | `stroke-width` × 2 |
| `graph` | `width` or 40pt | the font's line height |
| `row`/`column` | children plus gaps | the tallest child / the sum |
| `spacer` | 0 | 0 |
| `canvas`/`raster` | the declared width | the declared height, else content height |
| custom | 0 until a renderer measures it (increment 16) | |

An item's natural width is its content plus padding plus border, then clamped by `width`,
`min-width` and `max-width`.

## One flex pass

`Flex.solve` is pure arithmetic over `(natural, min, max, grow, shrink)` and the row's
available width — no styles, no nodes — so it is tested directly:

- free space > 0 is handed to `grow` in proportion, capped at `max-width`;
- free space < 0 is taken from `shrink` in proportion, floored at `min-width`;
- a spacer is an empty item with `grow` 1, exactly as DESIGN.md says.

## Overflow

Real on menu bars. When the natural widths do not fit, items are dropped lowest `priority`
first (ties break right-to-left, so the rightmost of equal priority goes first) until the
rest fits. A dropped item gains `.overflow`, is re-cascaded so the stylesheet can fade it,
and is kept in `Scene.hidden` — it still renders into the state store, so a `▸` catch-all
item can list them later.

## The notch

`NSScreen` gives the geometry (`auxiliaryTopLeftArea`, `auxiliaryTopRightArea`,
`safeAreaInsets.top`), snapshotted into `DisplayInfo.notch` back in increment 02. Layout
treats it as an exclusion interval and runs the flex pass twice, once per sub-row.

Which items go where:

- an explicit `notch` marker splits there — the predictable option the docs recommend;
- otherwise one flex pass is run over the whole width, and the first non-spacer that would
  end past the notch's left edge starts the right sub-row;
- if the spacer before it straddles the whole notch, it becomes a spacer on *each* side,
  which is what makes `[a spacer clock spacer b]` degrade to `clock` hugging the notch
  instead of vanishing under it.

The marker has two modes (`ItemConfig.Kind.notch(NotchMarker)`). A bare `notch` (`.always`)
splits on a plain display too, at a gap-wide stand-in centred on the screen, so each half
stays on its own side of the centre whatever its width. `notch "if-present"` splits only at a
real notch and is dropped elsewhere, which is how to pick the notch's side for an item that is
centred on a plain display. `bar { notch "ignore" }` treats the display as plain: `scene.notch`
is nil, `.always` still splits at the centre, `.ifPresent` does nothing. The bar-level policy
and the marker share a node name; the loader tells them apart by argument (`"avoid"` /
`"ignore"` versus none or `"if-present"`).

## Vertical placement

The bar's height is the display's menu bar height unless the config overrides it. Items are
placed inside the bar's padding box by `bar { align … }`: `center` (the default), `start`,
`end`, or `stretch` to fill. Inside an item, the content row aligns the same way.

## Tests

`Flex.solve` against hand-computed cases; natural sizes with `FixedMetrics`; a spacer pushes
items apart; overflow drops the right items in the right order; the notch split in all three
modes including the straddling spacer; both marker modes on a notched and a plain display,
and under `notch "ignore"`;
every frame lands inside the bar.
