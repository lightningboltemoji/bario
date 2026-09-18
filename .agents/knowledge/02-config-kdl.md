# 02 — Config: a KDL parser and the `Config` model

## Why a parser of our own

DESIGN.md §11 picks KDL because "a bar is a tree" and KDL nests, takes arguments and
properties, and reads well unquoted. The fallback it names is TOML, "if the KDL parser
situation in Swift turns out worse than expected". Rather than take a dependency on someone
else's parser for ~600 lines of grammar, bario parses KDL itself, for the same reason it
parses its own CSS subset (§7): the error messages are the product. A config error has to say
*line 14, column 9: `interval` takes a duration like "10m", "watch" or a number of seconds*,
and that only happens if positions survive from the tokenizer to the typed model.

## Dialect

KDL 2.0, plus one deliberate deviation: bare `true`, `false` and `null` are accepted as the
keywords `#true`, `#false`, `#null`. KDL 2.0 reserves those bare words precisely so that a v1
document does not silently mean something else, but DESIGN.md's own example config writes
`hidden-until-set=true`, and a config language that rejects that is not the one the design
describes. Everything else is 2.0: `#`-prefixed keywords, `#"raw strings"#`, `"""multi-line
strings"""` with indentation stripped from the closing line.

Supported: nodes with names, arguments, properties and children blocks; `;` and newline
terminators; `\` line continuations; `//`, `/* nested */` and `/-` slashdash comments;
`(type)` annotations (parsed, carried, currently unused); decimal, hex, octal and binary
numbers with `_` separators; the full escape set including `\u{...}`.

## Layers

```
text ──▶ KDLLexer ──▶ KDLParser ──▶ [KDLNode] ──▶ Config
        tokens+pos    nodes+pos      tree          typed, validated
```

`KDLNode` keeps `name`, `arguments`, `properties` (order-preserving), `children` and the
source position of each, so every later error can point at a line.

## KDL → JSON, the canonical mapping

Modules take their configuration as JSON: a built-in gets a `JSONValue`, and a WASM module
gets those same bytes through `init(ptr, len)` (DESIGN.md §5). So one mapping is defined once
and every module option travels through it unchanged, which is what lets an item be promoted
from `exec` to WASM without touching its config.

A node becomes:

- properties become object keys;
- children become object keys named after the child node, with the same rule applied
  recursively; repeated child names collect into an array;
- arguments become the key `args`, *unless* the node has no properties and no children, in
  which case the node simplifies to its argument (one argument) or to an array of them
  (several) — so `low 20` is `20`, `permissions "net" "exec"` is `["net", "exec"]`, and
  `config city="Vancouver"` is `{"city": "Vancouver"}`.

## `Config`

```
Config
  bars: [BarConfig]            one per `bar` node; a display picks the most specific match
  renderers: [RendererConfig]  renderer "ring" path="…"
BarConfig
  display: DisplayFilter       .any | .builtIn | .external | .named(String)
  padding, gap, height?, align, hole, notch policy, elements
Element = .item(ItemConfig) | .group(GroupConfig) | .spacer(grow) | .notch
ItemConfig
  name, module, format?, priority, sizing, interval?, on-click/-scroll/-right-click,
  style?, hiddenUntilSet, content: Node?,
  options: JSONValue                            ← everything the module defines itself
```

Known keys are lifted into typed fields and validated; everything else stays in `options`,
because DESIGN.md is explicit that slot and option names are per module. An option bario does
not recognise is therefore *not* an error — the module decides.

`DisplayFilter.matches` scores a display so "most specific wins" is a sort, not a special
case: exact name 3, built-in/external 2, unfiltered 0.

Durations parse from `"watch"`, a bare number of seconds, or `500ms` / `2s` / `10m` / `1h`.

## Content in the config

An item's `content { … }` child is a content tree written as KDL (`Config/ContentKDL.swift`),
for what is known when the config is: a `text` item shows it, and a `data` item shows it until
something is pushed. It is not a second model. The KDL is turned into the JSON a push would
carry and decoded by the same `Node` decoder, so the two cannot drift:

| KDL | JSON |
|---|---|
| `text "73%" class="pct"` | `{"text": "73%", "class": "pct"}` |
| `meter value=0.73 width=24` | `{"meter": {"value": 0.73, "width": 24}}` |
| `graph width=30 { values 1 4 2 }` | `{"graph": {"width": 30, "values": [1, 4, 2]}}` |
| `row gap=4 { icon "wifi"; text "home" }` | `{"row": {"gap": 4, "children": [{"icon": "wifi"}, {"text": "home"}]}}` |
| `raster width=80 { source surface="wave" }` | `{"raster": {"width": 80, "source": {"surface": "wave"}}}` |

`id=` and `class=` belong to the node, not its payload. A kind given an argument and properties
together is an error (write `value=` beside the others), and so is `content` beside `format=`,
on a group, or holding more than one node. Children of a row are decoded one at a time, so an
error names the line of the node that has it. A `canvas` display list does not fit KDL well
and is pushed or rendered by a module instead.

## Discovery

`~/.config/bario/config.kdl`, then `~/Library/Application Support/bario/config.kdl`
(DESIGN.md §7). `BARIO_CONFIG` overrides both, which is what the tests and `--config` use.
A missing file is not an error: bario falls back to a built-in default config, so a first run
shows a clock and a front-app bubble rather than nothing.

## Tests

The design document's own example config parses into the expected tree; each KDL syntax
feature has a case; malformed documents report the right line and column; the JSON mapping
matches the table above; durations and display filters round-trip.
