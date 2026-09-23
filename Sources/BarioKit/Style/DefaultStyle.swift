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
  transition: layout 160ms ease-out;
}

item {
  padding: 2pt 9pt;
  border-radius: 8pt;
  background: var(--bubble);
  transition: background 120ms ease-out, opacity 120ms, color 120ms;
}

/* Hover and press only happen while Option is held over the bar, which is when a click
   reaches an item: the rest of the time the bar ignores the pointer, bar the hole. */
item:hover { background: var(--bubble-hover); }
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

@media (prefers-color-scheme: dark) {
  :root {
    --bubble: rgba(0, 0, 0, 0.30);
    --bubble-hover: rgba(0, 0, 0, 0.45);
  }
}
"""
