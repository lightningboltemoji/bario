# 01 — Core: package split, JSONValue, content model

## Why this first

Everything downstream is a function of two data types: the **state** that providers write
(arbitrary JSON) and the **content tree** that modules render (DESIGN.md §2). Both travel over
the socket, through WASM linear memory and out of built-in Swift modules, so they have to be
one vocabulary with one decoder. Nothing else can be built until they exist.

The package also has to stop being a single probe executable. (The probe has since been
removed; everything it proved now lives in `bario`.)

## Package layout after this step

```
Sources/BarioKit/      library — everything reusable
  Support/             logging, NSScreen helpers, PNG, single-instance lock
  Capture/             ScreenCaptureKit backdrop strip (moved verbatim from the probe)
  Model/               JSONValue, Node, RenderResult
Sources/bario/         executable — CLI + daemon entry point (skeleton here)
Tests/BarioKitTests/   swift-testing
schema/content.json    the published contract for PDK authors
```

The probe's capture path is the bar's capture path, so it moves into the library rather than
being duplicated.

## `JSONValue`

A six-case enum (`null`, `bool`, `number`, `string`, `array`, `object`), `Sendable` and
`Hashable`, `Codable` by hand so that:

- integral numbers re-encode as integers (`{"pct": 43}` stays `43`, not `43.0`);
- `object` keeps a plain dictionary, because the state store is a tree of these.

Three operations the rest of the system needs:

- **path access** — `store["battery.pct"]`, dotted keys into nested objects, used by format
  strings and by the socket's `get`/`set` targets;
- **deep merge** — `merging(_:)`: objects merge recursively, scalars and arrays replace
  wholesale, and an explicit `null` *deletes* the key. This is the semantics of the socket's
  `set` op and of a WASM module's state patch, so it is defined once, here;
- **write at a path** — `setting(path:to:)`, creating intermediate objects as needed.

## Content model

One node = exactly one kind key plus optional `class` and `id` (DESIGN.md §2):

```json
{ "meter": { "value": 0.73, "width": 24 }, "class": ["bar", "wide"], "id": "pct" }
```

Swift shape:

```swift
struct Node { var kind: NodeKind; var id: String?; var classes: [String] }
indirect enum NodeKind {
  case text(String), icon(IconSpec), meter(Meter), graph(Graph)
  case row(Container), column(Container), spacer(Spacer)
  case canvas(CanvasNode), raster(RasterNode)
  case custom(String, JSONValue)          // registered by a renderer module, §9.2
}
```

Decoding rules, which are the schema in executable form:

- exactly one kind key; zero is an error, two is an error naming both;
- an unknown kind key is **not** an error — it decodes to `.custom`, because renderer modules
  add node types at runtime (§9.2) and the decoder cannot know the registry;
- `class` accepts a string or an array of strings, `id` a string;
- shorthands: `{"text": "hi"}` and `{"text": {"value": "hi"}}`; `{"icon": "wifi"}` and
  `{"icon": {"file": "..."}}`; `{"spacer": {}}` and `{"spacer": null}`.

`canvas.ops` and `raster.source` stay as `JSONValue` until increments 12 and 16 give them
typed forms — the display list is data that the host paints, and the parser for the op set
belongs with the painter that consumes it.

`RenderResult` is `{ content, classes, tooltip, visible }` with `visible` defaulting to true.

## Validation

`schema/content.json` (JSON Schema draft 2020-12) is the published contract that PDK authors
and socket clients read. The enforcement point in the running system is the Swift decoder:
it rejects everything the schema rejects and reports the JSON coding path, so there is no
second validator to keep in sync.

## Tests

Round-trip every node kind; the design document's own battery example decodes; malformed
nodes produce the intended errors; merge and path semantics including `null`-deletes.
