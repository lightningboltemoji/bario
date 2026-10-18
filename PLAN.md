# Plan: colours from the wallpaper

How the stylesheet gets colours that go with the wallpaper. DESIGN.md §7 will say what and why
once it is built; this is the how, written in October 2026 after a prototype and before any of it
is in bario. When a step starts, its knowledge note (`.agents/knowledge/22-wallpaper-colours.md`)
is written from the matching part of this file.

Three tools, each useful alone and better together:

- **measure**: `wallpaper(vibrant)` and its siblings, colours really in each display's wallpaper;
- **generate**: `@scheme` and `scheme(primary)`, a theme generated from one seed colour;
- **adjust**: CSS Color 4 and 5, `oklch(from <colour> l c calc(h + 50))`, `color-mix()` and
  `contrast-color()`, plus bario's `on()`, a readable partner for any colour at all.

```css
@scheme { seed: wallpaper(seed); harmony: tonal; chroma: 1; contrast: 4.5; }   /* the defaults */
@scheme --pop { seed: accent; harmony: 50deg 180deg; }

:root {
  --glow: oklch(from wallpaper(vibrant) l c calc(h + 50));
  --wash: color-mix(in oklch, wallpaper(muted-dark) 70%, transparent);
}
item     { background: scheme(primary-container); color: scheme(on-primary-container);
           transition: background 600ms ease-in-out, color 600ms ease-in-out; }
#clock   { background: scheme(--pop primary); color: scheme(--pop on-primary); }
#battery { background: var(--wash); color: contrast-color(wallpaper(muted-dark)); }
#wifi    { background: wallpaper(vibrant); color: on(wallpaper(vibrant)); }
```

Every colour there is resolved per bar from that display's wallpaper, and a new wallpaper eases
in through whatever `transition` the stylesheet already has.

**All of it is ours.** Oklab is Björn Ottosson's and in the public domain ("feel free to use it
any way you please"). The slots borrow Android Palette's idea and names; the seed and the scheme
roles borrow Material You's idea and names. Neither's code, maths or numbers are used, and
matching their colours is a non-goal. bario keeps its one dependency.

## Where we start

- **Colours are symbolic until commit.** `Color` (`Style/Properties.swift`) is `rgba`, `mix` (two
  colours mid-transition), `system(name)`, `accent`, `current` or `none`. `CSSValue.color` parses
  hex, a few named colours, `rgb[a]()`, `hsl[a]()` and `system()`, and `ColorResolver` turns them
  into `RGBA` at commit. `RGBA` is sRGB. Display lists parse their colours with the same parser,
  against the node's custom properties (`CanvasPainter.parseColor`).
- **The cascade** (`Style/Cascade.swift`) is one `Cascade(stylesheet:dark:)` per frame, shared by
  every bar. It substitutes `var()` on component lists before any property parser sees them,
  custom properties first. A declaration with `var()` in it is not validated at parse time.
- **Transitions** start when a property's value differs between the old style and the new
  (`Animator.StyleMotion.retarget`). A colour that changes in the style eases; one that changes
  only at commit, as `accent` does, snaps.
- **The tokenizer** knows `,` and `/` as delimiters and nothing else. A lone `+` is a malformed
  number and `*` an unexpected character.
- **At-rules** are `@media`, `@keyframes` and `@starting-style`, one switch in
  `CSSParser.stylesheet()`. `Stylesheet.appending` lets a later sheet's `@keyframes` win.
- **The capture** photographs the strip only (`Capture/Strip.swift`), through a filter of every
  window below normal level. It runs on events, each second while the desktop keeps changing, and
  on the refresh timer, and never while the screen is locked (`BarController.captureBackdrops`).
  `WallpaperSpec` and `fromWallpaperFile` stand in without permission.
- **A bar is ordered in** once a backdrop exists and every item has rendered, or at the deadline
  (`FrameLoop`, `bar.isReady`).
- **The state store** has no key that bario writes for itself.

## The shape of it

```
wallpaper window ──▶ PaletteCapture ──▶ Palette.extract ──▶ FrameLoop.setPalette
 (320px, ~25ms)       or the file        clusters, slots,      style dirty for that bar;
                                         seeds (~3ms)          `wallpaper` in the store
                                                                 │
          Cascade(stylesheet, environment: dark, accent, palette, schemes)
            wallpaper() and scheme() substituted like var(), into colours
            oklch(from …), color-mix(), contrast-color() folded when their inputs are known
                                                                 │
          Style ──▶ Animator, which eases the change ──▶ commit
```

