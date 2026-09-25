# Examples

Everything here runs as-is: bario assembles a `.wat` file at load, so nothing in this
directory needs a toolchain installed. The Rust versions in `../pdk/rust` are what you would
actually write; these are the same contracts with the sugar taken off.

| file | what it shows |
|---|---|
| `counter.wat` | the whole module lifecycle: `init`, `poll`, `set_timer`, `render` |
| `ring.wat` | a renderer module that registers a node type, measures it, and draws it |
| `weather/` | the design's worked example, in Rust: `http`, permissions, state, render |
| `surface/` | a native process drawing into shared IOSurfaces with Metal, shown with no copy |
| `emira/` | another program's stream as a source, a mode that takes part of the bar over, a roll, and a Rust module rendering from the source |
| `ping/` | one source feeding several items: an app's Dock badge per item, its state as classes for the stylesheet |

## counter.wat

```kdl
item "ticks" module="wasm" path="~/.config/bario/modules/counter.wat" interval="1s"
```

Counts its own polls, writes the count into the state store (`bario get ticks`), asks to be
polled again a second later with `set_timer`, and renders a timer icon beside the number.

## ring.wat

```kdl
renderer "ring" path="~/.config/bario/renderers/ring.wat"
```

From then on any module's content tree may say `{"ring": {"value": 0.7}}`, including from a
shell script:

```sh
bario content cpu '{"ring": {"value": 0.7}}'
```

and it is themed entirely from the outside, by a stylesheet the renderer knows nothing about:

```css
#cpu ring  { color: system(systemGreenColor); stroke-width: 3pt; }
:root      { --track: rgba(255, 255, 255, 0.22); }
```

`draw` is called by two stages: layout calls it with `"measure": true` for the natural width,
and commit calls it for the drawing, with the node's size in a frame at 0, 0. Commit calls it
again only when the payload, the node's style or its size changes, or when the renderer called
`request_frame()` while it drew; otherwise its last drawing stays on screen, however much moves
around it. The colours it names (`currentColor`, `var(--track)`) are resolved against that
node's own style when the host rasterizes them.

## weather

```sh
rustup target add wasm32-unknown-unknown
cd weather && ./build.sh
```

```kdl
item "weather" module="wasm" path="~/.config/bario/modules/weather.wasm" interval="10m" {
  permissions "net"
  config city="Vancouver" units="metric"
}
```

Fetches through the gated `http` import and writes what it found into the store; `render`
reads the store, so a failed fetch still shows the last good reading, marked `.stale`. It
never touches the filesystem, a socket or a process — `permissions "net"` is all it asks for
and all it gets.

## surface

```kdl
item "wave" module="data" {
  content {
    raster width=80 height=20 {
      source surface="wave"
    }
  }
}
```

```sh
swift run surface-example wave 30
```

The item's content is in the config, so it survives a restart. (`bario content wave` with the
same tree as JSON does the same thing for an item that has none, until bario restarts.)

A Swift program, built from this package, that hands a running bar two IOSurfaces under the
name `wave` and then draws a moving wave into them with Metal for thirty seconds. Each frame it
draws into the surface that is not showing and sends `frame` over the socket; bario makes that
surface the node's layer contents, so nothing is copied and nothing on the bar is drawn. When it
exits, its surfaces go with it.

`SurfaceProducer` in BarioKit is the whole producing side: `next` is the surface to draw into,
`present()` says it is drawn. A producer in another language sends the same Mach message
(`bario_surfaces_hand_off` in `Sources/CBarioShim` is the reference) and the same `frame` line.

## emira

