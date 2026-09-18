# 00 — Roadmap

DESIGN.md phases 1–6 broken into increments that each build, test and (from 06 on) run.
This file is the plan; each numbered file is the note written *before* that increment was
implemented. IMPLEMENTATION.md is the running high-level map.

| # | increment | design section | phase |
|---|---|---|---|
| 01 | core: package split, `JSONValue`, content model, capture moved into `BarioKit` | 2 | 1 |
| 02 | config: KDL parser + `Config` model | 11 | 1 |
| 03 | style: CSS-subset tokenizer, parser, selectors, cascade, typed properties | 7 | 1 |
| 04 | state store + module protocol + format strings + `text`/`clock` | 2, 3 | 1 |
| 05 | scene + flex layout + notch split + overflow | 6 | 1 |
| 06 | painter, hole `punch`/`keep`, display link, `bario --run` | 8, 10 | 1 |
| 07 | built-in modules: `front-app`, `battery`, `wifi`, `volume`, `net`, `cpu`, `mem`, `data` | 3 | 2 |
| 08 | `exec` module (interval and watch) | 3 | 2 |
| 09 | live reload of config + style, `.error` bubble, `.app` bundle | 11 | 2 |
| 10 | socket server and the wire protocol | 4 | 3 |
| 11 | `bario` CLI verbs | 4 | 3 |
| 12 | `canvas` node and the display-list painter | 9.1 | 4 |
| 13 | `WasmEngine` on WasmKit, bytes ABI, host imports, permissions, budgets | 5 | 4 |
| 14 | PDKs (Rust + C) and the worked `weather` module | 5 | 4 |
| 15 | interaction: click-through, item events behind Option, `on-click`/`on-scroll`, layout transitions | 8 | 5 |
| 16 | custom renderers: registered node types, `draw`/measure, `request_frame`, `ring`, `raster` | 9.2, 9.3 | 6 |
| 17 | the frame loop: invalidation, separate style/layout/present stages, first-frame rule | 7, 10 | — |
| 18 | the compositor: a layer tree per bar, the commit stage, raster keys, the hole as a mask, `CARenderer` offscreen; renderers drawn at commit, `animation`, shared surfaces | 9, 10 | 7 |

All eighteen are implemented, and phases 1–7 of DESIGN.md §12 are delivered. Phase 7's shared
surfaces rest on one deprecated call, `bootstrap_register`, isolated in `CBarioShim`, because an
app a user opens has no launchd-given Mach service ([18-compositor.md](18-compositor.md),
DESIGN.md §13). Two things the
design flagged as unknowns was measured rather than assumed, and the answer is recorded where
it belongs:

- **click-through on transparent pixels does not work** (§13's biggest unknown) — a real click
  posted into a fully transparent hole still reaches the cover, so the cover only takes events
  while Option is held over it. See [15-interaction.md](15-interaction.md).

Out of scope for this pass (DESIGN.md §12.8 "Later"): popovers, overflow catch-all item,
`NSAccessibility`, WIT/Component Model.

Deviations from the design, each argued where it is made: the WASM ABI packs `(ptr, len)` into
one `i64` and returns host bytes as length-then-read ([13-wasm.md](13-wasm.md)); KDL accepts
bare `true`/`false`/`null` ([02-config-kdl.md](02-config-kdl.md)).
