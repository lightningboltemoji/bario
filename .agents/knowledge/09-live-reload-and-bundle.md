# 09 — Live reload, the error bubble, and the `.app`

The two things that finish phase 2: editing the config with the bar running, and a stable
bundle identifier for Screen Recording permission.

## Watching two files

`FileWatcher` watches a path with `DispatchSource.makeFileSystemObjectSource`, but on the
*containing directory* as well as the file, because every editor worth using replaces a file
rather than writing into it — vim renames, and the fd the watcher holds then points at a file
nobody will ever read again. Watching the directory catches the replacement; re-arming on
`.rename` and `.delete` catches the rest. Changes are debounced by 120ms, so one save is one
reload even when the editor writes twice.

`config.kdl` and `style.css` are watched even when they do not exist yet, so creating one for
the first time does the right thing without a restart.

## Reload is atomic, and failure is visible

```
reload() → Theme.load()
   ok    → frame loop inputs: stylesheet, config, banner cleared → style, everywhere
         → ModuleHost.load(items)   (instances with unchanged options are kept)
   error → keep the last good theme, show the message on the bar
```

DESIGN.md §11: "Errors show up as a red `.error` bubble on the bar with the message, and the
last good config stays live." The bubble is not a special case in the painter — the
controller synthesises one `ItemConfig` named `bario-error` and one `ItemState` carrying the
message, and hands them to the scene builder with everything else. It therefore cascades,
lays out, overflows and paints like any other item, and `item.error` in the stylesheet is all
that styles it.

Reloading is also what `SIGHUP` does, and what the socket's `reload` verb will do in
increment 11. One method, three callers.

A style invalidation always re-lays out: layout is a function of the styles, and the
expensive half — text and symbol measurement — is cached by `(string, font)` in
`CoreTextMetrics`. The reverse is what the stage split buys: a layout invalidation does not
re-cascade ([17-frame-loop.md](17-frame-loop.md)).

## The `.app`

`make app` builds a release binary and assembles `bario.app` around it, from
`Resources/Info.plist`:

- `CFBundleIdentifier` `zip.tanner.bario` — the stable identity Screen Recording permission
  attaches to (§13). The probe's terminal-attached permission is a dev convenience only;
  granted to a terminal, it is granted to everything that terminal ever launches.
- `LSUIElement` true, so there is no Dock icon and no menu of our own.
- `NSLocationWhenInUseUsageDescription`, without which macOS never shows the prompt the
  `wifi` module needs for an SSID, and the module quietly stays SSID-less forever.
- `CFBundleShortVersionString` and `CFBundleVersion`, stamped by `make app` from `git describe`
  and the commit count into the bundle's *copy* of the plist. `barioVersion` reads the first one
  back through `Bundle.main`, which is why the version is the git tag and no Swift file holds a
  number — and why a binary run out of `.build`, with no bundle around it, reports `dev`.

`make install` copies it to `/Applications`. The bundle runs `bario --run`; every other verb
still works from the binary inside it, which is what makes `bario set …` from a shell script
talk to the same process.

## Tests

`FileWatcher` against a real file: a write fires, a rename-into-place fires, a delete then
re-create fires, and two writes in quick succession fire once. Reload is tested end to end
through the theme loader: a broken config keeps the previous one and produces a message with
a line number; a fixed config takes effect.
