# 22 — Colours from the wallpaper

PLAN.md's "colours from the wallpaper", written step by step as each starts. The plan's decisions
are numbered W1–W16 and cited as such in the code. Three tools, each useful alone:

- **measure**: `wallpaper(vibrant)` and its siblings, colours really in each display's wallpaper;
- **generate**: `@scheme` and `scheme(primary)`, a theme generated from one seed colour;
- **adjust**: CSS Color 4 and 5, `oklch(from <colour> l c calc(h + 50))`, `color-mix()` and
  `contrast-color()`, plus bario's `on()`, a readable partner for any colour at all.

All of it is ours: Oklab is Björn Ottosson's and public domain; the slots borrow Android
Palette's idea and names and the schemes Material You's, but none of either's code, maths or
numbers, and matching their colours is a non-goal.

## Step 1: colour maths, and CSS Color 4 and 5

`Sources/BarioKit/Style/`

| file | holds |
|---|---|
| `Oklab.swift` | `Oklab`, `OKLCH`, `SRGB`'s transfer function, `WCAG` contrast, and the contrast solver behind `on()` |
| `ColorFunctions.swift` | `RelativeColor`, `ColorCalc`, `ColorMix`, and the parsers for every colour function |
| `Properties.swift` | `Color`'s four new symbolic cases: `.relative`, `.mixed`, `.contrast`, `.on` |
| `CSS.swift` | `CSSComponent.delim` (`+ - *`) and `.color` (a computed colour), and bare `( … )` |

### Oklab, sRGB out (W4)

`RGBA` stays sRGB. Every function converts to Oklab or OKLCH, works there, and comes back
through `OKLCH.rgba()`, which clamps lightness to 0…1 and, inside that, bisects chroma down
until the colour fits sRGB, so lightness and hue are kept. `OKLCH.maxChroma(l:h:)` is the same
bisection from 0.5: the most chroma sRGB holds there, which step 2's relative chroma divides by.
`Oklab(linearRed:green:blue:)` takes extended linear sRGB, so a P3 capture's colours outside sRGB
convert as they are. Below a chroma of 10⁻⁴ a colour is a grey and its hue is 0, as in CSS.

`WCAG.ratio` is WCAG 2's contrast, from relative luminance; alpha is ignored, since what a
translucent colour ends up over is not known.

### The syntax

- `oklab()`, `oklch()`, and `rgb()`/`hsl()` in the modern space-separated syntax with
  `/ alpha`; the legacy comma syntax stays for those two. Channels take numbers, percentages of
  the channel's reference (L 1, C and a/b 0.4, rgb 255, hsl's s/l 100, alpha 1), angles for a hue
  (`deg grad rad turn`), and `none`, which is 0.
- The relative syntax in all four: `oklch(from <colour> l c h [/ alpha])`, channel keywords
  `r g b`, `h s l`, `l a b`, `l c h`, and `alpha`, which an omitted alpha takes. The keywords are
  in the space's own units: rgb's 0–255, hsl's 0–100, Oklab's own.
- `calc()` over those, with `+ - * /`, precedence, and grouping by parentheses or a nested
  `calc()`. A percentage or angle inside it becomes the channel's units first, so
  `calc(l + 10%)` is `l + 0.1` and `calc(h + 0.25turn)` is `h + 90`; nothing else is checked for
  type. Dividing by zero is infinite and the channel's clamp takes it, as in CSS. `min()`,
  `max()` and `clamp()` work the same way, each argument an expression of its own, so
  `oklch(from wallpaper(seed) 0.23 min(c, 0.065) h)` is a colour's hue with its chroma capped;
  `clamp()`'s least wins when it crosses the most, as in CSS.
- `color-mix(in oklab | oklch | srgb | srgb-linear, <colour> [p%], <colour> [p%])`, premultiplied,
  with CSS's percentage rules: one missing is the rest of 100%, both are 50%, and a sum under
  100% is that much more transparent. OKLCH takes the shorter arc, and a grey takes the other
  colour's hue, so `color-mix(in oklch, x 70%, transparent)` is x at 70% alpha.
