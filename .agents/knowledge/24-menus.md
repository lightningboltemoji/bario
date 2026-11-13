# 24 — Menus

DESIGN.md §8 ("Menus"), submenus and the front app's menus included. What drops down from an
item when it is clicked: a second render of the item's state, shown as a one-item scene on a window of its own,
through the same frame as the bars.

## The shape

```
click on an item whose on-click is `menu` (or `bario menu <item>`)
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
| `Support/AppMenus.swift` | an app's menu bar as a bario menu, pure: `AppMenuItem`, `MenuShortcut` (AX's character, glyph and modifier bits), Option variants, separators, the tree with `press <path>` rows |
| `Support/AppMenuReader.swift` | the Accessibility side: reading `AXMenuBar` with timeouts and a deadline, `press`, finding a stale item again by its titles |
| `Modules/SystemModules.swift` | `FrontAppModule.menu` (reads, keeps the read for `press`) and `onEvent("press")` |
| `Support/MenuExtras.swift` | the menu bar's other items, pure: `MenuExtra`, names, `hide`, the state with its `lines`, cutting pictures from a `MenuBarPicture` |
| `Support/MenuExtrasReader.swift` | their Accessibility side and the photograph: `AXExtrasMenuBar` of every app at once, bario's own on the main thread, `press`, the "Menubar" window and 26's item windows, PNGs |
| `Modules/MenuExtrasModule.swift` | `menuWillOpen` (reads, photographs, writes the pictures under `~/Library/Caches/bario/menu-extras/<item>`), `press` |

## Rules that are easy to break

- **Only `menu` opens a menu.** A click does what its item's `on-click` says; one with none opens
  nothing, whatever menu the item has (`FrameLoop.menuItem(forClickOn:)`, `BarController.handle`).
  Moving onto another item while a menu is open switches only to items whose click is `menu`. The
  controller runs a `menu` click at once, before the module hears the click, so a busy module
  cannot hold the menu up. Modules and socket subscribers still hear every click.

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
- **A module can read fresh as its menu opens.** `preparesMenu` (nonisolated, false by default)
  makes `ModuleHost.openMenu` ask `menuWillOpen` and merge its patch before the first render,
  which waits for it (`MenuSlot.prepareTask`, `canRenderMenu`) up to the menu budget; a later
  answer is merged when it comes. Only modules that say so pay the hop.
- **A menu goes when its anchor does**: the anchor must be in its bar's target scene, not leaving,
  and the bar showing. `layOut` returning false is what closes it.

## Submenus

`NodeActions.submenu` holds them, so a node with one is a control and its submenu travels with
its actions into the scene (it is never laid out there). `FrameLoop.submenus` is the chain below
`menu`, one per level; `openMenus` is both. A submenu's content is not rendered on its own: it is
taken from the root's render, walking each submenu's `row` (`FrameLoop.content(of:)`), so every
new render of the root reaches every level, and laying the root out again lays every submenu out
after it (`presentMenus`).

- **A submenu closes when its row changes, not only when it goes.** `Menu.rowNode` is the row as
  it was when it opened, less its submenu; a render that puts another row at that path closes it.
  An Option swap keeps the rows where they were, which is what keeps an app's submenus open
  through one.
- **Route by point, not by window.** A submenu's window overlaps its parent's edge by its reach,
  and the window server gives a press on transparent pixels to the window anyway. The controller
  asks `menuTarget(at:)`, deepest panel first, whichever view heard the event.
- **Only the root's window is key** (`MenuPanel(takesKeys:)`). A submenu's that could become key
  would take it from the root on a click, and the root closes when it resigns key.
- **Aiming waits on moves, not frames.** `updateMenuHover` runs after every frame with the pointer
  standing still; only a move (`pointerMovedSinceHover`) can start or extend an aim, and a pending
  one is left alone until its `aimDelay` timer, so frames do not reset the wait.
- **Scroll is kept in range by layout.** `Menu.scroll` is whatever the wheel made it;
  `BarLayout.finish` clamps it to the content's overflow, and `reveal` (the keys' hover) moves it
  to show a row. The panel already clips content to its box.

## The front app's menus

`front-app`'s `menu` reads the frontmost app's menu bar every time it renders (on opening, and on
a write to anything it read: its own key, `/modifiers.option`). The read is 5–11 ms warm; the menu
render budget is 250 ms (`ModuleHost.menuRenderBudget`), the read's own deadline 150 ms, and each
AX message 100 ms. `press` uses the elements of the last read, by path; the rows' paths come from
the same read, so they agree. Pressing is detached from the actor with a 1 s wait.

- **Option variants are guessed** (`AppMenus.isAlternate`): AX marks nothing on macOS 27. Same
  key, same modifiers plus ⌥, same first five characters of title; ⌘H/⌥⌘H excepted. Swapped in
  place while Option is held, so indices do not move.
- **`modifiers` is bario's key in the store**, like `wallpaper`. The controller writes it on any
  change it sees: the global flags monitor (Accessibility), the pointer poll over a bar, and the
  open menu's key view (`MenuView.flagsChanged`).
- **No AX in tests.** Everything an app's menus become is in `AppMenus`, pure, and tested from
  `AppMenuItem`s; the reader and pressing are not covered.

## The menu bar's other items

`menu-extras` lists every app's status item and the system's own, read through Accessibility as
its menu opens (`menuWillOpen`), with pictures cut from the window server's "Menubar" window. See
DESIGN.md §8. Measured on macOS 27, with 26.6's differences after:

- **Asking every app is cheap once.** ~130 ms the first time (the messages to each app are set up
  then), ~3 ms after; the start's poll pays the first. The photograph is ~30 ms with its listing.
- **No item has a window.** All of them are drawn into one window per display, layer 24, titled
  "Menubar", owned by the window server; `SCContentFilter(desktopIndependentWindow:)` photographs
  it under the cover, transparent around black (or white) pictures.
- **On macOS 26.6 every item has.** The "Menubar" window is there but blank where the items are;
  each item is a window of its own at status level (layer 25, just under the cover), all of them
  owned by Control Center whichever app the item is ("Item-0", "BentoBox-0", "Clock"). So
  `photograph` takes one display photograph of the menu bar's frame with only the "Menubar"
  window and those over it (`SCContentFilter(display:including:)`, a clear background): the same
  picture on both, ~20 ms however many items. Each window photographed alone was ~15 ms an
  item, past the menu's 250 ms with a full menu bar. Missing them leaves every item its app's
  icon. `backgroundColor` built with `CGColor(red:…)` trapped in ScreenCaptureKit; `.clear` is fine.
- **Control Center on 26.6 lists items it does not show:** no title, description or identifier,
  no size, below the bottom of the screen. They would be rows called "System" with Control
  Center's icon; an item with no size is left out.
- **A picture's file is named for its bytes.** `CoreTextMetrics` caches an icon's size by path,
  so a changed picture needs a new path; files no item shows go at the next read.
- **bario's own item is the main thread's.** Accessibility asked of this process calls straight
  into AppKit on the asking thread, and pressing from another traps
  (`BSServiceMainRunLoopQueue assertBarrierOnQueue`). It is read in `ownItems` and pressed with
  `DispatchQueue.main.async`; its NSMenu then tracks on the main thread, the bar standing still
  until it closes, and, opened without activating bario, it does not hear Escape.
- **Not covered by tests:** reading, photographing and pressing. The names, `hide`, the lines,
  the cuts and the template test are, from `MenuExtra`s and synthetic pictures.

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
  `--menu app/1/0` opens row 1's submenu too, and row 0's in that.
- `bario menu wifi` on a running bar opens it from the socket; `bario menu` closes whatever is open.

## Tests

`MenuTests.swift`: templates (`each`, `if`, absolute and quoted slots), KDL and JSON for controls,
config errors, the verbs and confinement; the cascade path and inheritance, hover only on controls,
stretch, slider growth, separator margins, placement and clamping, the window's style; and the frame
loop with `RecordingMenuSurface`: opens after its first render, nil opens nothing, renders only while
open, eases out then closes, the bar is shut and the item `:open`, hover switching, the anchor leaving,
toggling, key hover, and a drag's value surviving until the next render.

`SubmenuTests.swift`: `submenu` in KDL, JSON and templates; `menu menu` and node `:open`;
placement beside, flipped, kept on the display; cut to fit and scrolled; the chain in the frame
loop (opening on hover, closing on another control, aiming, keys, closing together, a render
reaching it); shortcuts, Option variants, separators and the tree an app's menu bar becomes.

Not covered by tests: the AppKit window (key status, Escape, the glass view), and Accessibility
(reading another app's menu bar, pressing its items), which only a real window server and app show.
