# 20 — Stats widgets: windows, templates, graphs that scroll

`net`, `cpu` and `mem` have existed since increment 07, but only as text: they kept a rolling
history nothing could draw, since a format string only makes text and icons and a `content`
block was fixed at load. This increment makes them widgets: numbers over time windows, content
trees that read state, and graphs worth looking at.

## Sampling is configuration

`interval=` was already a duration on every item. Everything else about sampling is a duration
too, so changing how often an item samples changes neither what `1m` means nor how many seconds
a graph spans:

```kdl
item "cpu" module="cpu" interval="1s" windows="5s 1m" history="60s"
```

- `interval` is the sample rate, and nothing else. The defaults stay (2s for `cpu` and `net`,
  5s for `mem`) for configs that do not say.
- `windows` names durations the module reports over, each as its own key: `load-5s`,
  `load-1m`. A window is a whole number of samples, rounded to the nearest; one shorter than
  `interval` holds no sample at all and is a config error, shown as the item's error bubble.
- `history` is how much per-sample history `{history}` holds: a duration, or a bare number of
  samples as before.

**Windows are exact, not averages of averages.** Each module keeps a ring of raw snapshots,
CPU ticks and byte counters, as deep as its longest window or history. A window's value is the
difference between the newest snapshot and the one that many samples back, so `load-1m` is the
CPU's busy share over that minute exactly, and `rx-1m` the bytes that minute moved over its
length. Memory is a gauge, not a counter, so its windows are the mean of the samples in them.
A window not yet full reports over what it has, so nothing reads blank for a minute after
launch.

**History is always full length.** It is padded at the front with `null` until it fills, and a
graph leaves a gap where a value is null. So a graph's step never changes as its history grows,
and new samples come in at the right from the start.

## Content that reads state

A `content` block may now use slots, which makes it a template, compiled once at load:

```kdl
item "cpu" module="cpu" interval="1s" windows="5s 1m" {
  content {
    row {
      graph values="{history}" max=1 kind="area" scroll="smooth"
      column { text "{load-5s:%3.0f}%"; text "{load-1m:%3.0f}%" }
    }
  }
}
```

Every string in the tree is a format string. One that is exactly one slot with no spec,
`"{history}"`, is replaced by the value itself, an array or a number, so a graph gets its
values and a meter its fraction, and by empty text when there is no value; anything else
renders to a string as a format does. Then the tree goes through the same decoder a pushed tree
does. So a template works for every node kind, a renderer's included, and for `class` and `id`,
and reads are tracked like a format's: the item re-renders when what it read changes and at no
other time.

Any module that shows a format now takes a `content` block instead, static or templated, not
just `text` and `data`. A literal brace inside content is `{{`, as in a format, in plain content
as much as in a template, so a string means the same thing whether or not a slot sits beside it.

What cannot be checked at load is a templated node's values, which do not exist yet; the format
strings are, and so is every subtree with no slot in it. A template that decodes badly at render
(`graph values="{nope}"`) keeps the item's last content and wears `.stale`, with the decoder's
message in the log, as any module that throws does.

Two specs join the printf, truncation and date ones: `{used:bytes}` is `11 GB`, and
`{rx:rate}` is a byte rate padded to a fixed width, `  12 kB/s`, so the number changing every
second never changes the width of the item. A width change would be a layout transition every
tick.

## Presets

`preset=` picks a content template the module ships, so the common shapes are one word. Each is
written in KDL like a user's own, and the root node carries the preset's name as a class, so
`#cpu .stacked text` styles one.

| module | preset | shows |
|---|---|---|
| `cpu` | `stacked` | one line per window, `5s 1m` if none are named |
| `cpu` | `graph` | the history as an area, and the load |
| `net` | `stacked` | upload over download |
| `net` | `graph` | the download history, and the rate |
| `mem` | `stacked` | used over the pressure level |
| `mem` | `meter` | a meter and the percentage |
| `mem` | `graph` | the history as an area, and the percentage |

A preset beside `format=` or `content` is an error: an item shows one of them. `scroll=` and
`kind=` on the item reach the preset's graph.

The name is `preset`, not `display`, because `display=` on a `bar` already names a monitor.

## Graphs

`graph` gains three properties, all optional:

- `kind`: `line` (the default and the old look), `area`, or `bars`, all painted in `fill`.
- `floor`: the least the top of an auto-scaled graph can stand for, so an idle network is a
  flat line rather than noise at full height. `max` still fixes the top outright.
- `scroll`: `step` (the default) redraws in place when the values change; `smooth` slides the
  graph one step left over the time the last sample took, so it moves continuously.

A smooth graph is drawn one step wider than its node, with the newest value just past the
right edge, inside a layer that clips to the node. When the values change the raster is drawn
again and a Core Animation translation, added once, slides it one step left over the period
between the last two changes. The next sample lands exactly where the slide ends, so the seam
never shows. The window server runs the slide: bario draws once per sample, as a stepping graph
does, and sleeps in between. The period is measured rather than configured, so a graph from a
`data` item that someone pushes to on their own schedule scrolls at their pace. It costs one
sample of latency: the newest value slides into view rather than appearing at once.

## What the modules write

| module | new keys |
|---|---|
| `cpu` | `load-<w>` per window (0…100); `history` null padded |
| `net` | `rx-<w>`, `tx-<w>` per window (bytes/s); `interface`; histories null padded |
| `mem` | `pct-<w>` per window; `pressure` (`normal`, `warn`, `critical`); `swap-used`; `history` null padded |

**`net` counts the primary interface by default**, the one the system routes through
(`State:/Network/Global/IPv4` in the dynamic store), looked up again every few seconds so a
switch from Wi-Fi to Ethernet is followed. Summing every interface counted a VPN's traffic twice,
once inside the tunnel and once on the wire, and added AirDrop's and bridges' on top.
`interface="en0"` still names one, and `interface="all"` sums everything but loopback as before.

**The kernel's byte counters are 32 bits** in `getifaddrs`, so they wrap every 4 GB, which a
five-minute window at 15 MB/s crosses. So the ring does not hold them: `ByteCounter` adds what
each counted interface moved since the last sample, modulo 2³², to totals that only grow. A wrap
between samples costs nothing, and an interface that appears, disappears, or becomes the primary
one adds nothing on the sample it changes rather than a jump.

**`mem` reports the kernel's pressure level** (`kern.memorystatus_vm_pressure_level`), which is
what decides whether the machine is short of memory: a Mac using most of its memory is normal.
It sets `pressure-warn` and `pressure-critical` classes.

**Thresholds.** `warn` and `critical`, like `battery`'s `low`, set a `warn` or `critical` class
from `cpu`'s `load` and `mem`'s `pct`, one or the other, never both.

**Tooltips** say everything the module knows, every window included, for the item that shows
only two numbers.

## Tests

The window maths over synthetic snapshots: exact CPU deltas across a window, rates across a
window, a partly filled window, gauge means. Sampling config: durations to sample counts,
rounding, a window shorter than the interval refused with a message naming both. Templates:
whole-slot values keep their type, mixed strings format, missing slots, `{{` escapes, nested
rows, classes from slots, read tracking, a malformed template refused at load. The two specs.
Graph decoding with nulls, `kind`, `floor` and `scroll`; pixels for area and bars; a smooth
graph gets a clip, a strip one step wider, and an animation only after its second set of values.
Presets for every module parse and render.
