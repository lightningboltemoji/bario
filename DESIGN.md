# bario design

Status, September 2026: phases 1–7 (section 12) are built. The shared-surface source of phase
7 receives its surfaces through the one deprecated call in bario, `bootstrap_register`, because
an app a user opens has no other way to be found by a Mach port (section 13).

bario is a system bar for macOS in the spirit of waybar. It lives in a window over the menu
bar, on every display, and it does not hide the real bar: it covers it with a photograph of the
desktop and punches a hole through itself around the pointer so you can peek at what's
underneath. An early probe proved the cover, the photograph and the hole. This document is about everything that goes *on* the cover.

Vocabulary, used consistently from here on:

| term | meaning |
|---|---|
| **bar** | the strip on one display; one per display, all driven by one config |
| **item** | one bubble on the bar: chrome (background, padding, radius) around some content |
| **group** | an item whose content is other items |
| **content** | a small tree of nodes (text, icon, meter, graph, row…) inside an item |
| **module** | the code that turns state into an item's content; built in, `exec`, or WASM |
| **state store** | a key/value tree that modules and external processes write into |
| **provider** | anything that writes state: a built-in poller, a shell command, a socket client, a WASM module |
| **source** | a provider in the config with no bubble: a module whose state other items read (section 3) |
| **mode** | a named condition over the state store and time, which the bar is in or not (section 6) |
| **scene** | one bar laid out: every item and node with its resolved style and its rectangle |
| **frame** | one pass of the rendering pipeline, run because something was invalidated (section 10) |

The one idea that organises the rest: **content is a pure function of state.**
Providers write state. Modules render state to content. bario lays out, styles and paints
content. Push and pull are then the same thing seen from two ends: a poll writes to the
store on a timer, a socket client writes to the store when it feels like it, and the item
re-renders either way.

```
 providers                state store        modules            the frame (section 10)
 ───────────              ───────────        ───────            ──────────────────────
 built-in pollers ──┐                                          style (css subset)
 exec on interval ──┼──▶  battery.pct ──▶  render(state) ──▶  layout (flex + notch)
 socket clients   ──┤     wifi.rssi        content tree        present (transitions, hole)
 wasm timers      ──┘     weather.temp                         commit ──▶ compositor (GPU)
```

## 1. Process model

One process, `bario`, an `.app` bundle (so Screen Recording permission attaches to bario and
not to whichever terminal launched it). It owns:

- one cover window per display, exactly as the probe does today;
- the state store;
- every module instance, including the WASM runtime;
- a Unix domain socket for external processes;
- the config and stylesheet, watched for changes and reloaded live.

Concurrency: AppKit, style, layout and the commit to each bar's layer tree stay on the main
actor, and compositing happens in the window server. The state store is an actor. Each module
instance is an actor with its own serial executor, so a slow module never stalls a frame or
another module. The socket server runs on its own queue and forwards decoded
messages to the store.

A separate tiny CLI, `bario` (the binary inside the bundle doubles as it: `bario set …` talks
to the running instance over the socket, `bario --run` is the daemon), covers shell scripts.

## 2. Content model

A module's render result is:

```json
{
  "content": { "row": { "gap": 4, "children": [
      { "icon": "battery.75percent", "class": "ico" },
      { "text": "73%", "class": "pct" },
      { "meter": { "value": 0.73, "width": 24 }, "class": "bar" }
  ] } },
  "classes": ["charging"],
  "tooltip": "3:10 remaining",
  "visible": true
}
```

The built-in node vocabulary is small. Everything an item can show is one of these, or a
custom node (section 9):

| node | payload | notes |
|---|---|---|
| `text` | string | one run; style controls font, colour, weight |
| `icon` | SF Symbol name, or `{ "file": path }` | SF Symbols are the reason to be on macOS; rendered at the current font size and colour |
| `meter` | `{ value: 0…1, width }` | horizontal fill, e.g. battery, volume |
| `graph` | `{ values: [..], width, max? }` | sparkline, e.g. network throughput, CPU |
| `row` / `column` | `{ gap, align, children }` | containers |
| `spacer` | `{ grow? }` | flexible space inside a row |
| `canvas` | `{ width, height?, ops: [..] }` | a vector display list painted by the host; the escape hatch, section 9 |
| `raster` | `{ width, height?, source }` | a pixel buffer supplied by the module; the bigger escape hatch, section 9 |
| *custom* | anything | a node type registered by a renderer module, e.g. `{ "ring": { "value": 0.7 } }`; section 9 |

Every node takes an optional `class` (a list is fine) and `id`, so the stylesheet can address
parts of an item: `#battery .pct { font-weight: semibold }`. `classes` at the top level are
state classes on the item itself, in the waybar sense (`#battery.charging`, `#wifi.off`).

The tree is data, not code. That is what lets the same shape travel over the socket as JSON,
through WASM linear memory as JSON bytes, and out of built-in modules as Swift values. There is
one schema (`schema/content.json`, JSON Schema) and every path validates against it.

Most people will never write a content tree by hand. Built-in modules accept a **format
string** and produce a `text` node from it:

```
format = "{icon} {pct}%"          # battery
format = "{ssid} ↓{rx}"           # wifi
```

Slot names are per module and documented with it. A `{icon}` slot expands to an `icon` node,
so formats can mix icons and text. This is the waybar affordance and it covers the 80% case.

## 3. Modules and providers

Three tiers of authoring, cheapest first. Most bars will use only the first two.

**Tier 1, config only.** Built-in modules, configured with a format string and some options.
The initial set, chosen because each one replaces something the cover is hiding:

| module | source | state it writes |
|---|---|---|
| `front-app` | `NSWorkspace.frontmostApplication` + activation notification | `name`, `bundle-id`, `icon` |
| `clock` | timer aligned to the next second/minute | `now` |
| `battery` | IOKit `IOPSCopyPowerSourcesInfo`, on change notification | `pct`, `charging`, `time-remaining` |
| `wifi` | CoreWLAN | `ssid`, `rssi`, `on`; SSID needs Location permission on macOS 14+, degrade to `rssi` only |
| `volume` | CoreAudio default output device listener | `level`, `muted` |
| `net` | `getifaddrs` counters on an interval | `rx`, `tx`, rolling history for `graph` |
| `cpu` / `mem` | `host_statistics` on an interval | `load`, `used`, history |
| `text` | none | static content from config |
| `data` | nothing of its own | renders whatever was pushed under its key (Tier 2) |

**Tier 2, scripts and other processes.**

