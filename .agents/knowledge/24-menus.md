# 24 — Menus

DESIGN.md §8 ("Menus"), from PLAN.md's decisions M1–M15. What drops down from an item when it is
clicked: a second render of the item's state, shown as a one-item scene on a window of its own,
through the same frame as the bars.

## The shape

```
click on an item with no on-click (or `menu`)
  └─ FrameLoop.toggleMenu → pendingMenu, ModuleHost.openMenu
       └─ host renders the menu (config › written `menu` › Module.menu), reads under "\u{1F}menu:<item>"
            └─ onMenuRendered → nil content: nothing opens │ content: Menu made, makeMenuSurface()
                 └─ frame: layOut (Styler.style(menu:) → BarLayout.layout(menu:)) → present → commit
```

| file | holds |
|---|---|
| `Frame/Menu.swift` | `MenuSurface`, `Menu` (one open menu's pipeline state, its hover, press and drag), `MenuTarget`, control hit testing on `SceneNode` |
| `Frame/FrameLoop.swift` | `menu`, `closingMenus`, `pendingMenu`; `toggleMenu`/`openMenu`/`closeMenu`, hover switching, `layOut`, `presentMenus`; the bar shut while its menu is open (`isShut`) |
| `Runtime/ModuleHost.swift` | `MenuSlot` and `MenuState`; `openMenu`, `closeMenu`, `menuState(for:)`, `renderMenu`; `isConfined` |
| `Style/Styler.swift` | `style(menu:of:bar:states:interaction:modes:)`, `StyledMenu`, `NodeInteraction`; node `:hover`/`:active` by index path; item `:open` |
| `Layout/MenuLayout.swift` | `MenuScene`, `BarLayout.layout(menu:anchor:top:align:on:)`: size, place, clamp, reach |
| `Layout/BarLayout.swift` | stretched columns, sliders growing in rows, node `margin` and `width`/`min-width`/`max-width` |
| `Runtime/ContentTemplate.swift` | `each`, `if`, quoted action slots; `StateReader.value` reads `/absolute` paths |
| `Config/ContentKDL.swift` | node actions in KDL, `separator`, `each`/`if`, `KDLNode.menuContent` (several nodes are a column) |
| `App/MenuPanel.swift` | the window (`KeyPanel`, pop-up-menu level), `MenuView`, the glass that follows the panel |
| `App/BarController.swift` | controls on the bar and in menus, the default click, `menu`/`send`, slider changes one at a time, keys, clicks forwarded to the bar under the window |
| `Modules/…`, `Support/Brightness.swift` | default menus for `wifi`, `volume`, `battery`, `brightness`; device lists; DisplayServices and CoreBrightness |

## Rules that are easy to break

- **A closed menu costs nothing.** Its reads are recorded under `ModuleHost.menuKey(item)`, never the
  item's own, and forgotten when it closes. A write under the item's key dirties an open menu too
  (an item always depends on its own subtree). A test counts `Module.menu` calls across a close.
- **A menu opens on its first render, not its request.** `pendingMenu` holds the ask; a render with
  content makes the `Menu`, and one with nil drops the ask. Asked for by a click, an empty one
  closes the open menu, as a click outside it would; asked for by the pointer moving onto an item
  (`hovering`), it leaves the open one be. A menu already rendering for another anchor is reused, not closed: see
  `retire(_:rendering:)`.
- **The menu inherits from the bar.** `Styler.style(menu:)` matches the path with the item (and its
  groups) in it, but passes the bar's style as the parent. Matching and inheriting are separate on
  purpose; do not "simplify" the parent to the item's style.
- **Opacity and transform are the window's.** `BarLayout.surface(of:)` moves them to the scene's
  style, where `Animator.arrive`/`leave` ease them; the panel item gets opacity 1 and no transform,
  or they would apply twice.
- **Hover from the keys sticks until the pointer moves.** `updatePointerTarget` runs after every
  frame and would put the hover back under a still pointer; `Menu.hoverFromKeys` stops it.
- **A drag's value outlives the release** until a render lands (`dragged.released`), or the slider
  snaps back for the frames before the module has read the new level.
- **One `on-change` in flight.** `BarController.send` keeps the newest value and sends it when the
  last has been dealt with; an `exec` waits for its process there (`perform(waits:)`).
- **Confined actions.** `Action.parse(_:confined:)` for anything a WASM module wrote: its bubble
  (`ModuleHost.isConfined`) and a `menu` tree written under its key. Only `menu` stays bario's.
- **The window overlaps the bar** by its shadow's reach. A press there is the bar's
  (`BarController.forward`); a press elsewhere off the panel closes the menu.
- **The look is the bar's, not the system's.** The built-in `menu` sets no font or colour, so the
  bar's flow in, and dims from `currentColor` (`opacity`, `color-mix(… currentColor …)`), never
  `system(secondaryLabelColor)` and friends: those are the system's greys, unreadable on a bar
  restyled in light text over a dark tint. Its background is the bubble as it shows over the
  wallpaper, made solid. See DESIGN.md §8.
- **A rule only menus wear does not make a first frame wait.** `Stylesheet.usesWallpaper` skips
  a rule whose every selector has `menu` in it (`Selector.isInMenu`), so the built-in menus'
  `wallpaper(dominant, …)` does not hold every bar's first frame for a palette.
- **A menu goes when its anchor does**: the anchor must be in its bar's target scene, not leaving,
  and the bar showing. `layOut` returning false is what closes it.

## Glass

Not the default look, but there for a menu whose background says `glass`. `NSGlassEffectView` is a view, so it cannot be a layer in the compositor's tree. `MenuPanel` puts one
behind the layer-hosting `MenuView` while the panel's background is `glass`, and moves it to the
panel's box, top-left radius, opacity and translation on every `presented`. The compositor's chrome
draws `glass` as the backdrop blurred (`Glass.stand`), which on a menu, with no photograph, is
nothing; on a bar it is the stand-in. `--shot --menu` gives the menu the picture behind it as its
backdrop, so a shot shows the stand-in, not the system's glass.

## Seeing it

- `bario --shot out.png --menu wifi [--dark]`: the bar with that item's menu open under it, over the
  checkerboard or `--backdrop`. A source's menu hangs from the first item.
- `bario menu wifi` on a running bar opens it from the socket; `bario menu` closes whatever is open.

## Tests

`MenuTests.swift`: templates (`each`, `if`, absolute and quoted slots), KDL and JSON for controls,
config errors, the verbs and confinement; the cascade path and inheritance, hover only on controls,
stretch, slider growth, separator margins, placement and clamping, the window's style; and the frame
loop with `RecordingMenuSurface`: opens after its first render, nil opens nothing, renders only while
open, eases out then closes, the bar is shut and the item `:open`, hover switching, the anchor leaving,
toggling, key hover, and a drag's value surviving until the next render.

Not covered by tests: the AppKit window (key status, Escape, the glass view), which only a real
window server shows.
