# Tweens

Two representations, one per concern:

- **Authored**: a tween tree is one guid-tagged JSON value (`tween.Authored`).
  It lives in component fields (`animations: [dynamic]tween.Authored`), so
  component serialization, undo, prefab overrides and copy/paste treat it as
  a plain value. Children nest inside the parent's `"children"` array.
- **Live**: `tween_run` instantiates the blob into per-type pools. Nodes hold
  children as `Node_Handle` arrays, dispatch is an index into the registered
  desc table, and a finished run destroys its tree.

Node types register at runtime, so ANY package adds tween nodes — including
composites — with no codegen and no import restrictions.

## Usage

```odin
// Initialization: stock nodes register on the TweenNodesInit phase (fired by
// runnable binaries next to SerializationInit); tween_init() covers callers
// outside that flow (tests).
tween_init()
tween_tick_running(dt, {})   // main loop

// Build authored trees in code:
a := tween.authored(tween.Sequence{}, {
    tween.authored(tween.TweenMoveToLocal{position = {1, 0, 0}, duration = 0.5}),
    tween.authored(tween.TweenScaleToLocal{scale = {2, 2, 2}, duration = 0.5}),
})

// Run directly, or via a named prototype:
tween_run(&a, TweenContext{subject = handle})
tween_register("Anim0", &a)         // stores marshaled bytes
tween_run("Anim0", ctx)             // fresh instance per run

authored_destroy(&a)                // the value is owned
```

## Add new tween node types — from any package

```odin
import tween "moonhug:packages/tween"

@(typ_guid={guid="..."})
MyShake :: struct {
    using base: tween.Tween `inline:""`,
    strength: f32,
    // composites declare children — the runtime fills and frees the array:
    // children: [dynamic]tween.Node_Handle `json:"-"`,
}

@(phase={key=TweenNodesInit, order=1})
my_tween_nodes_init :: proc() {
    tween.register_node(MyShake, tick_MyShake)
}

tick_MyShake :: proc(self: ^MyShake, dt: f32, ctx: tween.TweenContext) -> tween.Status {
    // composites tick children via tween.tick_node(h, dt, ctx) and read
    // their status via tween.node_base(h)
    return .Done
}
```

`packages/plugin_example/tween_spinner.odin` is the reference. Rules:

- The struct embeds `tween.Tween` at offset 0 (the `using base` field).
- Runtime-only fields carry `json:"-"` — authored blobs never store them.
- `register_node` takes an optional `cleanup: proc(^T)` for node-owned heap
  beyond the children array.
- The type guid is the on-disk identity — never change it.

## Package layout

```
packages/tween         base vocabulary, runtime (registry, pools, run list),
                       stock leaves + composites, Authored + serialization,
                       TweenPlayer component
packages/tween/editor  the Tween Graph window
packages/tween/tests   the suite
```

The stock nodes register through the same public path foreign packages use
(a TweenNodesInit phase subscriber calling register_node).

## Semantics

- `Status :: enum { Pending, Running, Done }`
- `Sequence` ticks children in order and stops at the first not-Done child.
  `Parallel` ticks all children every frame. Both consume `base.delay` first.
- Leaf nodes capture `from` on the first tick (`elapsed == 0`). `duration == 0`
  applies the value instantly.
- `base.skip` prevents a root from starting and a child from ticking.
- Unknown node types (package not installed) fail the whole run — a
  half-instantiated sequence would misbehave silently. The authored blob is
  preserved either way, like unknown components.
- Subject refs inside blobs remap on copy/paste through the engine's
  ref-remap hook (registered at SerializationInit) — the typed walk cannot
  see into JSON.

## Authoring in code

```odin
a, ok := tween.authored_make(typeid_of(tween.Sequence))  // by registered type
child, _ := tween.authored_make(typeid_of(tween.TweenMoveToLocal))
tween.authored_add_child(&a.value, child)                 // ownership moves in
tween.authored_remove_child(&a.value, 0)                  // frees the child
tween.authored_retype(&a.value, typeid_of(tween.Parallel))

tween.registered_node_types()      // every registered type
tween.node_type_has_children(tid)  // composite or leaf
```

`authored_make` fails for unregistered types, and `authored_add_child` fails
on leaves. `authored_retype` resets every field to the new type's zero
values and keeps the node's children when the new type is a composite (a
leaf drops them).

## The Tween Graph window

The inspector row for an `Authored` field expands into the node's fields and
its children, each editable in place. The Graph button opens the same tree
on a canvas.

The selected node materializes into a typed instance by guid — the ordinary
inspector draws it, and a released edit marshals back into the blob as ONE
whole-component undo step. Selection is a path of child ordinals, so it
survives undo.

Structure is edited from the panel: `Change Type` on any node, `Add Child`
on a composite, `Delete Node` on any non-root — each one undo step. The
inspector row carries a swap button for retyping the root, and an empty
`Authored` slot (a fresh array element) offers `Set Type`. Every picker
lists the REGISTERED node types, so an installed package's nodes appear
without the editor knowing them.
