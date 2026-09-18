# 15 — Interaction: clicks, scrolls, hover, transitions

DESIGN.md §8, plus the transitions §7 calls "the point of the whole exercise".

## Click-through, measured rather than assumed

§13 called this "the biggest unknown and the first thing to measure in phase 5": does a click
on a transparent pixel of the cover — the hole — fall through to the real menu bar? A tool
posted a synthetic click on solid bar (the cover received it, so the measurement was sound) and
then one inside a fully transparent hole, and the cover received that too. **On macOS 27 it does
not work**: the window server does not consult per-pixel alpha when deciding which window a
click lands in. So the cover switches `ignoresMouseEvents` instead.

What switches it changed once. First it was per item: the cover took events over an item with a
shortcut, a tooltip or `interactive=true`, with a `mouse "toggle" | "transparent" | "off"` bar
setting. Items also hovered, `hole: dodge` faded an item out of the lens and `hole: keep` kept
it over it. The result read wrong: bubbles glowed under a pointer aimed at the real menu bar,
and a click on a glowing clock opened whatever system menu was underneath.

**Now: hold Option.** Without it the bar is inert — the hole cuts every item, nothing hovers,
every click falls through. With Option held and the pointer on a bar, that bar eases its hole
shut, takes the pointer, and its items hover and receive clicks. `mouse`, `interactive`,
`hole: keep | dodge` and `--verify-clickthrough` are gone.

- The frame loop decides (`FrameLoop.optionHeld`, `Bar.isInteractive`,
  `BarSurface.setTakesPointer`), from what is on screen under the pointer, after pointer moves,
  Option changes and frames — see [17-frame-loop.md](17-frame-loop.md).
- Option is noticed three ways: the modifier state on pointer events; a global `flagsChanged`
  monitor, which only delivers with Accessibility permission; and a 30Hz read of
  `NSEvent.modifierFlags` that runs only while the pointer rests on a bar, which covers pressing
  or releasing Option over a still pointer without that permission.
- The cover is a non-activating `NSPanel` (`hidesOnDeactivate = false`). As a plain `NSWindow`,
  an Option-click activated bario: focus left the app you were in, and `front-app` read "bario".

A `CGEventTap` would replace the poll but needs Input Monitoring permission. Not for v1.

## Events

An item's events go to three places at once, which is what keeps the tiers equivalent:

1. the item's module, as `on-event` (`click`, `right-click`, `scroll`);
2. socket subscribers, as `click:volume`-style topics (the protocol from increment 10);
3. the item's own `on-click` / `on-right-click` / `on-scroll` shortcut, if it has one.

## The action language

Shortcuts cover the common cases without a module (§8):

```kdl
item "cpu" module="cpu" on-click="exec open -a 'Activity Monitor'"
item "volume" module="volume" on-scroll="adjust" on-click="toggle-mute"
item "ci" module="data" on-click="emit refresh"
```

A handful of verbs are the host's: `exec <command>` (through `/bin/sh -c`, so quoting works),
`emit <name> [json]`, `set <target> <json>`, and `reload`. **Anything else is delivered to the
item's module as an event named by the action**, which is why `adjust` and `toggle-mute` need
no special case in the config layer — they are `volume`'s business, and `volume` implements
them by actually moving the system volume through CoreAudio.

## Transitions

The cascade already produces target styles and the interpolator already exists (increment 03).
What was missing is the clock. `Animator` (in `Frame/`) keeps the target scene and, per item,
when each transition started and from what value — per property, so a property still easing
toward an unchanged target is not restarted by another one changing. Asked about a moment, it
returns what should be on screen then; nothing is stepped per tick. See
[17-frame-loop.md](17-frame-loop.md).

Subtleties that matter:

- **Retargeting mid-flight** starts from the value on screen, not from the original start, so
  hovering in and out quickly does not snap.
- **Layout animates too** (`bar { transition: layout 160ms ease-out }`): item frames are eased
  toward their new positions, which is what stops a clock changing width from making the
  bubbles beside it jump. Content keeps its measured size, centred and clipped to the bubble.
- **Inherited properties ease into content**: an item's `color` transition reaches the text
  that inherited it, not text that set its own.

An item that has just appeared, or receives its first content, is placed at its target; its
neighbours slide. A bar that is not on screen takes every scene without easing.

## Tests

The action parser, including quoting. Event routing: a click reaches the module, the socket
and the shortcut. The animator: an exact start and end, sampling that moves nothing, a retarget
mid-flight starting from where it was, independent per-property clocks, layout easing with
content centred, inherited colour easing, and `isMoving` going false so frames can stop.