- `contrast-color(<colour>)`: white or black, whichever has the higher ratio; white on a tie.
- `on(<colour>[, <ratio>])`, bario's (W16): the colour's hue and half its chroma, on whichever
  side white or black contrasts more, starting at L 0.97 or 0.25 and moving towards the extreme
  only as far as the ratio (default 4.5, from 1 to 21) needs. 4.5:1 is always reachable; above
  about 4.58:1 against a mid-luminance colour it returns the extreme, as close as it can get.
  `OKLCH.readable(against:ratio:lighter:)` is that solver, which step 4's `on-` roles reuse.

The tokenizer's `.delim` is a `*` anywhere, or a `+` or `-` with no digit after it (and for `-`,
no letter either, which would start an identifier). So `calc(h + 50)` has a delimiter and
`calc(h +50)` is "needs an operator before '50'". A bare `(` is a function with no name.

### Folding (W3)

A colour function computes to `.rgba` where it is parsed when all its inputs are known: at parse
time for literals, and in the cascade once `var()` has been substituted (and, from step 3,
`wallpaper()` and `scheme()`). An input only commit knows, `accent`, `currentColor` or
`system()`, leaves it symbolic, as `.relative`, `.mixed`, `.contrast` or `.on`, nested as
written, and `ColorResolver.resolve` computes it, as it computes `accent`. `Color.constant` is
the test: `.rgba`, or `.none` as transparent.

What folds transitions as an ordinary colour. What stays symbolic blends as a `Color.mix` of its
ends, which commit resolves before mixing, like any symbolic colour.

A `.color(RGBA)` component has no syntax of its own; only substitution makes one. Its text is
`#rrggbb[aa]`, which is what a renderer reading a custom property receives.

## Step 2: extraction

`Sources/BarioKit/Palette/`

| file | holds |
|---|---|
| `Quantize.swift` | `Quantizer`: the image read through extended linear sRGB, the 32³ Oklab histogram, weighted k-means |
| `Palette.swift` | `Palette`, `Cluster`, `Slot`, `Seed`; `Palette.extract(_:previous:accent:)`; the store's JSON |

`Capture/PaletteCapture.swift` has `thumbnail(of:)`, ImageIO's thumbnail of a wallpaper file at
320 pixels, which `bario palette <image>` and (step 3) the file fallback use.

### Measuring (W4, W8)

`Quantizer(image:)` draws the image into a float context in extended linear sRGB, at most 320
pixels wide, so a P3 capture's colours outside sRGB come through as they are and a file of any
size measures like the capture. Each pixel goes to Oklab and into a cell of a 32³ grid over L
0…1 and a, b ±0.4, which keeps the weight and the mean colour of what fell in it. `clusters(k:)`
is weighted k-means over the occupied cells, k = 16 (fewer if there are fewer cells), seeded with
the heaviest cell and then the cell with the largest √weight × distance² to the centres so far,
stopping when no centre moves by 10⁻⁵ (or after 100 rounds). Everything runs in grid order, so
the same image gives the same palette, bit for bit.

A cluster's `relativeChroma` is its chroma over `OKLCH.maxChroma` at its lightness and hue; a
colour beyond sRGB has more than 1, and slots count it as 1.

### Slots (W9)

`Slot.specs` is W9's table. A slot scores each eligible cluster 0.40 × closeness in L + 0.35 ×
closeness in relative chroma + 0.25 × √(population ÷ the largest), where closeness is 1 at the
target and 0 at the far end of the slot's range. That normalisation is ours; the prototype's
exact formula was not kept. Eligible: inside both ranges, at least the least chroma, at least
0.2% of the image, not taken by an earlier slot, and for a variant at least 0.15 in L from the
base chosen before it. Slots choose in `Slot.Name.chosen`'s order, each base before its
variants. `dominant` is cluster 0, measured apart, and `dominantSameAs` names the slot that took
the same cluster.

Made up, when nothing is eligible:

