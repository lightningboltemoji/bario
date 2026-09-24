# 21 — Sources, modes, and arriving and leaving

DESIGN.md §3, §6 and §7. A bar that shows another program's picture of the desktop needs three
things it did not have. The program's facts have to land in the store without a bubble of their
own. The bar has to be able to rearrange itself on a condition, not only restyle. And what comes
and goes has to be able to animate in and out, not snap. The worked case is emira's names guide
taking over the stretch of the bar with the app name while the desktop changes. All three pieces
are general, and none of them knows about emira. `examples/emira` holds config, a stylesheet,
and a Rust module that renders the row from the source's state. It asks for no permissions: it
subscribes to `state:emira.*` in `init`, reads the snapshot with an absolute `get`, and keeps what
it shows under its own key. A jq filter makes the same row for anyone without a Rust toolchain.

## The bus is the other program's own socket

emira streams its desktop as JSON lines (`emira watch`: a snapshot on connect, then one whenever
a fact changes). bario reads it through a `source`, which is an `exec` with no bubble. That is how
niri, sway and Hyprland serve bars. A distributed notification gives a late joiner no snapshot
and a shell no way in, and a shared broker would be more machinery than either program. Anything
else that wants emira's facts runs the same command.

## `source`

```kdl
source "emira" module="exec" interval="watch" { command "emira" "watch" }
```

It is parsed like an item and run by `ModuleHost` like one (`load(_:sources:)`), with
`Instance.isSource`: never held, never dirty, never rendered, and not one of a bar's
`moduleItems`, so no first frame waits for it. It writes under its own name. A format, content,
`when` or action on it is an error, because nothing shows it. Its name must not be an item's.

## The store: a write is what it changed

`StateStore.write` diffs the subtree it writes (`JSONValue.differences`) and, if nothing changed,
does nothing: no version, no notification, no dirty items. Otherwise it dirties the readers of the
paths that changed rather than of the path written, so a snapshot stream re-renders only what
reads the part that moved. `recentWrites` keeps those paths per write.

`values(of:)` yields the values at some paths now, and again after every write that changes any
of them. It yields every value in order, so a change and its undoing are two changes rather than
none, which is what modes need and what sampling after a notification cannot give.

Under an item's key, `content` is a tree and is replaced whole. Merged key by key, a row followed
by a text would hold two kind keys and decode to nothing. `bario content` had exactly that.
`exec` shows a line's `content` key the way `data` shows a pushed one.

## Modes

`ModeConfig` holds `while` paths (on while truthy), `changed` paths (on when a value changes) and
`hold` (stays on that long after the last reason: a change, or a `while` letting go).
`ModeTracker` (in `Frame/`) consumes `values(of:)`, keeps what it last saw, and arms the frame
scheduler's `after` for holds. A timer that fires early arms again rather than leaving the mode
on. A path's first non-null value is not a change, so startup and a source's first line turn
nothing on; that is emira's `Guide.prime` rule. A flip is one invalidation row:
`FrameLoop.modes` changing restyles every bar.

The style stage takes the modes. They are classes on the `bar` style node, and
`Styler.Shown` decides `when`/`unless` before anything else, for items, groups and spacers alike.
A mode decides layout only: an item it hides still renders, so it has content the moment it
shows. `--shot` and `--diagnose` take `--mode <name>` to hold one on.

## Arriving and leaving

`@starting-style` rules carry `StyleRule.starting` and take part in no cascade but
`Cascade.startingStyle`. `:leaving` is a `StyleState`, and `Cascade.leavingStyle` cascades an item
with it. Both return nil when no rule applies, which keeps the second cascade off every item that
does not ask for one. The styler puts both on `StyledItem` (never on a spacer), and layout copies
them to `SceneItem`, so the animator has an item's leaving style from while it was still there.

In `Animator.retarget`:

- **Leaving.** An item in the last target and not in the new one, with a `:leaving` style and a
  transition to it, becomes a `Ghost`: the item as it was presented at that instant, its style
  tweening on to the leaving style, and where it sat (row, index, the group it was in). A group
  goes as one, and its items are not ghosted again. `presented(at:)` puts each ghost back among
  the items it left, with `.leaving` in its states, until its tweens end. It is dropped at the
  next retarget after that.
- **Arriving.** An item not in the last target starts from its ghost's style if it is coming back,
  so it turns round from where it had got to. Otherwise it starts from its starting style. Its
  frame is its target, as before; a returning ghost's frame eases there under `layout`.
- **Off screen**, nothing leaves or arrives: the scene is taken as it is.

`Scene.item(at:)` skips `.leaving`, so a ghost takes no clicks. It keeps its name, so the
compositor keeps its layers and rasters: a roll draws nothing.

Transitions rather than Core Animation `animation`, because a mode flipping back mid-roll must
reverse from what is on screen, and only the animator retargets.

## Turning in depth

`Transform` gains `rotateX`, `rotateY` and `perspective` (0 is none), and the parser gains
`translateX()` and `translateY()`, which CSS users write and bario lacked. The matrix is scale,
then rotateY, rotateX and rotate, then `m34`, then translate. Positive `rotateX` tips the top away
and positive `rotateY` tips the right away, as in CSS; `DepthTests` pins both by projecting
corners. When one side of a tween has no perspective, the other side's holds throughout: there is
no distance to ease from `none`.

**Measured:** siblings under a layer share one 3D space, and a box tipped out of the bar's plane is
cut where it passes behind the bar's backdrop layer at z = 0. A 40° `rotateX` showed only its near
half, and a flat `rotateX(60deg)` with no perspective showed nothing at all. So a layer whose style
turns in depth, now or in a keyframe, gets `zPosition` `Motion.lift`. That orders it in front and
changes no projection, since translation does not touch w.

## Tests

`ModeTests.swift`: writes that change nothing, precise invalidation, `differences`, value watching
through a change and its undoing, truthiness; sources and modes in the config, with every error;
modes on the frame loop with `ManualScheduler` (hold re-armed by a second change, `while` holding
and its hold starting when it lets go, the bar class, a hidden item still rendering). The source's
real-module test is in `ModuleHostTests`, in the serial pass. `EnterExitTests.swift`: the starting
and leaving cascades, their parse errors, transform parsing and directions, perspective blending,
and on the frame loop: leaving, vanishing without `:leaving`, arriving, turning round, a group
going as one, an item leaving a group that stays, and nothing leaving off screen. The lift is
tested on the compositor. `exec`'s `content` key and the store's content replacement each have one.
