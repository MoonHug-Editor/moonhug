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

## Add New Tween Types
```odin
TweenNew :: struct{
    base:Tween, // important, generator will find tween types by searching for base:Tween
    // custom data
}

// optional in same file as TweenNew, tween_free_* naming is picked up by generator
tween_free_TweenNew :: proc (tween:^TweenUnion) {
    // see other tween_free_* for examples
}

// optional in same file as TweenNew, tick_* naming is picked up by generator
tick_TweenNew :: proc (tween:^TweenUnion, delta_time:f32, ctx:TweenContext) -> TweenStatus {
    // see other tick_* for examples
}
```

## Core concepts

```
TweenUnion      — tagged union of all tween variants (no_nil)
Tween           — base struct embedded in every variant (delay, await, status)
TweenContext    — runtime context passed to each tick (subject transform handle)
TweenRunning    — linked-list node wrapping a live TweenUnion + TweenContext
tween_lib       — named registry of serialized tweens (key → JSON bytes)
```

A tween is a **node tree** — composites (`Parallel`, `Sequence`) own children `TweenUnion` colelctions, leaf nodes animate a single transform property. All variants share the `Tween` base via `using`.

## Type system

```odin
TweenStatus    :: enum { Pending, Running, Done }
TweenContext   :: struct { subject: Transform_Handle }

TweenTickProc  :: proc(task: ^TweenUnion, delta_time: f32, ctx: TweenContext) -> TweenStatus
TweenFreeProc  :: proc(^TweenUnion)

tween_tick_procs : [TypeKey]TweenTickProc   // dispatch table, filled by __tween_ticks_init
tween_free_procs : [TypeKey]TweenFreeProc
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