- **a vibrant base** takes seed 1's hue, or the accent's without a seed, at its own L, with its
  source's relative chroma held to 0.45…0.85. This is the step 2 tuning the plan asked for. At a
  flat 85%, pale images got vibrant slots far louder than anything in them: Desert-3 (beige,
  seed C 0.05) a magenta at C 0.25, and the royce-fonseca photographs (seed C 0.014) a cyan
  `vibrant-light` at C 0.12. Following the seed but never below what a vibrant slot accepts
  gives C 0.13 and 0.065. The accent is vivid, so the no-seed case still comes out at 85%:
  `#448bee` for the default blue, the plan's W14 example.
- **a muted base** is the cluster nearest its lightness, moved to the slot's L with its relative
  chroma kept, capped at muted's 0.45 so that a vivid image's made-up muted slot is still muted.
  A grey stays grey.
- **a variant** is its base's hue and relative chroma at its own L, or further, so the gap holds.

`Palette.with(accent:)` re-chooses slots against another accent from the same clusters, with the
palette itself as `previous`; only a made-up vibrant of a seedless image changes.

### Seeds (W10)

`Seed.find(in:)` works on the grid cells, not the clusters. Each cell adds its share of the image
× clamp((C − 0.015) ÷ 0.085, 0, 1.5) to a 72-bin hue histogram, smoothed by a σ = 10° (two bins)
Gaussian around the circle. Local maxima, highest first, are taken if they are at least 5% of the
highest and at least 30° from those already taken, up to four. A seed's colour is the mean of the
cells within 15° of its peak, weighted by population × C², and its `mass` is the peak's smoothed
height over all the colour. Fewer than 0.4% of pixels with C > 0.015 means no seeds.

### Hysteresis (W11)

`extract(_:previous:)`: a slot whose last pick was found keeps the eligible cluster nearest that
last colour, if one is within ΔE 0.06 of it and scores within 5% of the best. Seeds have no
hysteresis, as planned: seed 1's hue held within 5° under the prototype's perturbations. Their
ranking can still swap between two near-equal peaks of a changing wallpaper, which would move
`wallpaper(seed)` and every scheme on it, easing. Worth watching once schemes exist.

### On the corpus

`bario palette ~/Pictures/wallpaper/*` reproduces the plan's observations: the Manhattan
twilight's vibrant is the warm city lights and its seed the blue sky; Sonoma's seed is its green
and its vibrant the blue-violet, with the coral a third seed; Neo Citrus keeps its teal as seed
2; the misty, nearly grey photograph has no seed, its vibrant slots come from the accent and its
muted slots are its own greys.

## Step 3: capture, the environment and the store

| where | what |
|---|---|
| `Capture/PaletteCapture.swift` | the wallpaper window, 320 wide, or the file, thumbnailed once per URL |
| `Style/Cascade.swift` | `StyleEnvironment` (dark, accent, palette); `wallpaper()` substituted in `resolve`; `WallpaperReference` |
| `Style/CSS.swift` | `needsSubstitution` and `mentions(_:)`; parse-time checks of `wallpaper()`; `Stylesheet.usesWallpaper` |
| `Frame/Bar.swift` | `palette`, and `paletteLooked` for the first frame |
| `Frame/FrameLoop.swift` | `setPalette`, `foundNoPalette`, `accentChanged`; the store write; the per-bar environment |
| `App/BarController.swift` | measuring in the capture round |
| `App/Shot.swift` | `--shot`'s palette from its backdrop picture |
| `App/CLI.swift` | `bario palette [image…]` |

### The capture (W5, W6)

