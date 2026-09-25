# 08 — `exec`

DESIGN.md §3, tier 2: the escape hatch that makes everything else optional. Two shapes, as
waybar has them.

- **Interval.** Run the command every `interval`, read its stdout, write it to the store.
- **Watch.** `interval="watch"`: keep the command running and read lines as they arrive. Each
  line is one update. This is how a spaces indicator from AeroSpace or yabai works.

```kdl
item "spaces" module="exec" interval="watch" {
  command "aerospace" "list-workspaces" "--monitor" "focused" "--format" "%{workspace}"
}
item "weather" module="exec" interval="10m" {
  command "curl -s 'wttr.in/Vancouver?format=%t'"
}
```

`command` as a list is an argv, executed directly. `command` as one string goes through
`/bin/sh -c`, because that is what people write and what `on-click="exec …"` will need in
increment 15.

## What the output means

Stdout is either plain text or, if it parses, JSON, which is written into the store as-is
(§3). Precisely:

- a JSON **object** is merged into the item's subtree, so any key the script invents is
  addressable from a format string;
- anything else — plain text, a JSON array, a bare number — lands under `text`, which is also
  the default format, so `echo hello` is a working module;
- waybar's own keys keep their meaning when they appear: `text`, `alt`, `tooltip`,
  `percentage`, and `class` (a string or a list) becomes the item's state classes. Adopting
  that vocabulary means existing waybar scripts work unchanged.

A `content` key is a whole content tree, and the item shows it, as a `data` item shows one
pushed over the socket. The store replaces it whole on every line.

Every run also writes `exit-code`, and `stderr` when there was any. A non-zero exit adds the
`.error` class and puts stderr in the tooltip rather than replacing the last good content —
the same rule modules follow everywhere else.

## Not taking the bar down

- Interval runs get a budget (`timeout`, default 10s); over it, the process is terminated,
  then killed, and the item goes `.stale`.
- A watched process that exits is restarted with exponential backoff from 0.5s to 30s, and
  the backoff resets once it has run for a while. `max-backoff` lowers (or raises) that 30s
  ceiling: a watch on a daemon that fails fast when the daemon is down — `emira watch` exits
  69 — can afford `max-backoff="5s"`, and then finds the daemon within 5s of it coming back.
  A command that cannot start at all becomes one `.error` bubble, not a restart storm.
- An exit is waited for through `terminationHandler`, never `waitUntilExit()`. Without a
  handler, Foundation delivers the exit through the run loop of the thread that launched the
  process, and `waitUntilExit()` on that thread waits for the delivery, not just the exit. On a
  concurrency thread it waited for good: a watch sat there for minutes, with `isRunning`
  already false, while `emira watch` had long since exited 69 and been reaped. With a handler
  set, Foundation marks the exit delivered itself and calls the handler from a dispatch queue.
- A watch's stdout is read by a `readabilityHandler` of its own (`ExecModule.lines(of:)`), never
  `FileHandle.bytes`. Every `AsyncBytes` in a process reads on one serial queue, with a blocking
  `read`, so beside a quiet `emira watch` a second watch got its first line and then nothing until
  emira spoke again. **Measured:** a quiet watch and one printing a line every 500ms left the second at
  its first line of six; each reading its own pipe, it gets all six.
- `stop()` terminates the process group, so a watched `sh -c` does not leave its child behind.
- The environment is inherited plus `BARIO_ITEM`, so one script can serve several items. A bario
  that launchd started (Finder, `open`, a login item) has first taken on the login shell's
  environment (`LoginShell.adopt()`, from `main.swift`), so what it inherits is what a terminal
  would have: launchd's `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`, and under it `emira watch`
  exited 127 in Bario.app while working under `bario --run`, with no bubble to say so. The shell
  runs `-l -i -c`, and its output is read up to a closing marker rather than to the end, because
  a startup file can leave something running that holds stdout. 5s at most, then launchd's.

## Tests

Plain text, JSON object, waybar-shaped JSON with classes, a non-zero exit, a command that does
not exist, a watched command emitting several lines, one doing so beside a watch that has gone
quiet, a watched command that exits being restarted, and one that fails fast being retried at
`max-backoff` and picked up within it once it works again. `LoginShellTests` runs a stub shell
that prints around the environment and leaves a child holding stdout, and one that never
answers. All of them run real `/bin/sh`, because the point of this module is that it runs real
commands.
