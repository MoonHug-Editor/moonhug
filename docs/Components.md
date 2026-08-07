# Components

The component data layer and its access contract. The contract is deliberately narrow so the storage layout can change (for example to SoA columns) without touching the code above it.

## Model

- A component is a plain struct registered with `@(component)`, stored in a fixed-size `Pool(T, N)` per type per world (`MAX` slots by default, smaller for capped types like Camera and Light).
- A `Handle` (index + generation + type key) is the durable reference. Generations catch stale handles after a slot is recycled.
- `Transform` owns the hierarchy and the per-object component list (`Owned` entries). Component structs embed `CompData` (owner, local id, enabled).

## Access contract

**Handles are what you store. Pointers are what you use, this frame only.**

- `pool_get(pool, h) -> ^T` resolves a handle. The pointer is valid until the component is destroyed — treat it as frame-local and re-resolve through the handle rather than caching it across frames.
- Iteration goes through the iterator:

```odin
it := pool_iterator(mesh_renderers(w)) // engine.pool_iterator outside the engine package
for mr, h in pool_next(&it) {
    if !mr.enabled do continue
    ...
}
```

- A nil pool yields an empty iterator, so there is no caller-side guard.
- The yielded handle carries `INVALID_TYPE_KEY` — pools don't know their type key, callers stamp it when they need a typed handle (`h.type_key = .Transform`).
- Destroying any component (including the current one) mid-iteration is safe. Components created mid-iteration may or may not be visited.
- Pool internals (`_slots`, `_freelist`, `_free_head`) are private to pool.odin. Nothing outside it depends on the slot layout — that is what keeps the layout swappable. `count` is public and read-only.

## The generic boundary

Machinery that works on *any* component — serialization, the inspector, undo, the ext-component registry — reaches components as `rawptr + typeid` through the `Pool_Entry` vtable and `world_pool_get`. That boundary assumes a component is one contiguous block. If the layout ever splits component fields into columns, this machinery migrates to copy semantics at the same choke points: gather the component into a contiguous scratch `T`, run the existing reflection code on the scratch, scatter it back. Consumers above the boundary (property drawers, inspector buttons, undo targets) are unaffected because they already receive ordinary pointers from the framework.

Undo follows the same rule: `Property_Target` re-resolves its pointer at apply and commit time (handle first, scene + local id fallback) — a raw pointer is never dereferenced across frames.

## Two data regimes

The object model is the authoring tier. Every entity has identity: a handle, a transform in a hierarchy, per-entity serialization with local ids, prefab override tracking, undo participation, inspector presence. Those features are per-entity cost by nature — the tier is sized for scenes you edit by hand, and its storage can keep getting faster behind the access contract above without changing what it is.

Mass simulation (tens of thousands of animated entities) is a different data regime. Those entities need position, sprite, animation frame and game state — not identity. Making the object model fast enough is not a layout problem: the features themselves are the per-entity cost, and the scene file, hierarchy view and undo history stop making sense at that scale in any engine. The direction for this regime is a first-class bulk entity tier — flat SoA arrays simulated in the fixed tick, rendered through GPU instancing, owned by one scene object that carries the settings. Tooling edits the settings and never holds per-entity pointers, so the bulk tier is unaffected by (and puts no constraints on) the object model's machinery. This mirrors Unity's literal split between GameObjects and DOTS entities.
