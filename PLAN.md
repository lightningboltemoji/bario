# Plan: menus

What drops down from an item when it is clicked: Wi-Fi's network and addresses, the outputs
under volume, a control centre under the Apple logo. Written in November 2026 before any of it
was in bario, and built the same month: DESIGN.md §8 ("Menus") says what and why, and
`.agents/knowledge/24-menus.md` is the record of how. (The plan this replaces, colours
from the wallpaper, is built; its record is `22-wallpaper-colours.md` and git history.)

DESIGN.md §8 has said since the start that a popover is "a second window anchored to the item's
frame … the content model is the same tree, so nothing has to change to allow them". That is the
whole idea, taken literally:

```kdl
item "wifi" module="wifi" format="{icon}" {
  menu {
    row class="title" { text "{ssid}"; spacer; text "{rssi} dBm" }
    row { text "IP address"; spacer; text "{ip}" }
    separator
    row on-click="exec open 'x-apple.systempreferences:com.apple.wifi-settings-extension'" {
      text "Wi-Fi Settings…"
    }
  }
}
```

```css
menu            { background: color-mix(in srgb, white 14%, wallpaper(dominant)); border-radius: 12pt; }
menu row:hover  { background: var(--bubble-hover); }
#wifi menu      { min-width: 260pt; }
```

## Where we start

- **An item is one module's render** (`ModuleHost`), cached against the state paths it read,
  restyled only when its result changes (`FrameLoop.rendered`). An item always depends on its own
  subtree in the store.
- **A bar's pipeline** is style (`Styler`) → layout (`BarLayout`) → present (`Animator`, `Lens`)
  → commit (`Compositor`), all fed one `Scene`. The compositor and the animator know nothing of
  bars beyond the `Scene` they are handed.
- **Events are per item.** `BarView` hit-tests items, `BarController.handle` sends the event to
  the module, the socket and the item's `on-click`. Content nodes are not hit, and have no
  `:hover`.
- **Templates fill slots from the item's own state** (`ContentTemplate`, `FormatString`); there is
  no way to read another key, and no way to repeat a node per element of a list.
- **The cover takes the pointer only while it is shut** (`FrameLoop.isShut`): Option held, or
  not held under `option "reveal"`.

## Decisions

**M1. A menu is a second render of the item's state.** `menu { … }` in the config is a content
tree, templated like `content`, and filled from the item's state. A module may supply a default
(`Module.menu(_:)`, nil unless it overrides it), and anything that writes an item's state may write
a `menu` tree under it, as it may write `content`. The config wins, then a written tree, then the
module's default. Several nodes directly inside `menu` are a column, since a menu is a list.

**M2. Menus render only while open.** The host renders an item's menu when it opens and again
when something it read changes, under its own dependency key, and forgets those dependencies when
it closes. A closed menu costs nothing, so a menu can read the rates and addresses a bubble never
shows without the bubble restyling every second. A menu appears after its first render, as a bar
does after its first frame; one whose render says nil does not open.

**M3. A menu is a one-item scene on a window of its own.** The panel is a `SceneItem` whose
content is the menu's tree, in a `Scene` whose bounds are the window. The compositor, the
animator, raster keys, tinted coverage, meters, `transition`, `@starting-style` and `:leaving` all
work unchanged. The window is a non-activating panel at pop-up-menu level, a little larger than
the panel so its shadow is not cut.

**M4. Styled as `menu`, under its item, inheriting from the bar.** The cascade path is
`bar(modes) › item#name.classes › menu`, so `menu`, `#wifi menu` and `#battery.charging menu`
all select, but inherited properties come from the bar and not the bubble: a bubble's `color`,
`icon-size` and `padding` stay in the bubble. The menu's `opacity`, `transform` and `transition`
are how the window comes and goes (the scene's style, as a bar's is); everything else is the
panel's chrome.

