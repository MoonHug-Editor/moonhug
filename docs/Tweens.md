# Tweens

## Usage

```odin
// Initialization and loop
tween_init()           // call during init
tween_tick_running()   // call in main loop to tick tweens every frame

// Tweens can run directly
tween_run :: proc(tween: ^TweenUnion, ctx: TweenContext) -> bool

// Or via key:string
tween_register :: proc(key: string, tween: ^TweenUnion) // JSON-marshals the tween and stores the raw bytes under `key`.
tween_run      :: proc(key: string, ctx: TweenContext) -> bool // JSON-unmarshals a fresh copy into a new `TweenRunning` node, so the same tween can be fired multiple times concurrently without shared state
```

## Package layout

```
packages/tween/core    tween_core: Tween base, Status, TweenContext
packages/tween/nodes   tween_nodes: leaf variants (move/rotate/scale)
packages/tween         the generated TweenUnion, composites, Runner + API,
                       TweenPlayer component, gen/ (tween_gen), tests/
```

`TweenPlayer` is the package's own component holding authored tweens
(`animations: [dynamic]TweenUnion`) — the tween tests run against it, so the
suite never depends on another package's components.

Variant packages import `moonhug:packages/tween/core` — never
`moonhug:packages/tween`, because the generated union imports every variant
package and that would cycle.

## Add New Tween Types

In any package (leaf variants only — children fields need `TweenUnion`,
which only `packages/tween` can name):

```odin
import tween_core "moonhug:packages/tween/core"

@(typ_guid={guid="..."})
TweenNew :: struct {
    using base: tween_core.Tween, // the generator finds variants by this field
    // custom data
}

// same file, tick_* naming is picked up by the generator; the concrete type
// is the parameter — tween_gen emits the TweenUnion adapter
tick_TweenNew :: proc(self: ^TweenNew, delta_time: f32, ctx: tween_core.TweenContext) -> tween_core.Status {
    // see packages/tween/nodes for examples
}

// optional, for variants owning heap
tween_free_TweenNew :: proc(self: ^TweenNew) { }
```

Inside `packages/tween` itself (composites), tick/free procs take
`^TweenUnion` and wire directly — see composites.odin.

## Core concepts

```
TweenUnion      — tagged union of all tween variants (no_nil)
Tween           — base struct embedded in every variant (delay, await, status)
TweenContext    — runtime context passed to each tick (subject transform handle)
TweenRunning    — linked-list node wrapping a live TweenUnion + TweenContext
tween_lib       — named registry of serialized tweens (key → JSON bytes)
```

A tween is a **node tree** — composites (`Parallel`, `Sequence`) own children `TweenUnion` collections, leaf nodes animate a single transform property. All variants share the `Tween` base via `using`.

## Type system

```odin
Status         :: enum { Pending, Running, Done }   // tween_core, TweenStatus aliases it
TweenContext   :: struct { subject: Transform_Handle }

// the runner's dense dispatch tables, sized by the TypeKey enum,
// filled by the generated __tween_ticks_init
_tween_runner.ticks : [len(TypeKey)]proc(task: ^TweenUnion, delta_time: f32, ctx: TweenContext) -> Status
_tween_runner.frees : [len(TypeKey)]proc(task: ^TweenUnion)
```

Each variant registers its tick/free procs by `TypeKey` at init time. `_tween_tick_child` dispatches through the table using `reflect.union_variant_typeid`.

## TweenUnion variants

```odin
TweenUnion :: union #no_nil {
    Tween,
    Parallel,
    Sequence,
    TweenMoveToLocal,
    TweenRotateToLocal,
    TweenScaleToLocal,
}
```

### Base

```odin
Tween :: struct {
    delay:         f32,
    is_await:      bool,
    delay_elapsed: f32 `json:"-"`,   // runtime only
    status:        TweenStatus `json:"-"`,
}
```

`delay` is consumed before the variant's own tick logic runs. `tween_has_delay` increments `delay_elapsed` and returns `true` while the delay is still pending.

### Composites

| Type | Behaviour |
|---|---|
| `Parallel` | Ticks all children every frame; done when **all** children are done |
| `Sequence` | Ticks children in order; done when the **last** child is done |

Both own a `[dynamic]TweenUnion` children slice freed by their `tween_free_*` proc.

### Leaf nodes

| Type | Fields | Interpolation |
|---|---|---|
| `TweenMoveToLocal` | `position [3]f32`, `duration f32` | Linear lerp on `transform.position` |
| `TweenRotateToLocal` | `rotation [4]f32`, `duration f32` | `quaternion_slerp` on `transform.rotation` |
| `TweenScaleToLocal` | `scale [3]f32`, `duration f32` | Linear lerp on `transform.scale` |

All leaf nodes capture `from` on the first tick (when `elapsed == 0`). If `duration == 0` the value is set instantly and returns `.Done`.