| type | file | what it is |
|---|---|---|
| `Oklab`, `OKLCH` | `Style/Oklab.swift` | conversions, gamut mapping by chroma, WCAG contrast |
| `Color.relative`, `.mixed`, `.contrast`, `.on` | `Style/Properties.swift` | colour functions with an input only commit knows |
| `CSSComponent.color`, `.delim` | `Style/CSS.swift` | a colour already computed; a `+`, `-` or `*` |
| `StyleEnvironment` | `Style/Cascade.swift` | what a cascade knows of its bar: `dark`, the accent, the palette, its schemes |
| `Palette`, `Cluster`, `Slot`, `Seed` | `Palette/Palette.swift` | one display's measurement; `Palette.extract(_:previous:)` |
| `Quantizer` | `Palette/Quantize.swift` | the histogram and the k-means |
| `Scheme`, `SchemeRule`, `Harmony` | `Palette/Scheme.swift` | a generated theme, and the at-rule that asks for one |
| `PaletteCapture` | `Capture/PaletteCapture.swift` | the wallpaper window, small, or the file |
| `bario palette` | `App/CLI.swift` | prints a palette, live or from image files |

## Decisions made while planning

Numbered W, so they cannot be mistaken for the D1–D15 that comments in the code still cite. Those
come from the compositor plan this file held before, which is in its git history.

**W1. A palette is a style input, per bar.** A display's new palette invalidates style for its
bar, as an appearance change does for every bar, and the cascade turns `wallpaper()` and
`scheme()` into concrete colours. So a new wallpaper eases through the stylesheet's own
`transition`. Raster keys see real colours, so a canvas using one redraws when it changes with
nothing added to `RasterStyle`. A renderer's custom properties carry real colours too. The other
way, symbolic cases resolved at commit as `accent` is, would snap every change and need the
palette in the raster key. Restyling one bar once per wallpaper change costs nothing that matters.
`Cascade` gains a `StyleEnvironment`, set per bar from `Bar.palette` before that bar is styled.

**W2. `wallpaper()` and `scheme()` substitute, like `var()`.** `Cascade.resolve` replaces each
with a `.color(RGBA)` component before any property parser runs. They then work wherever a colour
does: custom properties, gradients, shadows and display lists alike. Their presence defers a
declaration's validation, as `var()` does, but their own arguments are checked at parse time. A
slot or role that does not exist is an error with a line number. So is a `--name` that no
`@scheme` defines, checked once the whole sheet has been read.

**W3. Colour functions fold when they can.** After W2, `oklch(from wallpaper(vibrant) …)` has only
known inputs, so the cascade makes it `.rgba` and it transitions like any colour. A function of
literals folds at parse time. One with an input only commit knows (`currentColor`, `accent`,
`system()`) stays symbolic as `Color.relative`, `.mixed` or `.contrast`, and `ColorResolver`
evaluates it at commit, as it evaluates `accent` today. A scheme's seed is the exception. It has
to be known to make the scheme, so the environment resolves it, accent and `system()` included.
The style already restyles on an accent or appearance change, so nothing goes stale.

**W4. P3 in, sRGB out.** `RGBA` stays sRGB, as every other colour in bario is. Measurement reads
the capture, which is Display P3, through extended linear sRGB, so colours outside sRGB are seen
as they are. Anything that comes out of OKLCH beyond sRGB is brought in by lowering chroma at the
same lightness and hue, bisected. Wide-gamut output would be a change to `RGBA`, not to this.

**W5. The palette photographs the wallpaper window, small.** Measured on macOS 27.2, these are the
windows below normal level, bottom up:

| layer | owner, title | what |
|---|---|---|
| desktop − 3 | Window Server, "Display 3 Backstop" | behind everything |
| desktop − 1 | `com.apple.WindowManager`, "Wallpaper" | the wallpaper |
| desktop icon | Finder, untitled; WindowManager, "Event Shield Window" | icons; a click catcher |
| desktop icon + 1 | Window Server, "underbelly" | the shading under the menu bar, 122pt tall |
| desktop icon + 2 | Notification Center, one per widget | desktop widgets |