**M5. Any node with an action is a control.** `on-click`, `on-right-click`, `on-scroll` and
`on-change` are fields of every node, in the menu and on the bar. A node with one is hit by the
pointer, matches `:hover` and `:active`, and its action runs as the item's own would: same
verbs, same module, same socket event (with the node's `id`). The innermost control under the
pointer wins; with none, the item's action runs.

**M6. Clicking a control closes its menu,** as choosing a menu item does, unless it or an ancestor
says `keep-open=#true`. A slider never closes it.

**M7. `slider` is the one new node.** A meter you can drag: `slider value="{fraction}"
on-change="set-level"`. Drags and scrolls send `on-change` with `value` (0…1) in the payload, at
most once per frame, and the slider shows the dragged value until a render after the release
says otherwise. In a row it takes the free space, as a spacer does. `separator` is a styled
`spacer` with a class, written as its own word because menus are full of them; nodes take
`margin`, and `width`, `min-width` and `max-width` as items do, which is how a separator is spaced
and a column of glyphs lines up.

**M8. Lists and conditions: `each` and `if`.** In a template, `each "outputs" { … }` repeats its
children for every element of the array at that path, with slots read from the element first,
and `if "ssid" { … }` (or `if "!ssid"`) keeps them while the value is truthy. They exist so a menu
can list devices and leave out rows with nothing to say without a WASM module; they work in
`content` too.

**M9. Slots can read anywhere.** `{/volume.fraction}` reads from the store's root, so a control
centre can show other items' state. Reads are tracked like any other.

**M10. Slots in actions are quoted.** A slot filled into an `on-…` string is single-quoted, so a
network called `x; rm -rf ~` is one argument to a module verb and one word to `exec`'s shell.

**M11. Two new verbs.** `menu [item]` opens or closes a menu (an item's own, by default), and is
what a click on an item with no `on-click` does when the item has a menu. `send <item> <verb>
[args…]` delivers a verb to another item's (or a source's) module, so a control centre can move
the volume. `bario menu <item>` is the socket's way in, for keyboard launchers.

**M12. While a menu is open its bar is shut**, whatever Option says, as the real menu bar tracks
while one of its menus is open: the hole closes, the bubbles hover, and moving onto another item
with a menu switches to it. The item wears `:open`. A click outside bario, Escape, or a click on
the bar outside the item closes it; so does the item leaving the bar.

**M13. `background: glass` is the system's Liquid Glass.** On a menu, an `NSGlassEffectView` behind
the panel, following its box, radius and opacity; `glass(clear)` and a tint colour are its two
knobs. A bar has the real menu bar behind it, which glass would show, so there it is the
photograph blurred and saturated, the nearest look that hides it.

**M14. Placement is the item's.** A menu hangs from the bottom of its bar, its left edge under the
item's (`menu align="center"` or `"end"` otherwise), moved in to stay on the display. The gap is
the panel's `margin-top`.

**M15. Built-in modules bring menus.** `wifi` (network, signal, addresses, data in and out),
`volume` (level, outputs and inputs, each selectable), `battery` (charge, time, source) and a new
`brightness` module (display and keyboard, as sliders, with no permission needed: DisplayServices
and CoreBrightness are looked up at run time, as SkyLight is). Each default is written in KDL in
the module's file, so copying it into a config is the way to change it.

**M16. A menu looks like the bar, not like the system's menus** (decided after M13 was built, on
seeing it: glass, the system font and an accent-blue hover under a bar of tinted bubbles). The
built-in `menu` is one more bubble: the bubble as it shows over the wallpaper, made solid; the
bar's type and colour, inherited, not set; rows lit as a bubble is under the pointer; everything
dimmed dimmed from its own colour. Glass stays, as a background a menu can ask for. Rules only
menus wear do not make a first frame wait for the palette.

## Steps

1. **Content.** Node actions and `keep-open`, `slider`, `separator`; `each`, absolute slots and
   quoted action slots in templates; KDL and JSON both; the schema.
2. **Config and verbs.** `menu` on items; `menu` and `send`; errors for a source with a menu.
3. **The host.** `Module.menu`, menu renders with their own dependencies, `menu` replaced whole
   in the store.
4. **Style and layout.** `Styler.style(menu:)`, node `:hover`/`:active`, item `:open`;
   `BarLayout.layout(menu:)` with stretched columns and growing sliders; placement.
5. **The frame loop.** `Menu` beside `Bar`: open, first render, present, commit, leave; the bar
   shut while it is open; hover switching; hit testing controls on bars and menus.
6. **AppKit.** `MenuPanel` and `MenuView`, glass, Escape, the controller's wiring, the socket op
   and CLI verb, `--shot --menu <item>`.
7. **Modules and the look.** Menus for wifi, volume, battery and brightness; the default style.
8. **Docs.** DESIGN.md §2, §3, §8 and §12; the knowledge note; examples.

## Tests

Pure where it can be: the template's `each`, absolute and quoted slots; KDL for menus and node
actions; the cascade path and inheritance; node hover by path; menu layout, stretch, slider
growth, placement and clamping. The frame loop with the manual scheduler and recording surfaces:
a menu opens after its first render and not before, a nil render opens nothing, writes re-render
an open menu and not a closed one, closing eases to `:leaving` and then closes the window, the
bar is shut while a menu is open, hovering another item switches, and an item leaving the bar
closes its menu. Pixels through `--shot --menu`.
