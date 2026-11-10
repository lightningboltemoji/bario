import Foundation

/// The look bario ships with, and the worked example from DESIGN.md §7. It is applied under
/// the user's stylesheet, so `~/.config/bario/style.css` overrides rather than replaces.
public let defaultStyleCSS = """
/* bario's built-in look. Copy to ~/.config/bario/style.css and make it yours;
   yours cascades on top of this, so you only write what you want to change. */
:root {
  --fg: system(labelColor);
  --bubble: rgba(255, 255, 255, 0.14);
  --bubble-hover: rgba(255, 255, 255, 0.24);
}

bar {
  background: backdrop;
  font: 12pt system-ui medium;
  color: var(--fg);
  padding: 0 8pt;
  gap: 6pt;
  transition: layout 160ms ease-out, opacity 150ms;
}

/* The bar coming on screen and going off it: over the real menu bar at start, over and off a
   full screen app, with a menu bar that hides. A short cross-fade with the real menu bar
   underneath, rather than a pop. bar.fullscreen picks out the full screen app's. */
@starting-style { bar { opacity: 0; } }
bar:leaving { opacity: 0; }

item {
  padding: 2pt 9pt;
  border-radius: 8pt;
  background: var(--bubble);
  transition: background 120ms ease-out, opacity 120ms, color 120ms;
}

/* Hover and press only happen while the bar takes the pointer, which is when a click reaches
   an item: while Option is held over it, or, under `option "reveal"`, while it is not. The
   rest of the time the bar ignores the pointer, bar the hole. */
item:hover { background: var(--bubble-hover); }
/* The item a menu hangs from, lit while it is open, as the menu bar's own titles are. */
item:open { background: var(--bubble-hover); }
item:overflow { opacity: 0; }
item:stale { opacity: 0.5; }

item.error {
  background: rgba(220, 60, 50, 0.85);
  color: white;
}

group { gap: 2pt; background: none; padding: 0; }
group item { border-radius: 0; }
group item:first-child { border-radius: 8pt 0 0 8pt; }
group item:last-child { border-radius: 0 8pt 8pt 0; }
group item:only-child { border-radius: 8pt; }

meter { fill: currentColor; track: rgba(255, 255, 255, 0.25); }
graph { fill: currentColor; stroke-width: 1.5pt; line-cap: round; }

/* The stats presets: `stacked` is two lines in the height of one. */
.stacked { font-size: 9pt; }
.graph, .meter { gap: 4pt; }
.graph graph { fill: accent; }

#clock { font-weight: semibold; }
#battery.low { background: rgba(255, 70, 70, 0.35); }
#battery.charging .icon { color: system(systemGreenColor); }

/* Menus: what drops down from an item when it is clicked. A menu is a piece of the bar, not one
   of the system's menus: it inherits the bar's type and colour (it is selected under its item,
   `#wifi menu`, `#battery.charging menu`, but inherits from the bar, not the bubble), and it is
   a bubble of its own: one as it shows over the wallpaper, made solid, since a menu hangs over
   windows rather than the desktop, with a soft shadow to lift it off them. Its rows light as a
   bubble does under the pointer, and only a node with an action lights, so information rows sit
   still. Everything dimmed in it is dimmed from its own colour, so a bar in any colour has a
   menu that reads. Its opacity and transform are how its window comes and goes. */
menu {
  background: color-mix(in srgb, white 14%, wallpaper(dominant, system(windowBackgroundColor)));
  border-radius: 12pt;
  padding: 4pt;
  margin: 5pt 0 0 0;
  min-width: 240pt;
  gap: 0;
  shadow: 0 -6pt 20pt rgba(0, 0, 0, 0.14);
  transition: opacity 110ms ease-out, transform 110ms ease-out;
}
@starting-style { menu { opacity: 0; transform: translateY(-3pt); } }
menu:leaving { opacity: 0; transition: opacity 160ms ease-in; }

menu row { padding: 3pt 9pt; gap: 8pt; border-radius: 8pt; }
menu row:hover { background: var(--bubble-hover); }
menu .header { padding: 6pt 9pt 2pt; font-size: 11pt; font-weight: semibold; opacity: 0.6; }
menu .title { font-weight: semibold; }
menu .value { opacity: 0.6; }
menu .note { font-size: 11pt; opacity: 0.6; }
menu .separator {
  padding: 0.5pt 0;
  margin: 4pt 9pt;
  background: color-mix(in oklch, currentColor 18%, transparent);
}

/* A slider is a meter you can drag: a capsule filled from the left, with its icon beside it. */
menu slider {
  stroke-width: 7pt;
  fill: currentColor;
  track: color-mix(in oklch, currentColor 18%, transparent);
}
menu .glyph { width: 18pt; }

/* A choice among several, like an output: the check shows on the one that is chosen, and keeps
   its column on the rest so the names line up. */
menu .check { opacity: 0; icon-weight: semibold; icon-size: 11pt; }
menu .selected .check { opacity: 1; }

/* Submenus: every menu rule reaches them, and `menu menu` only them. One hangs beside the row it
   opened from, a little apart from its parent, and fades in where it is rather than sliding. The
   row stays lit while its submenu is open. */
menu menu { margin: 0 0 0 4pt; }
@starting-style { menu menu { transform: translateY(0); } }
menu row:open { background: var(--bubble-hover); }
menu .arrow { icon-size: 9pt; icon-weight: semibold; opacity: 0.6; }

/* An app's menus (the front-app item's): a check column where a menu has checks, the shortcut
   dimmed at the end, and an item the app has turned off dimmed further, and still. */
menu .mark { width: 13pt; }
menu .shortcut { opacity: 0.6; }
menu .disabled { opacity: 0.4; }

@media (prefers-color-scheme: dark) {
  :root {
    --bubble: rgba(0, 0, 0, 0.30);
    --bubble-hover: rgba(0, 0, 0, 0.45);
  }
  menu {
    background: color-mix(in srgb, black 30%, wallpaper(dominant, system(windowBackgroundColor)));
    shadow: 0 -6pt 20pt rgba(0, 0, 0, 0.30);
  }
}
"""