The strip's filter takes all of them, and a palette must not: a calendar widget is a palette's
worth of grey. So `PaletteCapture` filters to the one window by owner and title (the title is
readable because capture needs Screen Recording anyway), at 320 pixels wide. A capture took 23–30ms
at any size from 160 to 640 pixels wide, and 95ms cold. When that window is not found, or capture
is not allowed, the wallpaper file stands in. ImageIO thumbnails it to the same size off the main
actor, once per URL, which took 2–160ms. With neither, there is no palette (W10).

**W6. When.** In the same round as the strip, display by display, after it. That is on every
event, and in the settle loop and on the refresh timer whenever that display's strip came back
new. A palette image identical to the last is not new (`BackdropImage.same`) and costs no
extraction. Nothing while locked, as for the strip. A full screen Space has no wallpaper window,
so the last palette stays, as the last photograph does.

**W7. The first frame waits for a palette.** A bar ordered in before its palette would come in
wearing fallbacks and then ease to the wallpaper's colours. So `isReady` also needs a palette, or
an attempt that found none, under the same one-second deadline.

**W8. Extraction.** The 320 pixel image goes to Oklab, and into a histogram on a 32³ grid over
L ∈ [0, 1] and a, b ∈ [−0.4, 0.4] that keeps each bin's mean, not its centre. Weighted k-means
runs on the bins with k = 16. It is seeded deterministically: the heaviest bin first, then the
bin with the largest √weight × distance² to the centres so far, so a small vivid patch can claim a
centre. It stops when no centre moves by 10⁻⁵. Extraction took about 3ms in all, 0.1ms of it
k-means, and the same image always gives the same palette.

**W9. Slots.** Each slot asks for a lightness and a relative chroma, and takes the eligible
cluster that scores best. Relative chroma is chroma as a fraction of the most sRGB holds at that
lightness and hue, which is what saturation is to HSL, measured perceptually. A cluster scores
0.40 for lightness, 0.35 for chroma and 0.25 for √(population ÷ the largest). Clusters under 0.2%
of the image are ignored, a cluster fills one slot, and slots choose in the table's order, each
base before its variants.

`dominant` is the largest cluster, measured apart from the slots, so it is often the same colour
as one of them. That happened in 16 of the prototype's 27 images; an orange wallpaper's biggest
colour is its vibrant one. It is a true fact about the image, so it is kept, and the store says
which slot it shares a cluster with (W14).

| slot | L (range) | relative chroma (range) | least C |
|---|---|---|---|
| `vibrant` | 0.64 (0.45–0.82) | 1.0 (≥ 0.45) | 0.05 |
| `vibrant-dark` | 0.38 (0.15–0.52) | 1.0 (≥ 0.40) | 0.04 |
| `vibrant-light` | 0.84 (0.72–0.96) | 1.0 (≥ 0.35) | 0.04 |
| `muted` | 0.60 (0.40–0.78) | 0.22 (0.06–0.45) | 0.012 |
| `muted-dark` | 0.32 (0.10–0.48) | 0.22 (0.06–0.45) | 0.012 |
| `muted-light` | 0.86 (0.72–0.97) | 0.22 (0.06–0.45) | 0.012 |

**A family is distinct, though not readable.** A `-dark` slot is at least 0.15 darker in L than
its base, and a `-light` slot at least 0.15 lighter. A variant's candidates have to keep that gap
from the base chosen before them. The gap comes to about 1.6–1.9:1: enough to tell two fills
apart, not enough for text (W16). The table's lightness ranges overlap, so without the gap
`vibrant` and `vibrant-dark` came as close as 1.17:1, and `muted` and `muted-light` 1.07:1. With
it, of the 51 variants the corpus found in its images, 35 kept their colour, 6 took another
cluster and 10 were made up.

A slot that nothing fits is made up, so every slot always has a colour. A vibrant base takes the
seed's hue, or the accent's without a seed, at its own lightness and 85% of the chroma sRGB holds
there. A muted base takes the cluster nearest its lightness and moves it there. A variant is made
from its base: the base's hue and relative chroma, at the variant's own lightness or further, so
that the gap holds. `wallpaper(<slot>, <fallback>)` uses the fallback instead whenever the slot
was made up or there is no palette, so "the wallpaper's own vibrant, or my colour" is one
expression. These are starting numbers, tuned on the prototype's corpus, and free to move.

