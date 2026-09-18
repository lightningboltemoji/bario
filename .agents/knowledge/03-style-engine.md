# 03 — The style language

DESIGN.md §7 is precise about what "supporting CSS" means here: CSS *syntax*, for a theming
system we write ourselves, over a fixed property list and a fixed selector grammar. No
layout properties — layout is config. Anything outside the grammar is an error with a line
number rather than something to approximate.

## Layers

```
style.css ─▶ CSSLexer ─▶ CSSParser ─▶ Stylesheet ─▶ Cascade ─▶ Style
             tokens      components    rules         match +    one struct
             + position  + selectors   + media       specificity  per node
```

`Sources/BarioKit/Style/`

| file | holds |
|---|---|
| `CSS.swift` | tokenizer, the generic component AST, the stylesheet parser |
| `Selector.swift` | selector model, parsing, specificity, matching against a node path |
| `Properties.swift` | the typed value vocabulary and its parsers |
| `Style.swift` | the resolved `Style` struct, its defaults, inheritance and interpolation |
| `Cascade.swift` | matching, sorting, `var()` resolution, computing a `Style` |
| `DefaultStyle.swift` | the built-in stylesheet, which is also the worked example |

## Values are parsed in two passes

A declaration's value is first parsed into a generic component list — numbers with units,
identifiers, strings, hash colours, functions, commas — which is what makes `var()` possible
at all: substitution happens on components, before any property-specific parser sees them.

The property-specific parser then runs. When a value contains no `var()` it also runs *at
parse time* and throws away the result, purely so that `color: rbga(0,0,0,1)` is an error on
line 12 when the file is read, not a silently dropped declaration at paint time.

## Selectors

Type (`bar`, `item`, `group`, `text`, `icon`, `meter`, `graph`, `canvas`, `raster`, and any
node type a renderer registers), `#id`, `.class`, `*`, the descendant combinator, and
selector lists. `:root` is an alias for the bar, so `--fg` defined there inherits everywhere.

Pseudo-classes: `:hover`, `:active`, `:overflow`, `:stale`, `:first-child`, `:last-child`,
`:only-child`, `:empty`. Specificity is CSS's own (ids, classes+pseudos, types), and ties
break on source order.

## Properties

Fixed list, grouped as DESIGN.md §7 groups them.

| group | properties |
|---|---|
| box | `padding` `margin` `border` `border-width` `border-color` `border-radius` `min-width` `max-width` `width` `opacity` `gap` |
| background | `background` — a colour, `linear-gradient(…)`, `none`, or `backdrop` with optional `blur(20pt)` and `saturate(1.2)` |
| text | `font` `font-family` `font-size` `font-weight` `color` `letter-spacing` `text-transform` `contrast` |
| icon | `icon-size` `icon-color` `icon-weight` `icon-rendering` |
| meter/graph | `fill` `track` `stroke-width` `line-cap` |
| effects | `shadow` `transform` `transition` `animation` |
| custom | any `--name`, kept as components and handed to renderers |

`contrast: auto | light | dark | none` is the §13 open question made concrete: `auto` asks
the painter to sample the backdrop under the item and pick light or dark text. The cascade
carries the intent; the sampling lands with the painter.

Inherited: `color`, `font-*`, `letter-spacing`, `text-transform`, `contrast`, `icon-*`,
`fill`, `track`, `stroke-width`, `line-cap`, and every custom property. Everything
else resets, as in CSS.

## Colours stay symbolic until paint

`Color` is an enum — `rgba`, `system(labelColor)`, `accent`, `currentColor`, `none` — and is
resolved to `RGBA` by the painter, not by the cascade. Two reasons: `currentColor` inside a
renderer's display list has to resolve against the style it is drawn with (§9), and keeping
resolution out of the cascade keeps the cascade pure, `Sendable` and testable off the main
actor. `@media (prefers-color-scheme: dark)` still re-cascades on an appearance change,
because it selects *rules*, not colour values.

## At-rules

Two. `@media (prefers-color-scheme: dark | light)` wraps rules and does not nest.
`@keyframes name { from { … } 40% { … } to, 100% { … } }` declares `transform` and `opacity` and
nothing else, since the compositor runs an animation with no frames from bario; any other
property is an error naming the two. Keyframes are kept as declarations, by name, and
`Stylesheet.appending` lets the later sheet's definition of a name win, so a socket `style`
delta can redefine one.

## Transform and animation

`transform: translate(4pt, -2pt) rotate(90deg) scale(1.2)` is a `Transform` of parts, not a
matrix: each part at most once, `deg` or `turn` for the angle, one or two factors for scale. The
parts always apply as scale, rotate, translate about the centre, whatever the order written,
and they ease part by part, which is what makes a full turn ease through half a turn rather
than through none.

`animation: name duration [easing] [delay] [count | infinite] [alternate]`, comma-separated,
parses to `[Animation]` with names only. The cascade then resolves each name against the
stylesheet and embeds the keyframes, with `var()` resolved against the node, so nothing after
the style stage needs the stylesheet. A name with no `@keyframes` is a cascade diagnostic and
the animation is dropped. A keyframe that leaves a property out takes the node's own value
there, as in CSS. See [18-compositor.md](18-compositor.md) for how an animation becomes Core
Animation's.

## Transitions

`transition: background 120ms ease-out, opacity 120ms` parses to a list of
`(property, duration, delay, easing)`. `Style.interpolated(from:to:t:)` covers the animatable
properties — colours, opacity, padding, margin, radius, border width, shadow, transform, icon
size, letter-spacing, gap — and everything else snaps. A backdrop's `blur()` and `saturate()`
snap at the midpoint like backgrounds of different kinds: each distinct value is a Core Image
pass and a cached image. The driver that ticks `t` lands with the
painter; this increment owns the model and the maths so both are testable without a screen.

`transition: layout 160ms ease-out` on the bar is the same list with a reserved property name
that the layout pass reads.

## Errors

`CSSError` carries line, column and the offending text, and the parser recovers at the next
`}` or `;` so one bad declaration reports one error instead of cascading nonsense. An unknown
property is an error naming the closest known one; an unknown pseudo-class lists the ones
that exist.

## Tests

The design document's example stylesheet parses and cascades to the values it implies;
specificity ordering; inheritance; `var()` including fallbacks and inherited redefinition;
`@media (prefers-color-scheme: dark)`; every property's value grammar; errors point at the
right line; interpolation is exact at the ends and monotonic in between.