[emira](https://github.com/lightningboltemoji/emira)'s names guide in the bar: while the desktop
changes, the app name rolls away and a row of the focused strip's columns rolls in, centred
between the Apple logo and the notch, and it all rolls back 700ms after things settle. Nothing in
bario knows about emira; this is config, a stylesheet, and `names/`, a module that reads what the
source wrote. It needs an emira with `emira watch`.

```sh
rustup target add wasm32-unknown-unknown
names/build.sh          # installs ~/.config/bario/modules/emira-names.wasm
```

Then in `config.kdl`:

```kdl
// emira's desktop, a snapshot per change, under `emira` in the store. No bubble.
// `emira watch` exits at once while the daemon is down, so retry often: back within 5s of it.
source "emira" module="exec" interval="watch" max-backoff="5s" {
  command "emira" "watch"
}

// On while the desktop moves, and for 700ms after the last change or movement.
mode "guide" {
  while "emira.moving"
  changed "emira.focus" "emira.displays"
  hold "700ms"
}

bar {
  item "apple" module="text" { content { icon "apple.logo" } }
  item "app" module="front-app" format="{name}" unless="guide"
  spacer when="guide"
  // Reads `emira`, asks for no permissions; `max` keeps the 7 columns nearest focus.
  item "names" module="wasm" path="~/.config/bario/modules/emira-names.wasm" when="guide" {
    config source="emira" max=7
  }
  spacer
  notch
  // …
}
```

and in `style.css`:

```css
#app, #names {
  transition: transform 280ms ease-in-out, opacity 220ms ease-in;
}
@starting-style {
  #app, #names { transform: perspective(40pt) translateY(20pt) rotateX(-90deg); opacity: 0; }
}
#app:leaving, #names:leaving {
  transform: perspective(40pt) translateY(-20pt) rotateX(90deg); opacity: 0;
}
#names         { padding: 3pt 5pt; }
#names .column { padding: 0pt 7pt; border-radius: 12pt; }
#names .focused { background: rgba(255, 255, 255, 0.16); }
#names .app    { text-transform: lowercase; }
#names .more   { opacity: 0.5; padding: 0pt 4pt; }
```

`bario --diagnose --mode guide` prints the arrangement without emira moving anything, and
`--shot` draws it.

With no Rust toolchain, `names.jq` makes the same row from a second `emira watch`, through the
`jq` that ships with macOS; copy it to `~/.config/bario/emira/` and make the item

```kdl
  item "names" module="exec" interval="watch" when="guide" {
    command "emira watch | jq -c --unbuffered --argjson max 7 -f ~/.config/bario/emira/names.jq"
  }
```

The stylesheet is the same for both, since both draw the same tree.

The pieces are general. `source` puts any program's stream in the store, `mode` turns a
condition into an arrangement, and `@starting-style` and `:leaving` animate whatever comes and
goes. The module and the filter are the only parts that know emira's schema.

## ping

[Ping](https://github.com/lightningboltemoji/Ping)'s reading of the Dock in the bar: an app's icon
beside its badge, the count or word the Dock shows, or a dot. What state the badge is in is a
class, so how it looks is the stylesheet's business. Nothing in bario reads the Dock or needs
Accessibility; Ping does, and `ping-dot-app watch` streams what it read. It needs a Ping with
`watch`.

```sh
rustup target add wasm32-unknown-unknown
ping/badge/build.sh     # installs ~/.config/bario/modules/ping-badge.wasm
```

Then in `config.kdl`, one source and an item per app:

```kdl
// Ping's reading of the Dock, under `ping`: every app's badge, and whether it was acknowledged
// or snoozed. No bubble. `watch` exits at once while Ping is down, so retry often.
source "ping" module="exec" interval="watch" max-backoff="5s" {
  command "/Applications/Ping.app/Contents/MacOS/ping-dot-app" "watch"
}

bar {
  // A group with nothing shown in it is not drawn, so it goes with the last quiet app.
  group "badges" {
    item "slack" module="wasm" path="~/.config/bario/modules/ping-badge.wasm" on-click="exec open -a Slack" {
      config app="Slack" warn=5 critical=10 hide="quiet"
    }
    item "messages" module="wasm" path="~/.config/bario/modules/ping-badge.wasm" on-click="exec open -a Messages" {
      config app="Messages" hide="quiet"
    }
  }
  // …
}
```

`app` is the title under the icon in the Dock. `warn` and `critical` are counts; `hide="clear"`
hides an app while it has no badge, and `hide="quiet"` also while Ping has it acknowledged or
snoozed. `icon` takes an SF Symbol name in place of the app's own icon, and `dot` what a bare dot
shows. The item wears one of `.clear`, `.dot`, `.count` and `.text`, `.badged` with any but the
first, and `.warn`, `.critical`, `.acknowledged`, `.snoozed`, `.absent` (not in the Dock) and
`.silent` (Ping stopped answering, so this is the last thing it said). In `style.css`:

```css
/* The app's own icon in colour while it has something to say, its shape alone while it has not,
   and the count in red once it is worth dropping things for. */
#badges .app { icon-rendering: multicolor; icon-size: 15pt; }
#badges .clear .app { icon-rendering: monochrome; }
#badges .badge { font-weight: bold; }
#badges .warn .badge { color: rgb(255, 190, 90); }
#badges .critical .badge { color: rgb(255, 95, 85); }
#badges .acknowledged, #badges .snoozed, #badges .silent { opacity: 0.5; }
```

The icon is `{"icon": {"file": "/Applications/Slack.app"}}`, from the path Ping publishes: a file
icon naming an app draws the app's icon, as Finder does, so it follows the system's icon style.

Where emira's module renders one row from the whole source, this one renders one app, and each
item keeps only its own app's part of the source under its own key, so a badge on Slack does not
re-render Messages.
