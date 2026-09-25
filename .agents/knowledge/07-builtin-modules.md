# 07 — The built-in modules

DESIGN.md §3, tier 1: configured with a format string and some options, each one chosen
because it replaces something the cover is hiding.

| module | source | state it writes |
|---|---|---|
| `front-app` | `NSWorkspace.frontmostApplication` + the activation notification | `name`, `bundle-id`, `icon` |
| `battery` | IOKit `IOPSCopyPowerSourcesInfo`, with a change notification | `pct`, `charging`, `plugged`, `time-remaining`, `icon` |
| `wifi` | CoreWLAN | `ssid`, `rssi`, `on`, `bars`, `icon` |
| `volume` | CoreAudio's default output device, with a property listener | `level`, `muted`, `device`, `transport`, `headphones`, `icon`, `level-icon` |
| `net` | `getifaddrs` counters on an interval | `rx`, `tx`, `rx-total`, `tx-total`, and rolling history for `graph` |
| `cpu` | `host_statistics` tick deltas | `load`, `user`, `system`, history |
| `mem` | `host_statistics64`, `kern.memorystatus_level` | `used`, `total`, `pressure`, `pressure-pct`, history |

`net`, `cpu` and `mem` grew time windows, content templates and presets in
[20-stats-widgets.md](20-stats-widgets.md), which also has their full list of keys.

## Push, not poll, wherever the system offers it

`front-app`, `battery` and `volume` are event-driven: they subscribe once in `start()` and
write straight into the store, and the host re-renders only the items that read what changed.
`poll()` still exists on them as the first read and as a safety net, but an idle bar with all
three on it runs no timers at all. `net`, `cpu` and `mem` are genuinely sampled, so they poll
on the item's interval (default 2s) and keep a rolling history for `{graph}`.

## Two things every module does

**Icons.** Each module writes an `icon` key holding an SF Symbol name, picked from the state
it just computed — `battery.75percent`, `wifi.slash`, `speaker.wave.2.fill`. That is what
makes `format="{icon} {pct}%"` from the design work without the user knowing any symbol
names, and it keeps the choice in one place instead of in everyone's config.

**Derived, roundable numbers.** `pct` is 0…100 and already rounded; `level` is 0…100; `rx`
and `tx` are bytes per second with a `rx-human` companion (`1.2 MB/s`) because a format
string cannot do unit scaling. The raw values stay too, so a `meter` node can use `pct/100`.

## The awkward corners, handled where they are

- **Headphones have no property of their own.** `volume` reads them from what there is: the
  built-in device's `hdpn` data source (the jack; on Apple Silicon it is a device of its own,
  on Intel a source on the built-in one, so the data source is listened to as well), Bluetooth,
  which is headphones far more often than not (`speakers="Kitchen"` names the exceptions), or a
  name with headphones, headset, AirPods or Buds in it. Then `icon` is the headphones' own
  symbol (`airpods.max`, `airpods.pro`, `beats.headphones`, `headphones`) and the item wears
  `.headphones`; `level-icon` keeps the speaker waves for a format that wants the level too.

- **Wi-Fi SSID needs Location Services** on macOS 14+ (§13). The module works without it: it
  writes `rssi`, `on` and `bars` regardless, leaves `ssid` unset, and sets `ssid-denied` so a
  config can say why. It asks for authorisation once and never blocks on the answer.
- **Battery time remaining** is `-1` while the system is still estimating; that becomes unset
  rather than a bubble reading "-1 min".
- **CPU** needs two samples to mean anything, so the first poll writes nothing but a baseline.
- **Now Playing and Spaces are deliberately absent** (§13): no public API, so they stay in
  `exec` territory.

## Where they live

`Sources/BarioKit/Modules/`, one file per subject area, all registered from
`ModuleRegistry.registerBuiltIns()`. The default config grows to the design's own example
once they exist, because that is the first thing a new user sees.

## Tests

Each module's pure parts are separated from its system call and tested directly: the battery
icon ladder, the Wi-Fi bars ladder, byte-rate humanising, the rolling history window, the CPU
delta maths against two synthetic samples. The system calls themselves are smoke-tested —
they must not crash or hang, and on this machine they must return something plausible.
