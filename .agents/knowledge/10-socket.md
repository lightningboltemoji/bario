# 10 — The socket

DESIGN.md §4. Cross-language means a Unix domain socket carrying newline-delimited JSON,
because every language has both. XPC would be Apple-only and exclude shell scripts;
distributed notifications have no reply channel.

## Transport

`IPC/SocketServer.swift`: POSIX sockets driven by `DispatchSource`, on their own queue, not
Network.framework — a listener, an accept source, and one read source per connection is about
as much machinery as this needs, and it keeps the framing honest.

- Path `$TMPDIR/bario/sock`, mode 0700 on the directory; `BARIO_SOCK` overrides it. If that
  path would exceed `sun_path`'s 104 bytes (a long `TMPDIR` is normal under a sandbox), it
  falls back to `/tmp/bario-<uid>/sock` and says so.
- A socket file left behind by a crash is probed with a connect before being unlinked, so two
  instances can never quietly steal each other's socket.
- One JSON object per line, UTF-8. Lines are capped at 8MB so a runaway writer cannot exhaust
  memory; a connection that overruns is closed with an error.

## Verbs

| op | fields | effect |
|---|---|---|
| `set` | `target`, `data` | deep-merge `data` into the store under `target` |
| `content` | `target`, `content`, `classes?`, `tooltip?` | replace a `data` item's content tree |
| `emit` | `name`, `payload?` | broadcast an event to subscribed modules and connections |
| `get` | `target?` | reply with the subtree, or the whole store |
| `subscribe` | `topics` | stream matching events back on this connection |
| `unsubscribe` | `topics?` | stop, or stop everything |
| `style` | `css` | apply a stylesheet delta live, for iterating on looks |
| `reload` | | re-read config and stylesheet |
| `ping` | | `{"ok": true, "version": "…", "pid": …}` |
| `frame` | `surface`, `index?` | a shared surface's producer drew into one of its pair ([18-compositor.md](18-compositor.md)) |

Replies echo `id` when the request carried one: `{"id": 2, "ok": true, "value": …}` or
`{"id": 2, "ok": false, "error": "…"}`. A request with no `id` gets no reply, which is what
makes a one-shot `set` from a shell script a single `write` and a close.

## Topics

`state:battery.*`, `click:volume`, `system:wake`, `*`. One matcher, `TopicPattern`, already
used by the store's own subscriptions — a kind prefix and a dotted glob. State changes are
published from the store's change stream; clicks arrive in increment 15; `emit` publishes
under `event:<name>`.

## Where the tiers meet

The verbs here are the verbs a WASM module sees as host imports (§5), deliberately: a bubble
prototyped as a shell script and `bario set` can be promoted to a WASM module without
changing the item's config or its styling.

`BarioService` is the verb implementation, separate from the transport, so the whole protocol
is testable without a socket: it holds the store, the module host, and two closures for
`reload` and `style`.

## Trust

The socket is reachable only by the user, which is the same trust level as the config file —
and the config file can already run commands. No further authentication in v1, as the design
says. What the server does enforce is shape: an unknown op, a missing field or a malformed
line is an error reply, never a partial write.

## Tests

`BarioService` directly for every verb, including errors. Then the real socket end to end: a
client connects, sets, gets its value back, subscribes and receives a change written by
someone else, and a second connection's traffic does not leak into the first's subscription.