**W10. Seeds.** A histogram of hue in 5° bins, each grid bin weighted by its population ×
clamp((C − 0.015) ÷ 0.085, 0, 1.5), is smoothed by a Gaussian of σ 10° around the circle. Its
peaks are the seeds: up to four, at least 30° apart and at least 5% of the highest, ranked by mass.
Each seed's colour is the mean of the grid within 15° of its hue, weighted by C². A broad wash of
colour outweighs a small vivid patch. Sonoma's seed is its green although its coral is more
saturated, and that is what makes the seed a better source for a scheme than `vibrant`. At σ 15°
neighbouring hues merged (Neo Citrus lost its teal); 10° keeps them. With under 0.4% of the image
carrying colour there is no seed, and `wallpaper(seed)` is the accent, or its fallback.
`wallpaper(seed 2)` names the next one down. Where there is no second, it is its fallback or else
the first.

**W11. Hysteresis.** Discrete choices flip between near-ties. Perturbing the corpus (160 or 640
pixels instead of 320, a 4% crop, k = 24) moved 7–13% of slots to a different cluster, while seed
1's hue moved at most 5°. Merging near-identical clusters first did not help. A still wallpaper
never flips, since its photographs are identical (W6), but one that changes does: cross-fading
Sonoma's light and dark frames in 24 steps flipped a slot back and forth. So extraction takes the
last palette. A slot keeps a cluster within ΔE 0.06 of its last colour if that cluster scores
within 5% of the best. That removed the back and forth. What still moves follows the image, and
eases (W1). The last palette lives on the `Bar`, so a stylesheet or config reload does not reset
it.

**W12. Schemes.** `@scheme [--name] { seed; harmony; chroma; contrast }`, with defaults
`wallpaper(seed)`, `tonal`, `1` and `4.5`. The unnamed scheme is what `scheme(<role>)` uses;
`scheme(--name <role>)` names another. `seed` is any colour but `currentColor`, since a scheme
belongs to a bar, not a node. A scheme is four hues with chromas: primary at the seed's hue,
secondary and tertiary where the harmony puts them, and neutral at the seed's hue with almost no
chroma.

| harmony | secondary | tertiary |
|---|---|---|
| `tonal` (default) | the seed's hue, quiet | +60° |
| `analogous` | −30° | +30° |
| `complementary` | the seed's hue, quiet | +180° |
| `split` | +150° | +210° |
| `triadic` | +120° | +240° |
| `monochrome` | no chroma anywhere | |
| `<angle> <angle>` | as written | as written |

Primary's chroma is 0.13 × `chroma`. Secondary takes 0.8 of that on a hue of its own, or 0.35 on
the seed's; tertiary takes 0.75, and neutral 0.012. `chroma: seed` follows the seed's own chroma
instead, clamped to 0.03–0.2, which suits a muted wallpaper better. Roles are those hues at fixed
lightnesses:

| role | light L | dark L |
|---|---|---|
| `primary`, `secondary`, `tertiary` | 0.52 | 0.80 |
| `on-primary`, `on-secondary`, `on-tertiary` | 0.99 | 0.24 |
| `primary-container`, … | 0.90 | 0.36 |
| `on-primary-container`, … | 0.28 | 0.94 |
| `surface` | 0.975 | 0.20 |
| `surface-container` | 0.93 | 0.27 |
| `on-surface` | 0.24 | 0.93 |
| `outline` | 3:1 against `surface` | 3:1 against `surface` |

An `on-` role starts at its lightness. It moves further only when it falls short of `contrast`
against its partner, to the extreme if need be; this is the same solver as `on()` (W16). In the prototype the pairs came out at 5–15:1. The
obvious rule, moving only as far as the ratio needs, left every pair at exactly 4.5:1, which read
washed out beside it. Light or dark is the cascade's `dark`. Schemes are cached per bar by seed,
harmony, chroma, contrast and appearance.

