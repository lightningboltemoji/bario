# 11 — The `bario` CLI

DESIGN.md §4: "The `bario` CLI is a one-to-one wrapper" around the socket verbs. That is the
whole scripting story, and it is the same story a WASM module sees from inside, so learning
one teaches the other.

```sh
bario set battery '{"pct": 43}'      # merge state
bario set ci < status.json           # …or from stdin
bario content weather < tree.json    # push a content tree
bario emit refresh '{"why": "cron"}' # broadcast an event
bario get wifi                       # print a subtree
bario watch 'state:battery.*'        # stream events until Ctrl-C
bario style 'item { color: red }'    # a live stylesheet delta
bario reload                         # re-read config and stylesheet
bario ping                           # is one running, and which
bario frame wave 1                   # show the second of a shared surface's pair
```

One binary does both jobs (§1): `bario --run` is the daemon, everything else is a client. The
binary inside `bario.app` is the same one, so a script can call it wherever it lives.

## Shape

`IPC/SocketClient.swift` is a blocking request/response client — connect, write one line,
read one line — because a CLI has nothing better to do while it waits. `watch` is the one
exception: it subscribes and then streams until interrupted.

`App/CLI.swift` maps arguments onto requests, and does three things the raw protocol does not:

- **Reads stdin** when the payload argument is missing, so `bario set ci < status.json` and
  `echo '{"pct":9}' | bario set battery` both work.
- **Refuses to guess.** A payload that is not JSON is an error naming the argument, not a
  string silently stored where an object was meant. The exception is `emit`, whose payload is
  optional, and `style`, which takes CSS rather than JSON.
- **Says when nothing is listening**, with the socket path, instead of a connection error.

Exit codes: 0 fine, 1 the bar said no or is not running, 2 the command line was wrong.

`get` prints compact JSON to a pipe and pretty-prints to a terminal, so `bario get wifi | jq`
and `bario get wifi` both read well.

## Tests

The client against a real in-process server: every verb, stdin payloads, a bad payload, a
missing daemon, and `watch` receiving an event written by a second connection.