- `exec`: run a command on an interval, or keep it running and read lines (`interval = "watch"`,
  like waybar's `exec` with continuous output). Stdout is either plain text or, if it parses,
  JSON, which is written into the store as-is. Format strings apply as usual, and a line with
  a `content` key shows that content tree, so a script can draw anything a module can.
- The socket (section 4): any process writes state under any item's key, or pushes a whole
  content tree to a `data` item. The `bario` CLI wraps this for shell use.
- `source`: a module that only writes state. It is configured like an item, runs like one, and
  is never laid out, so another program's stream of facts lands in the store for any item to
  read and any mode to watch, with no bubble on the bar:

  ```kdl
  source "emira" module="exec" interval="watch" { command "emira" "watch" }
  ```

A write that changes no value changes nothing: it invalidates no render and notifies no
subscriber, so a stream that repeats itself costs nothing. Under an item's key, `content` is a
content tree and a write replaces it whole; two trees merged key by key are neither.

**Tier 3, WASM modules** (section 5): user code, sandboxed, in any language with a wasm32
target. For when a script is too slow, too chatty, or needs to react to events and clicks.

Every module, whatever tier, has the same lifecycle: `init(config)`, then zero or more of
`poll` (on its interval), `on-event` (store changes it subscribed to, clicks, system events),
and `render(state) → content`. Built-in modules implement this as a Swift protocol; `exec`
implements it by running a process; WASM implements it by exporting functions. One protocol,
three backends.

**Renders are cached.** A module is asked to render only when state it depends on changed
(the store tracks which keys each render read). Hover, animation and the hole never call a
module; the host has the last content tree and animates the styles around it. This is what
keeps idle CPU at zero and keeps a slow WASM module from mattering. A render whose result
changed invalidates style for its item, and the next frame takes it from there (section 10).

## 4. IPC: the socket protocol

Cross-language means: Unix domain socket, newline-delimited JSON. Every language has both.
XPC would be Apple-only and exclude shell scripts; distributed notifications have no reply
channel; Mach ports are out. (The one exception is handing bario a GPU surface, which only a
Mach port can carry; section 9.)

- Path: `$TMPDIR/bario/sock` (per-user, mode 0700 already), overridable with `BARIO_SOCK`.
- Framing: one JSON object per line, UTF-8. Requests may carry an `id`; replies echo it.

Client to bario:

| op | fields | effect |
|---|---|---|
| `set` | `target`, `data` | merge `data` into the store under `target` (`"battery"`, `"weather.temp"`) |
| `content` | `target`, `content`, `classes?` | replace a `data` item's content tree directly |
| `emit` | `name`, `payload?` | broadcast an event to subscribed modules |
| `get` | `target` | reply with the subtree |
| `subscribe` | `topics: ["click:volume", "state:battery.*", "system:wake"]` | bario streams matching events back on this connection |
| `style` | `css` | apply a stylesheet delta live, for iterating on looks |
| `reload` | | re-read config and stylesheet |
| `frame` | `surface`, `index?` | a shared surface's producer drew into one of its pair; show that one, or the other one without `index` (section 9) |

bario to client: `{"id": …, "ok": true, …}` for replies, and `{"event": "click", "target":
"volume", "button": "left", "x": …}` style lines for subscriptions. Connections are cheap;
a one-shot `set` from a shell script opens, writes, closes.

The `bario` CLI is a one-to-one wrapper: `bario set battery '{"pct": 43}'`, `bario content
weather < tree.json`, `bario emit refresh`, `bario get wifi`, `bario watch 'click:*'`,
`bario reload`. That is the whole scripting story, and it is the same story a WASM module
sees from inside (next section), so learning one teaches the other.

Trust: the socket is only reachable by the user. That is the same trust level as the config
file, which can already run commands, so no further auth for v1.

## 5. WASM modules

### Why WASM

The goal is user logic reachable from many languages with one small API, running without
being able to wreck anything. WASM gives the language independence and the sandbox; the API
surface is ours to keep small.

### ABI: core WASM, bytes in, bytes out

Two ways to define the interface: the Component Model with WIT (typed, generated bindings,
the principled future) or a core-wasm bytes ABI in the style of Extism (a module exports
`alloc`, host and guest pass `(ptr, len)` pairs, payloads are JSON).

v1 uses the bytes ABI. Reasons:

- WIT has no recursive types, so the content tree would have to be flattened or serialised
  anyway.
- Component tooling (`wit-bindgen`, `componentize-*`) is a real toolchain burden for someone
  who wants a weather bubble. The bytes ABI is thirty lines in any language and we can ship
  those thirty lines as a PDK for Rust, Zig, Go (TinyGo), AssemblyScript and C.
- Payloads are the same JSON documents the socket carries, validated by the same schema. One
  vocabulary.

Guest exports (all optional except `render`):

```
alloc(len: i32) -> i32               // host asks guest for a buffer
init(ptr, len)                       // config json
poll(ptr, len) -> (ptr, len)         // returns a state patch json, or empty
on_event(ptr, len) -> (ptr, len)     // event json in, state patch out
render(ptr, len) -> (ptr, len)       // state json in, render result json out
draw(ptr, len) -> (ptr, len)         // renderer modules only: {node, frame, style} json in,
                                     //   display list json (or raster descriptor) out
```

Host imports, namespace `bario`, mirroring the socket verbs:

```
log(level, ptr, len)
now() -> i64                          // ms since epoch
set(ptr, len)                         // state patch json, into this item's subtree
get(ptr, len) -> (ptr, len)           // key json in, value json out
emit(ptr, len)                        // event json
subscribe(ptr, len)                   // topic string
set_timer(ms) -> i32                  // next poll in ms; replaces the config interval
request_frame()                       // call draw again in the next frame (section 9)
exec(ptr, len) -> (ptr, len)          // argv json in, {status, stdout, stderr} out  [gated]
read_file(ptr, len) -> (ptr, len)     //                                            [gated]
http(ptr, len) -> (ptr, len)          // {method, url, headers, body}               [gated]
```

Gated imports exist only if the item's config grants them (`permissions "net" "exec"`), and
`fs` grants list paths. A module that asks for nothing can do nothing but compute, which is
the point.

### Runtime

Behind a `WasmEngine` protocol with two candidate implementations:

- **WasmKit** (swiftwasm/WasmKit): pure Swift, a SwiftPM dependency, interpreter. Zero
  build friction. Start here; widget code is tiny and an interpreter is plenty.
- **wasmtime** via its C API: JIT, fuel metering and epoch interruption for hard time limits.
  Switch if profiling says so, or if WasmKit cannot give us a reliable way to abort a
  runaway module.

Each module instance runs on its own actor with a per-call budget (50ms for `render`, more
for `poll`). Over budget: the call is abandoned, the item shows its last content plus a
`.stale` class, and the module is restarted after backoff. A module cannot take the bar down.

Memory: 16MB default linear memory cap per instance. Modules are instantiated once and live
for the config's lifetime; `reload` reinstantiates.

### Where the tiers meet

An external process and a WASM module use the same verbs (`set`, `emit`, `subscribe`, …). A
WASM module is just a provider that happens to run in-process, sandboxed, with a `render`
hook. This is deliberate: a bubble prototyped as a shell script and `bario set` can be
promoted to a WASM module without changing the item's config or styling.

## 6. Layout

The bar is one horizontal flex row. Items are laid out in config order, with `spacer` items
absorbing free space. `left / center / right` is not a concept; it is `[a b spacer c spacer d]`,
and it falls out of the general case:

```kdl
bar {
  item "app" module="front-app"
  spacer
  item "clock" module="clock"
  spacer
  group "status" { item "wifi" module="wifi"; item "battery" module="battery" }
}
```

Per item in the config: `grow` (flex-grow, 0 by default; a `spacer` is an empty item with
`grow=1`), `shrink`, `priority`, and `align` on groups, which are rows. Sizes are the
stylesheet's (section 7): `width` (fixed), `min-width`, `max-width` on items, and `padding` and
`gap` on the bar and groups.

Measurement: text via CoreText, icons at the font's point size, meters and graphs at their
declared width. An item's natural width is its content plus padding plus border. Then a
single flex pass distributes free space to `grow` and takes it from `shrink`.

**Overflow** is real on menu bars. When the natural widths do not fit, items are hidden
lowest `priority` first (default priority 0; the `front-app` name and the clock ship with
higher defaults) until the rest fits. Hidden items get a `.overflow` class and are still
rendered in the state store, so a `▸` catch-all item can list them later.

### The notch

On a notched display the bar has a hard obstacle in the middle. `NSScreen` says exactly
where: `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` are the two usable rects and the gap
between them is the notch; `safeAreaInsets.top` is its height.

Layout treats the notch as an exclusion interval. The bar is split into two sub-rows, left
and right of the notch, and each is laid out as its own flex row. Which items go where:

- If the config contains an explicit `notch` marker, the split is there. This is the
  predictable option and the docs recommend it.
- Otherwise the split is automatic: items fill from the left; the first item whose natural
  end would cross the notch starts the right sub-row. A `spacer` straddling the notch becomes
  a spacer on each side, which is what makes `[a spacer clock spacer b]` degrade to `clock`
  hugging the notch instead of vanishing under it.

Both sub-rows use the same styles, gap and padding. On a display without a notch the `notch`
marker is ignored and the row is one flex pass, so one config serves the MacBook and the
external monitor. `bar { notch "ignore" }` opts out of avoidance entirely.

### Modes

A bar can change its arrangement, not just its looks. A **mode** is a named condition over the
state store and time, declared once:

```kdl
mode "guide" {
  while "emira.moving"                    // on while this path is truthy
  changed "emira.focus" "emira.displays"  // on when either changes value
  hold "700ms"                            // and for this long after the last reason
}
```

While it is on, the bar wears it as a class (`bar.guide #clock { … }`), and items, groups and
spacers can be shown `when="guide"` or `unless="guide"`. So a mode can take a stretch of the
bar over, Dynamic Island fashion: the app name gives way to a row of window names, centred by
a spacer that exists only in that mode, while everything else stays where it was.

```kdl
item "app" module="front-app" format="{name}" unless="guide"
spacer when="guide"
item "names" module="exec" interval="watch" when="guide" { command "…" }
spacer
notch
```

`when` decides only whether an item is laid out. Its module runs either way, so an item a mode
brings in has its content the moment it appears. A path's first value is not a change, so
starting up turns nothing on. Items that stay in both arrangements slide to their new places;
the ones that come and go transition in and out (section 7). Modes are the same on every bar.

### Multiple displays

One config, one bar per display. `bar` can be filtered: `bar display="built-in" { … }`,
`bar display="external" { … }`, or `bar display="DELL U2723QE"`, most specific wins. The
bar's height defaults to that display's menu bar height (24pt normally, ~37pt on a notched
MacBook); items align to `bar { align "center" }` within it.

## 7. Appearance

Structure lives in `~/.config/bario/config.kdl`, looks live in `~/.config/bario/style.css`.
Two files, like waybar, because the audience knows CSS and a config language is a bad place
to write a stylesheet. `~/Library/Application Support/bario/` is checked second.

### The style language

A CSS subset, parsed by us. Not a browser engine: no flow properties in the stylesheet (what
is on the bar, in what order, and how it grows and shrinks is config), a fixed property list,
and a fixed selector grammar.

The line between the files: the config says what the bar holds and how it behaves; every
length that is about looks (padding, gap, widths, radii) is the stylesheet's, and only the
stylesheet's. A size in the config would win over the cascade and so switch off exactly what
the stylesheet is for: `transition`, `:hover`, `@media`, a theme. So `bar { padding 0 8 }` in
the config is an error that names the rule to write in `style.css` instead.

To be precise about what "supporting CSS" means, since there is no engine to borrow: the bar
is Swift and AppKit, composited by Core Animation and drawn with CoreGraphics and CoreText
(section 10), and the stylesheet is a
familiar syntax for a theming system we write ourselves. waybar's CSS is GTK's own
stylesheet engine, not a browser, and this is the same arrangement. The pieces, all Swift:

- a tokenizer and parser for the subset: rules, selector lists, declarations, `var()`,
  `@media`, `@keyframes`, comments. A few hundred lines, because anything outside the grammar is an error
  with a line number rather than something to approximate;
- selector matching against the scene tree, with standard specificity;
- typed value parsers per property, so `padding: 2pt 9pt` becomes edge insets, `font:`
  becomes a font descriptor, and `background: backdrop blur(20pt)` becomes an enum case;
- a cascade that resolves every node to one `Style` struct, and an interpolator over the
  animatable properties so `transition` works.

Two to three thousand lines, and the most self-contained part of the project. The
alternatives fit worse. A `WKWebView` on the cover would give real CSS but the hole has to
composite over our own pixels, and a web process at menu bar level is a lot of machinery for
a dozen bubbles. Rust crates such as `lightningcss` or `taffy` over FFI would parse and lay
out a general stylesheet we do not need, for a fixed property set we would still have to map
by hand. So: CSS the syntax, for theming; config for structure; no `display`, `position` or
their friends.

Selectors: type (`bar`, `item`, `group`, `text`, `icon`, `meter`, `graph`, `canvas`, and any
registered custom node type), `#id`, `.class`, state pseudo-classes (`:hover`, `:active`,
`:overflow`, `:stale`, `:leaving`; the first two only while Option is held, section 8), the
modes that are on as classes on `bar`, descendant combinator (`#battery .pct`), and lists. Specificity follows CSS. Cascade order is the stylesheet, then
per-item `style="…"` in config for one-offs.

Properties:

| group | properties |
|---|---|
| box | `padding`, `margin`, `gap`, `border` (width, color), `border-radius` (per corner), `width`, `min-width`, `max-width`, `opacity` |
| background | `background`: a colour, a gradient, `backdrop` (the captured desktop, i.e. an invisible bar) or `backdrop blur(20pt) saturate(1.2)` |
| text | `font` (family, size, weight, e.g. `12pt "SF Pro Text" medium`, `system-ui`, `monospace`), `color`, `font-weight`, `letter-spacing`, `text-transform` |
| icon | `icon-size`, `icon-color`, `icon-weight` (SF Symbol weight), `icon-rendering` (`monochrome`, `hierarchical`, `palette`, `multicolor`) |
| meter/graph | `fill`, `track`, `stroke-width`, `line-cap` |
| effects | `shadow` (offset, blur, colour), `transform` (translate, rotate, scale, turns in depth, perspective), `transition` (property, duration, easing), `animation` (`@keyframes` over `transform` and `opacity`) |

Values: `pt` lengths; colours as hex, `rgba()`, `hsl()`, `system(labelColor)` for any
`NSColor` system colour, `accent` for the user's accent colour; variables via `--name` on
`:root` and `var(--name)`; `@media (prefers-color-scheme: dark)` follows the system
appearance and re-cascades when it changes.

`transition` is the point of the whole exercise. The probe feels good because everything
eases; bubbles should get the same for free. Colours, opacity, padding, radius, shadow,
`transform` and `icon-size` are animatable. Layout changes (an item's width changing when its
text does) animate too, with a bar-level `bar { transition: layout 160ms ease-out }`.

`animation` is for motion that loops, like a spinner. It is limited to `transform` and
`opacity` so that the compositor can run it without bario (section 9):

```css
@keyframes spin  { to { transform: rotate(360deg) } }
@keyframes pulse { from, to { opacity: 1 } 50% { opacity: 0.4 } }
#sync icon { animation: spin 1s linear infinite; }
#ci.running { animation: pulse 1.2s ease-in-out infinite alternate; }
```

`animation` takes a name, a duration, then in any order an easing, a delay, an iteration count
or `infinite`, and `alternate`, and a list of them separated by commas. `transform` takes
`translate(x[, y])` or `translateX()` and `translateY()`, `rotate(angle)` in `deg` or `turn`,
`rotateX()` and `rotateY()`, which tip the top or the right away from the viewer,
`perspective(distance)`, and `scale(s)` or `scale(x, y)`, each at most once; whatever order they
are written in, they apply as scale, then the rotations, then perspective, then translate,
about the centre of the box, which is also how they ease. A box turned out of the bar's plane
is drawn in front of its neighbours rather than cut by them. A keyframe that leaves a
property out takes the element's own value there. `backdrop blur()` and `saturate()` snap
rather than ease: every distinct value is a filter pass and a cached image.

Layout transitions follow three rules. An item that appears, including one receiving its
first content, is placed where it belongs rather than grown out of nothing; its neighbours
still slide to make room, and it can transition in (below). The items in a group follow their own rectangles, which already
include the group's movement. And while a bubble resizes, its content keeps the size it was
measured at, stays centred in the bubble, and is clipped to it, so a bubble that is growing
never paints its new content across the neighbours it has not reached yet.

### Arriving and leaving

An item comes and goes whenever a mode, its module or `hidden-until-set` says so, and the
stylesheet says how, in CSS's own terms. `@starting-style` is what an item that has just
appeared transitions from. `:leaving` is what an item that has just left transitions to: it
stays on screen where it was, in the layer it had, taking no space and no clicks, until that
transition ends, and one that comes back before then turns round from where it has got to. An
item with neither snaps, as before. A group goes as one. A roll, as on a drum:

```css
#app, #names { transition: transform 280ms ease-in-out, opacity 220ms ease-in; }
@starting-style {
  #app, #names { transform: perspective(40pt) translateY(20pt) rotateX(-90deg); opacity: 0; }
}
#app:leaving, #names:leaving {
  transform: perspective(40pt) translateY(-20pt) rotateX(90deg); opacity: 0;
}
```

Both are transitions, run by the frame loop like any other, so they retarget from what is on
screen; a Core Animation `animation` could not turn round mid-way. Neither draws anything:
the layers keep their pixels and move.

An example that reads as a finished bar:

```css
:root {
  --fg: system(labelColor);
  --bubble: rgba(255, 255, 255, 0.14);
}
bar   { background: backdrop; font: 12pt "SF Pro Text" medium; color: var(--fg); padding: 0 8pt; }
item  { padding: 2pt 9pt; border-radius: 8pt; background: var(--bubble);
        transition: background 120ms ease-out, opacity 120ms; }
item:hover { background: rgba(255, 255, 255, 0.24); }
group#status { gap: 2pt; background: none; }
group#status item { border-radius: 0; }
group#status item:first-child { border-radius: 8pt 0 0 8pt; }
group#status item:last-child  { border-radius: 0 8pt 8pt 0; }
#battery.low       { background: rgba(255, 70, 70, 0.35); }
#battery.charging .ico { color: system(systemGreenColor); }
#clock { font-weight: semibold; }
@media (prefers-color-scheme: dark) { :root { --bubble: rgba(0, 0, 0, 0.30); } }
```

### Background and the backdrop

`backdrop` is the probe's photograph and it is the foundation of the illusion: the wallpaper
and the shading macOS lays under the menu bar. It is taken when something says either might
have changed — a display, a space, the appearance, waking, a new wallpaper — again each second
while it keeps changing, and on a slow timer for wallpapers that change on their own.
`backdrop blur()` is done by us with a `CIFilter` on the captured strip, once per capture, not per frame.
`NSVisualEffectView` is not an option because what is behind our window is the real menu
bar, not the desktop.

The photograph is the desktop and nothing else, because **the shadows windows cast up into the
strip cannot be photographed**: ScreenCaptureKit renders no window shadow at all in a display
filter, whatever `capturesShadowsOnly` is set to. The cover would erase them anyway, being
opaque over a strip the system draws as transparent — and a window near the top of the screen
casts a shadow that reaches well into the bar, so the bar would end in a hard edge exactly where
the gradient below it carries on. So bario casts them itself, from the window server's list of
what is on screen, as Core Animation shadows over the photograph. One measured Gaussian per
window — a different one for the key window, which casts far wider — fitted to the real screen
above a window's top edge and beside it at once, and verified back against it to under one level
of 8-bit grey; `contrast: auto` reads the same field, so an item over the
dark band under a window picks the ink it actually needs. See
[19-window-shadows.md](.agents/knowledge/19-window-shadows.md).

Both the bar and any item can use `backdrop`, so a translucent bubble on an invisible bar is
one line. It costs no drawing either: the capture is one layer's contents, and each item with
`background: backdrop` shows its own slice of the same image (section 10).

The capture must never contain bario itself. If it does, the bar is painted over a
photograph of its own earlier self, and every layout change leaves ghosts of old bubbles
behind. So the capture's content filter includes only windows below normal window level, the
desktop, rather than excluding bario's: an exclusion list has to know every cover, including
one waiting off screen for its first frame (section 10), and a filter that includes the
desktop has nothing of bario's to miss. It also keeps out an app window moved up under the
menu bar, which ScreenCaptureKit composites though the screen does not show it. A new capture invalidates commit for its bar; one identical to the last is not
new, and invalidates nothing.

## 8. The hole, and holding Option

The hole is a lens onto the real menu bar, and it cuts through everything bario paints: the
bar's background and every bubble on it alike. Bubbles are part of the cover, and the lens
shows the real bar through them. Apart from the hole, the bar does not react to the pointer at
all: nothing hovers, nothing gets out of the way, and every click falls through to the real
menu bar underneath. A bar you are peeking through should be as inert as the photograph it is.

(An earlier version let each item choose what the hole did to it: `hole: keep` painted it over
the lens, and `hole: dodge` faded it out of the way. Both made the bar respond to a pointer that
was aimed at the real menu bar, and an item that glows under the pointer reads as clickable
when it is not. Both are gone.)

Holding **Option** over a bar is how you use bario itself. While Option is held with the
pointer on a bar, that bar:

- eases its hole shut, so what you see is what you click;
- takes the pointer's clicks, scrolls and hover: items match `:hover` and `:active`, and their
  `on-click` and `on-scroll` shortcuts run;
- still does not activate bario. The cover is a non-activating panel, so the app you were in
  keeps focus and its menu bar.

Let go of Option, or move off the bar, and it is a lens again.

The hole's geometry keeps its probe knobs, moved into config:
`bar { hole radius=40 feather=0 proximity=80 click="reveal" }`. `click="reveal"` is the probe's
latch: a click that falls through a bar uncovers all of it until the pointer leaves, so the
menu you opened is usable.

### Mouse events

The cover ignores mouse events except while Option is held over it. The first plan was to take
events everywhere and let the window server pass clicks on transparent pixels, such as the
hole, down to the window beneath. Measured on macOS 27, it does not: a click on a fully
transparent pixel of the cover still reaches the cover. So `ignoresMouseEvents` is switched,
and Option is what switches it.

Option is noticed three ways, because each alone misses a case. Pointer events carry the
modifier state. A global `flagsChanged` monitor sees it change at once, but only with
Accessibility permission. And while the pointer rests on a bar, and only then, the modifier
state is read a few times a second, which is what makes pressing or letting go of Option over
a still pointer work without that permission. A CGEventTap would avoid the polling but needs
Input Monitoring permission. Not for v1.

Item events go to the module as `on-event` (`click`, `right-click`, `scroll`) and to socket
subscribers. Config shortcuts cover the common cases without a module:
`on-click="exec 'open -a Activity\ Monitor'"`, `on-scroll="volume adjust"`.

Popovers (a calendar under the clock, a slider under volume) are a second window anchored
to the item's frame. Deferred past v1, but the content model is the same tree, so nothing
has to change to allow them.

## 9. Custom renderers

`text`, `icon`, `meter` and `graph` are the built-in vocabulary, not the whole one. A bar
without an escape hatch would push everyone with an unusual bubble back to `exec` and a
PNG, so BYO rendering is a first-class path. Three levels, cheapest first, and they stack.

One rule holds for all three: **plugins describe; the host rasterizes and composites.** A
plugin hands over data, a display list or finished pixels, and never touches the screen. The
host decides when anything is drawn, caches what it draws, and gives every custom node a layer
of its own (section 10). A plugin's cost is then its own: redrawing one ring leaves the rest of
the bar alone, and the pointer moving over it redraws nothing at all.

### Level 1: the `canvas` node

A render result may contain a `canvas` node carrying a display list:

```json
{ "canvas": { "width": 28, "ops": [
    { "stroke": { "color": "var(--track)", "width": 3 },
      "path": [["arc", 14, 12, 9, 0, 360]] },
    { "stroke": { "color": "currentColor", "width": 3, "cap": "round" },
      "path": [["arc", 14, 12, 9, -90, 162]] },
    { "text": "70", "at": [14, 12], "align": "center", "font": "9pt monospace" }
] } }
```

The op set is small and vector: `move`, `line`, `curve`, `arc`, `close`, `rect`,
`round-rect`, `fill`, `stroke`, `text`, `image` (SF Symbol or file), `clip`, `transform`,
`opacity`, `group`. The host rasterizes it with CoreGraphics into the node's own layer, at the
display's scale, so it is resolution independent and Retina is free. Coordinates are points,
origin top-left of the node's frame, `height` defaults to the bar's content height.

Because a display list is data, it moves through every channel the content tree already
uses: JSON over the socket, JSON bytes through WASM memory, a Swift value from a built-in.
A shell script can `bario content ring < ring.json`; a Rust module can build the same list
with a PDK helper. It validates against the same schema, and its ops are part of the node's
raster key (section 10): a canvas that has not changed is never drawn again, however much
moves around it.

### Level 2: renderer modules that register node types

A WASM module can declare, in its config, that it renders a node type:

```kdl
renderer "ring" path="~/.config/bario/renderers/ring.wasm"
```

From then on any content tree from any module may use `{ "ring": { "value": 0.7 } }`. The
renderer's `draw` is called by the two stages that need it. Layout calls it with
`measure: true` to learn the node's natural size. Commit calls it with the node's final frame
for the drawing itself, a display list or (level 3) a raster descriptor. It does so only when
the node's payload, style or size changed, or when the renderer asked to be drawn again, and
what it returns keys the node's raster just as a canvas's ops do. Content modules stay declarative and stylable;
the vocabulary grows by dropping a `.wasm` in a directory; a good renderer is one file to
share. Built-in nodes could be reimplemented this way, which is a decent test that the
interface is complete.

Renderers are ordinary modules with ordinary permissions, which for a renderer is usually
none.

### Level 3: pixel buffers

For someone compiling their own rasterizer to WASM, or an external process drawing with
Metal, a `raster` node hands the host finished pixels, and they become the node's layer
contents as they are. The host says the size in points and the scale; the pixels are
premultiplied BGRA at that size, from one of:

| source | cost of a new frame |
|---|---|
| `{"png": …}` inline bytes, `{"path": …}` a file | decoded once, cached by source |
| `{"ptr": …, "len": …}` in the module's WASM memory | one copy of the node's pixels |
| `{"shm": "/name"}`, a shared memory object reused frame to frame | one copy of the node's pixels |
| `{"surface": "name"}`, a pair of IOSurfaces shared by a native process | nothing |

A copy is of one node, never the bar, so a live raster is affordable: the pixels become that
node's layer contents, and nothing else on the bar is drawn again.

The surface is the one source that needs more than the socket (section 4). An IOSurface crosses
processes only as a Mach port, so a native process hands bario a pair of them once, under a
name, in a Mach message to a port bario publishes in the login session; the name stays that
process's while it runs, and its surfaces go when it does. From then on it draws each frame
with Metal into the surface not showing and sends `frame` with that name over the socket, and
bario makes that surface the node's layer contents: the window server composites memory the
GPU already holds. A pair, because a layer shows new pixels only in a surface it is not already
showing. `SurfaceProducer` in BarioKit is the producing side for Swift, and
`examples/surface` draws a wave with it.

### Motion without frames

Nothing redraws by itself, and motion comes two ways.

A drawing that changes shape, a waveform or a graph that scrolls, calls `request_frame()`
while it draws. Commit calls that node's `draw` again in the next frame, at the display's
refresh rate and under the same time budget as everything else, and rasterizes that node
alone, for as long as it keeps asking. A renderer that overruns keeps its last frame and a
`.stale` class; the bar does not stutter.

A drawing that only moves, a spinner turning or a dot pulsing, says so instead and costs
nothing per frame. `transform` and `opacity` are style properties of every node, and
`animation` runs `@keyframes` over them (section 7). Those become Core Animation animations,
which the window server samples against the same clock the frame loop reads: `draw` is called
once, and bario sleeps while the spinner spins. The restriction is what makes it safe. Only
properties that change neither layout nor hit testing may animate this way, which is why
`transition`, which can move a bubble, stays the frame loop's (section 10).

### What makes them feel native

- **Theming reaches them.** `draw` receives the node's resolved style: `color`, `font`,
  `opacity`, the accent, and every custom property that cascaded to it. A renderer we never
  wrote is themed with `#ring { --ring-width: 3pt; color: accent }`, and `currentColor` and
  `var(--x)` inside a display list resolve against that same style. Level 1 canvases from an
  external process get the same treatment.
- **A plugin's cost is its own.** Every canvas, custom node and raster is a layer with its own
  raster key. Nothing a plugin drew is drawn again because the pointer moved, a neighbour
  changed or a bubble slid.
- **Hit testing is the node's rect.** Clicks, scrolls and hover arrive as events with
  coordinates relative to the node, to the owning module and to socket subscribers.
- **The hole still works.** A plugin's layer sits under the same mask as everything else, so
  the hole cuts through it like any other bubble.

### Non-goal: external windows

An external process drawing its own window into a slot bario reserves is not supported.
macOS cannot reparent windows across processes, and the hole could not cut through a window
it does not own. A shared surface (level 3) is the way in instead: the pixels are the process's,
the layer is bario's, and the hole cuts through it.

## 10. Rendering

Rendering is two problems: *when* a bar changes, and what that costs. The first is the frame
loop, and it has held up. The second is where the first version went wrong.

That version kept the probe's pipeline: one layer-backed `NSView` per display, drawing the
whole bar with CoreGraphics in `draw(_:)`, with the hole as a final `destinationOut` pass. It
was simple and correct, but its cost did not follow what changed. Measured on a 120Hz display
in September 2026, moving the pointer over the bar redrew all of it at the pointer's rate.
Nearly half the main thread's work went to rasterizing the same three SF Symbols again, and
much of the rest to recording the bar for Core Animation to replay on the GPU while the main
thread waited. A frame cost as much as the most expensive thing on the bar, paid at the rate
of the fastest-changing thing: the hole. Caches would have lowered that constant and kept the
shape.

### Describe, rasterize, composite

A browser does not repaint a page to scroll it, and bario should not redraw a bar to move a
hole. The work splits three ways, and each part is done at its own rate:

| work | where | redone when |
|---|---|---|
| **describe** | render, style, layout and present (below) | something is invalidated |
| **rasterize** | per node, on the main actor, with CoreText, CoreGraphics and SF Symbols, into the node's own layer | that node's pixels change |
| **composite** | the window server, on the GPU | every displayed frame, at no cost to bario |

macOS already has the compositor: Core Animation. Each bar is a tree of layers that mirrors its
scene, and a frame's last stage, **commit**, brings the tree up to date. The cover's view hosts
that tree and never draws.

The alternatives, and why not:

- **The immediate-mode painter, with caches in front of it.** Cheaper frames of the same shape:
  a moving hole still redraws every bubble.
- **A renderer of our own on Metal**: one `CAMetalLayer`, signed-distance chrome, glyph
  atlases. Full control, but text quality, symbol atlases, path tessellation for display lists
  and colour management would all be ours, and bario would encode a GPU frame whenever anything
  moved. A bar is mostly still content under compositor-level motion, which is what Core
  Animation is for, and it brings CoreText and SF Symbols at system quality. Revisit only for
  an effect Core Animation cannot do.
- **SwiftUI** would give text and symbols for free, but fights the window-level tricks and gives
  up control of exactly when anything changes.

Above the layer tree, rendering is retained-mode too, and everything below follows from one
rule: **inputs only invalidate, and a frame does all the work.**

### Stages

A frame runs five stages in order. Each stage's output is a function of the previous stage's
output and its own inputs, and nothing else:

| stage | produces | its own inputs |
|---|---|---|
| **render** | each item's content tree | the state the render read (section 3) |
| **style** | a resolved `Style` for every item and node | stylesheet, live `style` deltas, appearance, item classes and states (`:hover`, `:stale`, …) |
| **layout** | a rectangle for every item and node: the **scene** | display geometry, the notch, text and symbol measurement, renderers' `measure` |
| **present** | the scene as it looks at the frame's timestamp, with the hole | transitions and when each started; the pointer and Option, and how far the click reveal and the hole's closing have eased |
| **commit** | the bar's layer tree: layer properties, and a fresh raster for each node whose raster key changed | the backdrop, colours resolved for the current appearance, the display's scale, renderers' `draw` |

Render is the only asynchronous stage. It runs on the module's actor under its budget
(section 5), and a frame never waits for it. The other four run on the main actor.

An item that has never rendered takes no part in the stages after render: it has nothing to
show, and a placeholder is exactly what the first frame (below) exists to avoid. An item that
rendered and had nothing to show is different; it is there, and it is `:empty`.

Style and layout are separate stages so that layout can run without re-cascading: a display
changing size, or its menu bar showing, is geometry and not style. The one input that crosses
back is `:overflow`: only layout knows which items did not fit, so it restyles those, and only
those, before setting them aside.

### The layer tree

```
bar            opacity = 1 − reveal; mask = the hole
├─ backdrop    contents = the capture
└─ item        frame, opacity, background colour, border, corner radii, shadow;
   │           clips what is inside it to its rounded rect
   ├─ backdrop the capture again, through contentsRect: this item's slice of it
   ├─ node     a leaf: its raster, or its raster as a mask tinted by a colour
   └─ item     a group's children, and so on down
```

An item's layer is identified by the item's name, and a node's by its path within the item's
content, or its `id` where it has one. The same identity in the next scene is the same layer,
updated in place, so neither a re-render nor a transition throws pixels away. A new identity
is a new layer, placed where it belongs, as section 7 says an appearing item is.

Every style property lands in exactly one of two places, layer properties or a raster, and
this table is the rule that is easiest to break:

| style | becomes |
|---|---|
| an item's frame, `opacity`, `margin`, a colour `background`, `border`, `border-radius`, `shadow`, `transform` | layer properties; no pixels |
| `background: <gradient>` | a gradient layer |
| `background: backdrop` | the capture, through `contentsRect`; its `blur()` and `saturate()` variants are made once per capture |
| `color` and `icon-color`, on text and monochrome symbols | the tint of a mask, so a colour transition draws nothing; `contrast` resolves to a colour and tints the same way |
| a meter's `value`, `fill` and `track` | two layers; the value is a width |
| text, `font`, `letter-spacing` and `text-transform`; an icon's name, size, weight and non-monochrome rendering; a graph's values; a canvas's ops; a renderer's drawing; a raster's pixels | the node's **raster key** |

Core Animation takes one corner radius per layer, and a set of corners to apply it to. That
covers `8pt 0 0 8pt`; corners with different non-zero radii need a shape mask. Opacity below 1
still fades a group and everything in it as one image, as it did when the bar was painted.

### The raster key

A node's raster is a function of its raster key: the node's kind and payload (a display list or
pixels by a hash of their bytes), the raster rows of its resolved style, the display's scale
and the appearance. Commit computes the key of every node on a bar it commits, and redraws only
the nodes whose key changed. Text and monochrome symbols are rasterized as coverage alone, so
no colour is in their key.

This is how partial redraw comes back without the dirty regions the first version rejected
(below). Nothing hands in what changed: the key is everything that could, computed by the
frame. A stale pixel then means an input missing from the key, which a test of the key can
catch, rather than a region some caller forgot to report.

### The hole

The hole is the bar's mask, in three parts:

- the **lens**: a square layer two radii across, opaque but for a clear circle with the feather
  at its edge, rendered once per radius, feather and scale, and centred on the pointer;
- four opaque **bands** that fill the bar around the lens;
- the **strength**: one opaque layer over the whole bar, at opacity `1 − strength`.

Where the lens is clear by `h` and the strength is `s`, the mask's alpha is
`(1 − s) + (1 − h)·s = 1 − s·h`, exactly
what the `destinationOut` pass cut. Moving the hole sets six properties and draws nothing: a
spike measured it at about 5µs, with the feather and half strength coming out right.
Everything bario shows is under the mask, every plugin's layer included, so the hole still cuts
through all of it. The click reveal is the bar's opacity.

### Commit

For each bar a frame touches, commit is one Core Animation transaction with implicit animations
turned off:

1. reconcile the tree with the presented scene, creating, reusing and removing layers by
   identity;
2. set every layer's properties from the presented scene, the hole and the reveal;
3. call `draw` for each custom node whose draw inputs changed, or whose renderer asked for a
   frame (section 9);
4. compute raster keys, and redraw the nodes whose key changed.

The animator stays the truth about motion. While a transition runs, each frame sets the
presented values, which is property changes and no pixels. Core Animation's own animations are
for `animation` alone (section 9), where nothing reads the animated value back.

### Invalidation

Anything that can change what a bar looks like says so with one call, naming the earliest
stage it affects; every later stage is implied. Invalidating does no work. It records what
is dirty, and for which bar if it concerns only one, and asks for a frame.

| input | invalidates |
|---|---|
| a store write that changes a value some render read | render, for the items that read it |
| a render returning different content, classes, visibility or staleness | style, for that item |
| the pointer entering or leaving an item, a press, both only while Option is held | style, for that bar |
| Option pressed or let go | style, for the bar under the pointer; present, if a hole is showing |
| a stylesheet reload, a socket `style` delta, an appearance or accent colour change | style, everywhere |
| a mode turning on or off | style, everywhere |
| a config reload | render, for items whose module or options changed; style, everywhere |
| a display added, removed or resized; the menu bar hiding or showing | layout, for that bar |
| the pointer moving near a bar, a click that latches the reveal | present |
| a renderer calling `request_frame()`, a shared surface's `frame` | commit, for that node |
| a new backdrop capture, the first-frame deadline | commit, for that bar |

Nothing but the frame builds a scene, starts a transition or touches a layer. That is the
guarantee the rest of the design leans on: a new kind of input is one more row in this table,
never a new route to the screen that has to remember to start the display link.

### The frame

Invalidations coalesce. The first one in a run-loop turn schedules a frame for the end of
that turn, the same point at which AppKit settles `needsLayout`, so a burst of store writes,
or a hover that also changes a class, is one frame. (Concretely, a run-loop observer ordered
just ahead of Core Animation's own commit, so a frame's changes reach the screen in the same
pass.) While frames are coming from the display link anyway, an invalidation waits for the next
one instead of adding a frame of its own. A frame:

1. **Renders.** It starts a render for every item whose render is dirty. An item that is
   already rendering stays dirty and renders again when the current render finishes, so a
   write that lands mid-render is never lost. That includes a write to something the render
   is reading for the first time, which no earlier render could have recorded: when a render
   reports what it read, the store checks it against everything written since the render's
   snapshot. A finished render invalidates style for its item, which schedules the next
   frame.
2. **Styles and lays out.** If anything is style- or layout-dirty, it re-cascades and lays
   out the affected bars and gives each new scene to that bar's animator as its target. A bar
   that is not on screen has nothing on screen to ease from, so its animator takes the scene
   as it is.
3. **Presents.** It samples every animator, and the hole, at the frame's timestamp.
4. **Commits.** Every bar with anything dirty or anything moving is committed (above), and a
   bar whose first frame this was is ordered in.
5. **Continues or stops.** If a transition or the reveal is still moving, or the frame
   invalidated something itself (a renderer asking to be drawn again, hover changing under a
   pointer standing still), it asks for the next frame, which comes from the display link at
   the display's native rate. No frame can feed the next one faster than the display shows
   them. Otherwise it asks for nothing, the link stops, and an idle bar does no work at all.

Frames have to arrive whether or not a bar is on screen, because a bar waits off screen for
its first frame. So the display link belongs to a screen, the fastest one
(`NSScreen.displayLink(target:selector:)`), and not to any bar's view.

### What is on screen is a function of time

The presented scene is never stored as the truth. An animator holds its target scene and
when each transition started, and asking it about `now` gives what should be on screen. That
keeps three things simple:

- a transition progresses because frames keep coming while it is active, never because
  something else happened to cause a redraw;
- retargeting mid-transition eases from what is on screen, because that is exactly what the
  animator reports;
- animation is frame-rate independent by construction: progress is read off the clock, not
  accumulated per tick.

The hole works the same way. Where the pointer is says where the hole is and how strongly it
cuts; how far the click reveal has got, and how far the hole has closed for Option, are sampled
at the frame's timestamp. A hole too far from the pointer to show does not ease at all, so
Option pressed anywhere else starts no frames.

Hit testing reads the presented scene, because that is what the pointer is over, less the
items on their way out. Which bar
Option has made interactive, and which of its items is hovered, are decided when the pointer
moves or Option changes, and again after each frame, since a sliding item can arrive under a
pointer that is standing still, or leave it.

### What a frame costs

The first version redrew each bar a frame touched in full, and rejected per-item dirty regions:
a correct region has to account for every paint input, and one reported by whichever code made
a change will miss an input sooner or later and leave stale pixels behind. It named the
condition for bringing regions back: computed by the frame from the difference between two
presented scenes plus the other paint inputs, never handed in by the code that changed
something. Layers and raster keys meet that condition per node rather than per rectangle, so a
frame costs what changed:

| what happened | the work |
|---|---|
| the pointer moved near a bar | six properties on the hole |
| the clock ticked | one text node rasterized |
| a hover transition | layer properties each frame; a monochrome colour is a tint |
| a layout transition | positions and sizes each frame; content keeps its pixels |
| a new capture | the backdrop's contents; `contrast: auto` retints |
| a spinner turns | nothing: the window server runs it |
| a renderer animates | its `draw` and its node's raster, each frame |
| nothing | nothing |

A bar that is not committed costs nothing, so a pointer moving over one display still leaves
the bar on another alone.

### The first frame

A bar is not put on screen until it has something finished to show. Anything earlier is
placeholders drawn over the real menu bar.

- A module's first render waits for state to show: its first poll to land, or anything to
  be written under its key, for at most 250ms from when it was loaded. Modules start
  independently, so one slow to start holds up nothing but itself. This holds at startup and for a module a reload
  restarts, so no first render is an empty slot, and a restarted module's item keeps showing
  what it showed until its new render arrives.
- A bar, whether it exists from startup or appears with a new display, is ordered in with a
  short cross-fade after its first frame in which every item has rendered once (or failed,
  or run out of budget) and a backdrop exists.
- After one second it is ordered in regardless, showing what it has. A capture that has not
  come back is stood in for by a rendering of the wallpaper file, unless `--source capture`
  asked for captures only.

### Offscreen, and testing

`--shot` and the pixel tests render the same layer tree offscreen, with `CARenderer` into a
Metal texture: one renderer, not a painter for files and a layer tree for the screen. The
texture is cleared before each render, because `CARenderer` composites over whatever the
texture already holds.

The frame loop is tested headlessly, with an injected clock and an injected frame scheduler,
against the rules above rather than against particular symptoms:

- any number of invalidations in one run-loop turn produce exactly one frame;
- frames continue while any transition, hole easing or `request_frame()` is active, and stop
  when none is;
- a render invalidated while it is in flight runs again afterwards;
- a bar is ordered in only after a frame that meets the first-frame rule, or at the deadline;
- a pointer move rasterizes nothing, and neither does a colour transition on text;
- a node whose raster key did not change is not redrawn, and changing any input to the key
  redraws it.

## 11. Config

KDL for structure. It nests, it has properties and children, and a bar is a tree. TOML is the
fallback if the KDL parser situation in Swift turns out worse than expected.

```kdl
// ~/.config/bario/config.kdl
bar {
  hole radius=40 feather=0 proximity=80 click="reveal"

  item "app" module="front-app" priority=10 format="{name}"
  item "spaces" module="exec" interval="watch" {
    command "aerospace" "list-workspaces" "--monitor" "focused" "--format" "%{workspace}"
  }
  spacer
  notch
  spacer
  item "clock" module="clock" format="EEE d MMM  HH:mm" priority=10
  group "status" {
    item "wifi" module="wifi" format="{icon}"
    item "battery" module="battery" format="{icon} {pct}%" {
      low 20
    }
    item "volume" module="volume" format="{icon}" on-scroll="adjust" on-click="toggle-mute"
  }
  item "weather" module="wasm" path="~/.config/bario/modules/weather.wasm" interval="10m" {
    permissions "net"
    config city="Vancouver" units="metric"
  }
  item "ci" module="data" format="{icon} {status}" hidden-until-set=true
}

renderer "ring" path="~/.config/bario/renderers/ring.wasm"
```

The last item is populated from outside: `bario set ci '{"icon": "checkmark.circle",
"status": "green"}'` from a cron job or a CI webhook listener, with no module at all.

Content that is known when the config is written goes in the config, as KDL nodes that mirror
the JSON content tree (section 2) and pass through the same decoder: a node's name is its kind,
one argument is its value, properties and child nodes are its fields, and a row's child nodes
are its children. A `text` item shows it; a `data` item shows it until something is pushed.

```kdl
item "battery-ish" module="text" {
  content {
    row gap=4 { icon "battery.75percent" class="ico"; text "73%"; meter value=0.73 width=24 }
  }
}
item "wave" module="data" {
  content {
    raster width=80 height=20 { source surface="wave" }
  }
}
```

Both files are watched. Saving the stylesheet invalidates style; saving the config also
restarts the modules whose module or options changed, and no others (section 10). Errors
show up as a red `.error` bubble on the bar with the message, and the last good config stays
live.

## 12. Phasing

Each phase ends with something you can run and look at.

1. **Content on the cover.** Scene, flex layout with the notch, CSS-subset parser and
   cascade, `text` and `clock` modules, the hole cutting through them. This proves that
   bubbles on the photographed backdrop look as good as the probe does.
2. **Built-in modules and live reload.** `front-app`, `battery`, `wifi`, `volume`, `net`,
   `exec`, `data`; config and stylesheet watching; the `.app` bundle.
3. **Socket and CLI.** The protocol in section 4, `bario set/content/emit/get/watch`.
4. **WASM.** `WasmEngine` on WasmKit, the bytes ABI, host imports, permissions; a Rust PDK
   and one non-Rust PDK; the weather module as the worked example. The `canvas` node lands
   here too, since the display list painter is small and the PDKs should ship with it.
5. **Interaction.** Item events behind Option, `on-click`/`on-scroll` shortcuts,
   transitions on layout.
6. **Custom renderers.** Renderer modules registering node types, `request_frame`, the
   `ring` renderer as the worked example, `raster` last.
7. **The compositor.** Section 10's layer tree replaces the painter, in three steps, each of
   which runs. PLAN.md has how.
   1. a cover that hosts a layer tree, with the backdrop, item chrome and the hole as layers,
      each item's content still one raster, and `--shot` and the pixel tests on `CARenderer`.
      This alone makes a pointer move draw nothing;
   2. a layer and a raster key per node, text and symbols as tinted masks, meters as layers;
   3. renderers drawn at commit with `request_frame` per node, `transform` and `animation`,
      and the shared-surface raster source.
8. **Later.** Popovers, an overflow catch-all item, accessibility (expose items through
   `NSAccessibility`), a
   Component Model / WIT binding once the tooling is boring.

## 13. Open questions and known traps

- **Wi-Fi SSID needs Location Services** on macOS 14+. The module has to work without it,
  and the docs have to say why the SSID is missing.
- **Now Playing and Spaces** have no public API. Media is `MediaRemote` (private); Spaces come
  from yabai or AeroSpace over `exec`. Neither is a built-in module for that reason.
- **Screen Recording permission** must attach to a stable bundle identifier, hence the `.app`
  in phase 2. The probe's terminal-attached permission is a dev convenience only.
- **Aborting a runaway WASM call** depends on the runtime. If WasmKit cannot interrupt, the
  budget is enforced by tearing down the instance from another thread, which is why every
  instance gets its own actor and no shared state.
- **120Hz displays**: the display link runs at native rate, and animations are sampled
  against the clock rather than stepped per tick (section 10), so they are frame-rate
  independent by construction.
- **The capture photographing the bar** shows up as ghosts of old layouts, and only once
  something moves. Section 7's filter includes only the desktop, so it cannot; a filter that
  goes back to excluding windows has to know every cover, shown or not.
- **Text on the backdrop** needs contrast handling. A per-item `background` solves it in
  most themes; a `contrast: auto` that samples the backdrop under an item and picks light or
  dark text is worth prototyping in phase 1 because an invisible bar with bare text is the
  look most people will want first.
- **Compositor fidelity** has sharp edges, each one a test before it is a bug: one corner
  radius per layer; group opacity has to be asked for; `CARenderer` composites over what its
  texture already holds; and every raster has to follow a bar to a display with a different
  scale.
- **Receiving a surface needs a Mach service, and an ordinary app has none.** Measured in
  September 2026 on macOS 27, for the `surface` source (section 9):
  - *What a layer shows* is settled, and public: `contents` is documented to take an
    `IOSurfaceRef`, and the window server shows it. New pixels drawn into a surface a layer
    already shows never reach the screen, even when it is set as `contents` again; a second
    surface does, every time. So a producer keeps a pair, draws into the one not showing, and
    `frame` names it.
  - *Receiving one* is the trap. `NSXPCListener` and `xpc_connection_create_mach_service`
    listen only on names launchd gave the process. The supported way to get one is a
    LaunchAgent in the bundle with `MachServices`, registered through `SMAppService`, and then
    either bario is that job, launched by launchd rather than opened, or a helper is, brokering
    surfaces to an ordinary bario; both are listed in Login Items and change how bario installs
    and runs. `bootstrap_register` lets a plain process publish a name another process can
    look up, and still does, though it has been deprecated since macOS 10.5.
  - So bario publishes its port with `bootstrap_register`, and the hand-off is a plain Mach
    message (two surface ports, a port that names the producer, and a reply) with a dead-name
    notification for when the producer goes. All of it is one C file in `CBarioShim`; the
    registry, `frame`, and the source know nothing of it. If the call is ever removed, a
    helper LaunchAgent that brokers the same message takes its place and producers do not
    change.
- **Content is per item, not per bar.** A module runs once for an item name, and every bar
  showing that item shows the same content. A window manager's stream is per display, so an
  item showing one picks a display (the focused one) and every bar shows it. Per-bar content
  needs a module context that knows its bar, and a module instance per bar where it matters.
- **Shaders.** Nodes are layers, so a node could be a `CAMetalLayer` running pipelines the host
  owns. Shaders supplied by plugins would need translating, and GPU budgets the sandbox cannot
  enforce yet. Not planned, not ruled out.