**W13. CSS Color's own syntax for adjusting.** `oklch(from <colour> <L> <C> <H> [/ <alpha>])` and
`oklab(from …)`, with the channel keywords (`l c h alpha`, `l a b alpha`), numbers, percentages
and `calc()` of `+ - * /` over them. `rgb(from …)` and `hsl(from …)` come with them, since the
machinery is the same. Then `color-mix(in <space>, <colour> [<p>%], <colour> [<p>%])` in `oklab`,
`oklch` (the shorter hue arc), `srgb` and `srgb-linear`, and `contrast-color(<colour>)`, which is
white or black, whichever has the higher WCAG ratio against it. The tokenizer gains `.delim` for a
`+`, `-` or `*` with whitespace around it, which is what `calc()` asks of a stylesheet anyway.

**W14. The store has measurements; the stylesheet has opinions.** bario owns the top-level key
`wallpaper`, and an item of that name is a config error.

```json
{ "displays": [ { "name": "Studio Display XDR", "id": 3, "primary": true,
                  "clusters": [ { "hex": "#e3e3e3", "oklch": [0.91, 0.0, 0], "population": 0.31 } ],
                  "slots": { "dominant": { "hex": "#e3e3e3", "oklch": [0.91, 0.0, 0], "found": true,
                                           "same-as": "muted-light" },
                             "vibrant": { "hex": "#448bee", "oklch": [0.64, 0.16, 256], "found": false } },
                  "seeds": [] } ],
  "primary": { "…": "the primary display's entry again" } }
```

Schemes are not in it, since only the stylesheet knows its seeds and harmonies. A module that
wants scheme colours gets them through `var()` in its display list, which the host resolves (W2).

**W15. `bario palette`** prints clusters, slots and seeds as truecolour swatches with their numbers.
With no argument it shows each display's live palette from the store; with image paths, each
file's. It is how the numbers in W8–W12 get tuned, and how a surprising palette gets reported.

**W16. Contrast is promised by what generates colours, never by what measures them.** Slots and
seeds promise nothing about contrast with each other; W9's gap only keeps a family distinct.
When two slots come out alike, that is true of the image. Desert-3 is beige everywhere, and
forcing its slots apart would mean inventing colours it does not have. Readability comes from
three places instead:

- a scheme's `on-` roles (W12);
- `contrast-color(<colour>)`: black or white (W13);
- `on(<colour>[, <ratio>])`, which is bario's own and not CSS's. It is W12's on-colour rule for
  any colour. It keeps the colour's hue and half its chroma, on whichever side black or white
  contrasts more. It starts crisp, at L 0.97 or 0.25, and moves further only when short of
  `<ratio>` (default 4.5), to the extreme if need be.

4.5:1 is always reachable. Nothing above about 4.58:1 is, against a colour of middle luminance,
and there `on()` gets as close as it can. In the prototype, `on()` reached at least 4.5:1 on
every slot of every image, with a median of 9.4:1. Like `contrast-color()`, it stays symbolic
while its input does (W3).

The rule for a stylesheet: anchor on one colour and derive its partner. Never pair two slots as
text and background. Slots are for fills, borders, accents and seeds.

## What the prototype showed

A prototype of W4, W8–W12 and W16, about 550 lines of Swift, ran on 30 images: the 18 in
`~/Pictures/wallpaper`, seven of macOS's own, three solid colours, and live captures of the
desktop.

- **Grey wallpapers have no seed.** The misty mountain on the desktop while this was written is
  all but grey (C ≤ 0.01), and so is a white sands photograph. Both fall back to the accent, and
  their muted slots stay the image's own greys. Fallbacks are a first-class path, not an edge
  case.
- **Vibrant and seed answer different questions, as planned.** In the Manhattan twilight,
  `vibrant` is the warm city lights and the seed is the blue sky. In Sonoma, `vibrant` is the
  blue-violet and the seed is the green.
- **Made-up vibrant slots can be loud.** On a pale image whose seed is a faint teal, a vibrant
  slot made up at 85% of sRGB's chroma is much brighter than anything in the picture. It is
  flagged as made up in the store and replaceable with a fallback, but its chroma may want to
  follow the seed's. To tune in step 2.
- **Costs.** Capture 23–30ms, extraction about 3ms, schemes microseconds, per display, per
  wallpaper change.

## Step 1: colour maths and CSS Color 4 and 5