`PaletteCapture.captured(info:)` filters ScreenCaptureKit's windows to the one owned by
`com.apple.WindowManager` and titled "Wallpaper" that overlaps the display most (confirmed on
this machine: one per display, at the display's full frame, layer desktop − 1), and photographs
it alone at 320 pixels wide in Display P3. Not finding it, while capture is allowed, warns once
and falls back to the file; capture failing falls back too. `--source capture` takes no file,
`--source wallpaper` takes no capture. Files are thumbnailed off the main actor and kept by URL
(at most eight, for a shuffling wallpaper). Under the same six-second deadline as the strip.

`BarController.captureBackdrops` measures each display after its strip, when the round was asked
for by an event (`lookAgain`) or the strip came back new, never while locked (the round does not
run) and never for a display a full screen app has (it keeps its palette). An image identical to
the last (`BackdropImage.same`) is not measured; otherwise `Palette.extract` runs detached with
the bar's last palette and the current accent, and `FrameLoop.setPalette` takes the result. No
image at all is `foundNoPalette`. An accent change calls `accentChanged`, which re-chooses with
`Palette.with(accent:)`; only a seedless palette's made-up vibrant slots move.

### The environment (W1, W2)

`Cascade` has a `StyleEnvironment` instead of a bare `dark` (which remains as a computed
property, and `Cascade(stylesheet:dark:)` as an initialiser). `FrameLoop.styleAndLayout` makes one
styler per frame with the appearance and the resolver's accent, and sets
`environment.palette = bar.palette` before each bar is styled; the `StyledBar` keeps that styler,
so layout's overflow restyle sees the same palette.

`resolve` substitutes `wallpaper()` beside `var()`, into a `.color(RGBA)` or into its fallback's
components, which are resolved in turn. A found slot is its colour whatever the fallback; a
made-up slot or no palette takes the fallback if there is one. Without one, no palette means a
palette of nothing: `Palette(clusters: [], …)` against the environment's accent, so vibrant
slots are the accent's hue and muted ones greys. `wallpaper(seed n)` is that seed, else its
fallback, else seed 1, else the accent.

Validation: `CSSParser.declaration` defers a declaration that needs substitution, as `var()`
always did, but `checkSubstitutions` builds a `WallpaperReference` for every `wallpaper()` in it,
nested ones included, so a slot that does not exist, `seed 5`, or the wrong number of arguments
is an error on its line.

A display list cannot name `wallpaper()` itself: `CanvasPainter.parseColor` refuses it (magenta,
the visible mistake). The raster key holds a canvas's custom properties and not the palette, so a
direct reference would never redraw; through `var()` it redraws exactly when its colour changes.

### The first frame (W7)

`isReady` also needs `paletteLooked`, but only while `wantsPalette`: the stylesheet, a socket
delta or an item's inline `style` mentions `wallpaper()` or `scheme()`. A bar coloured from
nothing in the wallpaper has no reason to wait, so it does not; that is also why the frame loop's
existing tests needed no palettes. The deadline still shows whatever there is.

### The store (W14)

`publishPalettes` writes `{"displays": […], "primary": …}` under `wallpaper` with
`StateStore.replace`, every time a palette changes or a measured bar goes, chained so writes land
in order. Displays are ordered left to right; the primary is the one at the global origin.
Entries are `Palette.json`, rounded so an unchanged palette is a write that changes nothing.
`ConfigLoader` refuses an item or source called `wallpaper`.

### `--shot`

The palette is measured from the same picture as the backdrop: the whole `--backdrop` file,
thumbnailed as a wallpaper file would be, or the checkerboard. `Shot.scene` takes a `palette`
(nil for `--diagnose`, which then shows the palette of nothing).

### Seen live

Running the debug build over the real desktop for a few seconds: the window was found and
photographed, the store held the entry, and `bario palette` printed it. The desktop's misty,
all but grey wallpaper has no seed, so its vibrant slots are the accent's `#448bee` and its
`dominant` `#e2e2e2`, within a level of the prototype's numbers in PLAN.md's W14 example.

## Step 4: schemes

| where | what |
|---|---|
| `Palette/Scheme.swift` | `SchemeRule`, `Harmony`, `Scheme` and its `Role`s and `Key`, `SchemeReference` |
| `Style/CSS.swift` | `@scheme` parsed, its descriptors checked; `Stylesheet.schemes`; `checkSchemeNames` |
| `Style/Cascade.swift` | `scheme()` substituted; `StyleEnvironment.schemes`; `Cascade.scheme(named:at:)` |
| `Frame/Bar.swift` | `schemes(for:in:)` and its cache |

### The rule (W12)

`@scheme [--name] { seed; harmony; chroma; contrast }`, defaults `wallpaper(seed)`, `tonal`, `1`,
`4.5`. The block is read with `declarationBlock(validate: false)` and each descriptor checked by
hand: an unknown one, a harmony that is not a name or two angles, a negative chroma (`seed` is the
other spelling), a contrast outside 1…21, are errors on their line. The seed is kept as
components. It may mention `wallpaper()`, `accent` and `system()`, and is parsed at parse time
with each `wallpaper()` standing in as black, for its grammar and for `Color.mentionsCurrent`:
`currentColor` anywhere in it is an error, since a scheme belongs to a bar. So are `var()` and
`scheme()`; custom properties belong to nodes. Rules live in `Stylesheet.schemes` by name, ""
for the unnamed, and `appending` lets the later win, as for `@keyframes`.

`scheme(<role>)` and `scheme(--name <role>)` are checked as `wallpaper()` is: a role that does not
exist is an error where it is written. A name is checked once the whole sheet has been read
(`checkSchemeNames`), against the sheet's own schemes and `knownSchemes`, the names of the sheets
it will be layered over: `Theme.load` passes the built-in sheet's for the user's, and the socket's
`style` passes the running sheet's for a delta. The unnamed scheme is always there. Inline item
styles cannot be checked against a stylesheet when the config is read; a missing name there is a
cascade diagnostic.

### The scheme

`SchemeRule.key(in:)` resolves the seed as commit would (W3's exception): `wallpaper()`
substituted through a stylesheet-less `Cascade.resolve`, the result parsed, and resolved with a
`ColorResolver` of the environment's appearance and accent, so `accent` and `system()` are known.
Alpha is dropped. The `Scheme.Key` is that seed with the harmony, chroma, contrast and appearance.

`Scheme(key)`: primary chroma 0.13 × the scale, or the seed's own chroma held to 0.03…0.2 for
`chroma: seed`. Secondary takes 0.8 of it on a hue of its own, 0.35 on the seed's; tertiary 0.75;
neutral 0.012 at the seed's hue; `monochrome` has none anywhere. `Harmony.turns` gives the
secondary's and tertiary's turns from the seed, nil for the seed's own hue; two angles are as
written, and a turn of a whole circle counts as the seed's hue. Roles are W12's lightnesses for
light or dark, gamut-mapped by chroma.

Every `on-` role is `OKLCH.readable(against:ratio:lighter:)` from its own lightness and its
family's chroma and hue: lighter for `on-primary` and kin in the light scheme, darker in the dark,
and the other way round for `on-*-container`, `on-surface`. `on-surface` is solved against
`surface-container` and then checked against `surface`, so it reads on either, which is how the
two are usually paired. `outline` starts at the surface and moves away until it is 3:1 against
it, whatever `contrast` says. `Role.partners` says what each `on-` role is promised against.

At the default contrast every pair already reads where it starts, from 5:1 (`on-primary` on a
light scheme's primary) to 15:1; a contrast out of reach of white or black against the partner,
such as 7 against the light primary at L 0.52, ends at the extreme, as close as it gets. The
fills never move to make room.

### Caching

The frame loop asks each bar for `schemes(for: sheet, in: environment)` once its palette is in
the environment, and puts the result in `environment.schemes`. The bar keeps the schemes its last
styling used, by key, and makes only what is new: two rules with the same seed, harmony, chroma,
contrast and appearance share one. The unnamed scheme is always among them, so a stylesheet that
never says `scheme()` still makes one, once, which costs microseconds. A cascade with no cached
scheme for a name, in `--shot` or a test, makes it when asked.

`wantsPalette` counts `scheme()` as reading the wallpaper even when every scheme's seed is
`accent`. A first frame then waits for a palette it did not need; it arrives in the same capture
round as the backdrop.

## Examples

`examples/themes/slots.css` is built on slots: bubbles a wash of `muted-dark`, ink from `on()`,
one bubble in `wallpaper(vibrant, accent)`. `examples/themes/schemes.css` is built on schemes:
`primary-container` bubbles with their `on-` ink, `primary` for the clock, and a complementary
`--pop` scheme for the battery. A test parses and cascades both.