Oklab and OKLCH, gamut mapping, WCAG contrast; `oklab()`, `oklch()`, relative colours with
`calc()`, `color-mix()`, `contrast-color()`; `on()` and the contrast solver behind it, which step
4's `on-` roles reuse; `.delim`; the symbolic cases and their evaluation in `ColorResolver`;
folding (W3). Useful before anything else lands:
`border-color: oklch(from accent l c calc(h + 180))`, or `color: on(accent)`.

Tests: known conversions, with sRGB red at about `oklch(0.628 0.258 29.2)`; round trips; gamut
mapping keeps L and h; contrast of black on white is 21; `calc()` precedence and units; every
error points at its line; what folds and what stays symbolic; a transition between two folded
colours eases; `on()` reaches 4.5:1 against every colour on a grid over OKLCH, and gets as close
as it can to ratios that are out of reach.

## Step 2: extraction

`Palette/` and `bario palette <image>`. Tests on images the tests draw, not wallpapers in the repo:

- a solid colour is one cluster, the seed is its hue, and the slots are made up;
- 70% of one colour and 30% of another makes the 70 dominant;
- a grey ramp has no seed, and its vibrant slot is made up from the accent;
- a vivid 3% patch on a dull field is `vibrant` but not the seed;
- every family keeps its gap, whether its variants were found or made up;
- an image whose biggest colour is its most vivid has `dominant` and `vibrant` the same, and says
  so;
- the same image twice gives an identical palette;
- a near-tie flips without `previous` and holds with it.

## Step 3: capture, the environment and the store

`PaletteCapture`; `Bar.palette`; `FrameLoop.setPalette`, which invalidates style for that bar;
`StyleEnvironment`; `wallpaper()` substituted; the first-frame rule (W7); the store key (W14);
`bario palette` live. `--shot` takes its palette from the same source as its backdrop, the capture
or the wallpaper file. After this
step, `item { background: wallpaper(vibrant) }` follows a change of wallpaper, easing.

Tests, headless against the frame loop: a new palette restyles its bar and no other; an identical
one restyles nothing; the first frame waits for a palette, or for the deadline; a canvas using
`var(--x)`, with `--x: wallpaper(vibrant)`, redraws when the palette changes and not otherwise.

## Step 4: schemes

`@scheme` and its descriptors, with errors; `scheme()` substituted; `Palette/Scheme.swift`; the
cache. A `bario style` delta can redefine a scheme, the later sheet winning as for `@keyframes`.

Tests: every `on-` role meets its contrast in every harmony and both appearances, across seeds
that include near-grey, very light and very dark ones; `monochrome` has no chroma; named schemes
resolve to their own seed; a missing name is a parse error.

## Docs, as we go

DESIGN.md §7: the new colour values, and a subsection on colours from the wallpaper beside the
backdrop's. §10's invalidation table gains "a new palette: style, for that bar". §3 or §4 says
that bario writes `wallpaper` in the store. The knowledge note is
`22-wallpaper-colours.md`. Examples go in `examples/themes/`: one stylesheet built on schemes, one
on slots.

## Risks

- **The wallpaper window's owner and title are not API.** If a later macOS renames it, the file
  stands in, which is wrong for aerials and dynamic desktops but still a palette. The capture
  warns once when it falls back for that reason, so the change gets noticed.
- **Spaces have wallpapers of their own,** so switching Space can restyle a bar. That is the
  feature, but colours easing while the desktop slides may want a shorter transition. Watch it
  before deciding anything.
- **Tuning is taste.** The numbers come from one corpus and one evening. `bario palette` exists so
  they keep moving after this lands.

## Not in this plan

- Matching Material You or Android Palette, colour for colour.
- Wide-gamut colours out (W4).
- Scheme parameters per item, such as a `--scheme-harmony` that `scheme()` reads. A named
  `@scheme` covers that for now.
- Sampling part of the wallpaper, such as only what is under the bar. `backdrop` already shows
  that, and `contrast: auto` measures it.
- A scheme that is light or dark by the backdrop under the bar rather than the system appearance,
  as the menu bar's own ink is. Worth trying once schemes exist.
- Raising `contrast` when macOS's "Increase contrast" is on. Easy once W12 exists.
- Writing the palette into other programs' configs, such as terminal themes. The store is there
  for whoever wants to.
