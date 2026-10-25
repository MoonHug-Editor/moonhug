---
title: "Components"
description: "The component data layer and its narrow access contract: pools, handles, transforms and lifecycle procs"
weight: 10
tags: ["components", "engine"]
path: engine/data
---

The component data layer and its access contract. The contract is deliberately narrow so the storage layout can change (for example to SoA columns) without touching the code above it.

## Model

- A component is a plain struct registered with `@(component)`, stored in a fixed-size `Pool(T, N)` per type per world (`MAX` slots by default, smaller for capped types like Camera and Light).
- A `Handle` (index + generation + type key) is the durable reference. Generations catch stale handles after a slot is recycled.
- `Transform` owns the hierarchy and the per-object component list (`Owned` entries). Component structs embed `CompData` (owner, local id, enabled).

## Lifecycle procs

A `@(typ_guid)` type declares its lifecycle procs by name in its own file. Prebuild finds them there (same file only, the scan is syntax-only) and the generated registration puts them in the engine's tables by `TypeKey` (`core/type_lifecycle.odin`). Nothing is passed by hand.

- `reset_T :: proc(t: ^T)` calls `cleanup_T` first when the type has one, then sets the defaults, so a reset on a live value frees what it owned and a direct `reset_T` call is safe anywhere. `create_instance_by_type_key` runs it on a new zeroed instance (a new asset, first import settings, a component on add), and the inspector's Reset runs it on a live value.
- A field missing from a file loads as the type's reset default, not zero. [Missing fields and reset defaults](#missing-fields-and-reset-defaults) has the rule, the load paths and the setting that turns it off.
- `cleanup_T :: proc(t: ^T)` frees what a `T` owns (strings, arrays, authored blobs) and leaves the value zeroed. It does not free `t`. It runs when a component leaves the world, when a union variant goes (`tween_destroy`, `script_destroy`), when a tween node is destroyed, and through `type_cleanup(key, ptr)` for anything else that holds a value.
- A component's `cleanup_T` also releases what the instance holds outside itself: a physics body, a mixer track, GPU buffers. It runs on destroy and removal, and on a live value too (Reset, an undo write), so the resource goes or rebuilds with the value. A copy of a value is safe to clean up: resource handles are `json:"-"`, so a copy made through JSON (undo, deserialize scratch, remap temps) holds a zero handle and releases nothing.
- `on_validate_T :: proc(t: ^T)` runs after an inspector edit and after a value is loaded from data, to keep the value valid. Loading is zero → reset defaults → JSON → on_validate.
- `@(comp_awake)` and `@(comp_on_destroy)` are a component's game hooks, not value procs: see [Game lifecycle](#game-lifecycle).

`type_reset`, `type_cleanup` and `type_on_validate` take a `TypeKey` and a pointer, `type_has_reset` says whether Reset applies. The procs are explicit: a `cleanup_T` frees its own fields, and calls `type_cleanup` on a field of another type when that type owns something. Nothing walks fields on its own, since the tables cannot know which allocator a nested value came from.

## Game lifecycle

Four hooks run game logic on a component instance in the running game (`component_lifecycle.odin`). Each is `@(comp_<hook>={component=T})` on a `proc(c: ^T)` named `comp_<hook>_T`, in T's package:

- `comp_awake` runs once per instance when it enters the running game.
- `comp_on_enable` runs when the instance becomes enabled: right after its awake when it is, then on every change to that. Enabled means `enabled && transform_active_in_hierarchy(owner)`.
- `comp_on_disable` runs when the instance stops being enabled, and before `comp_on_destroy` when it was.
- `comp_on_destroy` runs when the instance leaves the running game. It is for game logic and for what `comp_awake_T` created outside the instance. `cleanup_T` runs right after it.
- There is no Start hook: the first `comp_on_enable` of a creation sees the whole creation awake, so a bool in the component covers "once, after everything exists".
- The generator enforces the name and stops the build on a hook whose T is no `@(component)` of the package, so a type has at most one of each.

Both run only while the game runs in the game world (`game_running()`): `application_is_playing()` is true and the context's world is `UserContext.game_world`. They never run in edit mode, and never on preview or thumbnail content, which renders in a world swapped into `UserContext.world`.

When awake runs:

- At play start (`application_set_playing(true)`), on every loaded scene in slot order.
- Right after a creation while the game runs: a scene load, `scene_instantiate_guid`, `scene_instantiate_guid_nested`, `scene_paste_subtree` (and `scene_duplicate_subtree`), `transform_add_comp`, and the undo steps that restore objects or components.
- Active and enabled state do not matter: every instance in the running game has had its awake.

Awake order:

- An object's components in their list order, then its children, depth first.
- Two passes over the creation: `comp_awake` on everything, then `comp_on_enable` on everything enabled, in the same order. Every `comp_on_enable` sees the whole creation awake.
- A creation inside another (an instantiate pastes, a scene load resolves its prefabs) runs in the outer one's batch (`awake_batch_begin` / `awake_batch_end`). The outermost creation awakes the whole result once, after every component exists and every reference is bound.
- A component or object an awake proc creates awakes on its own. The walk visits only what each object had when the walk reached it.

How enable changes are noticed:

- `CompData.notified_enabled` (runtime-only) records what the hooks last reported. `enabled_sync(key, ptr)` compares it with the real state and fires `comp_on_enable` or `comp_on_disable` on a difference. Nothing runs per frame.
- Game code changes the flags through `transform_set_active(tH, active)` and `comp_set_enabled(c, enabled)`, which sync at once: the subtree, or the one component.
- Editor writes (the inspector, the hierarchy checkbox, undo and redo, an MCP write, a multi-edit) reach the sync through the undo stack: `Target_Resolver.value_written` runs after every value write with the owner's handle. Override reverts sync their target in `nested_scene_patch_live_field`.
- A writer that bypasses both is a bug. `enabled_verify` panics on the first component whose reported state differs from its real one, naming the object and the component. `frame_tick` runs it in debug builds, and the tests run it directly.

When comp_on_destroy runs (`comp_on_disable` first when the instance was enabled):

- The object is destroyed, the component removed or its scene unloaded, while the game runs (`component_on_destroy`, the path every destroy takes).
- Play stops (`application_set_playing(false)`): every live component of the game world, type by type, while the game still runs. Simulate's Stop does this before its restore, and the player at `EngineShutdown` before anything shuts down. The destroys after it only run `cleanup_T`.

### Physics contact hooks

Four more hooks, `comp_on_collision_enter`, `comp_on_collision_exit`, `comp_on_trigger_enter` and `comp_on_trigger_exit`, are `proc(c: ^T, other: Transform_Handle)` named `comp_<hook>_T` (`physics_hooks.odin`):

- A physics plugin polls its library's begin and end events after the solver step and calls `physics_contact_dispatch` for each, in the same fixed tick. A hook may destroy, spawn or push bodies freely: the step is over.
- A hook runs on the components of the shape's own object only, not on its parents or children, with `other` the object of the other shape. Both objects of an event get their hooks.
- There is no stay hook. A component that needs one keeps its own set from enter and exit.
- `Transform.physics_hooked` skips objects without a hooked component: a component of a hooked type sets it at awake, and a dispatch that finds no hooked component clears it. A contact between two unhooked objects costs two bit tests.

### Destroying from game code

`transform_destroy` destroys at once. Code that runs inside an update loop over a pool queues the object instead:

- `transform_destroy_later(tH)` marks the object (`Transform.destroy`) and queues it. A second call before the queue runs does nothing.
- `frame_tick` destroys the queue after its last stage (`transform_destroy_pending`), in queue order. An object a `@(comp_on_destroy)` proc queues while the queue runs goes in the same pass. An object already gone (with its parent, or by a direct destroy) is skipped.
- Stopping the game drops the queue. An object that stays loses its mark and can be queued again.

## Missing fields and reset defaults

A file saved before a field existed does not name that field. MoonHug loads such a field as the type's `reset_T` default, so a field added to a component after a scene was saved loads as a new component's value, not zero. A Camera saved before `render_layer_mask` existed still draws every layer.

How a load works (`core/type_lifecycle.odin`):

- The value starts as a zeroed `T` and takes the JSON through a plain unmarshal.
- `reset_T` runs on a separate scratch `T`, never on the loaded value, since a reset may allocate and the unmarshal would allocate over it.
- Each top-level field the JSON object does not name swaps in from the scratch. The name is the field's `json` tag name, else the field name. The fields of a `using _:` field count as top-level.
- `cleanup_T` then frees what the scratch still holds (the defaults of the fields the file supplied), and the scratch is freed.
- `on_validate_T` runs last, as on every load.
- A type with no `reset_T`, or a value that is not a struct, gets a plain unmarshal.

The load paths that apply it:

- Scene load: every component record (`_ext_value_into` in `component_registry.odin`).
- Prefab and nested-scene instancing, and the id remap of a paste or a nested instance.
- Prefab-base normalisation (`_normalize_component_records`) and the override baselines of nested instances.
- Asset files (`serialization.odin`), and assets an owner reads by type (`engine.asset_parse_as`, `asset_load_as`): layer names, collision matrices.
- Union variants inside any value (`union_serialization.odin`).
- Import settings from a `.meta` file (`_settings_from_value` in `asset_pipeline.odin`).
- Undo and redo of an asset document or import settings (`asset_docs.odin`, `import_settings_docs.odin`).

The API:

- `unmarshal_over_reset(data, ptr, tid)` starts from bytes and parses them once to learn the key set.
- `unmarshal_over_reset_object(data, obj, ptr, tid)` takes the already parsed object for the key set, so the bytes are not parsed twice.
- `unmarshal_value_over_reset(v, ptr, tid)` takes a `json.Value`, marshals it once and reads the key set from it.

Limits:

- Only top-level fields take the default. A nested struct the file names comes from the file whole, and a sub-field it lacks is zero. A nested struct the file does not name takes its default whole.
- A `json:"-"` field is never in a file, so it always takes the reset value.
- A file is not rewritten on load. It gains the new field when it is saved next.

Prefab-base normalisation goes through the same path as a load. The override diff compares the normalised prefab base with the live instance, and a field the prefab file lacks has the same value on both sides, so a save never records an override for it. A change to the load rule must reach normalisation too, or saves invent overrides.

### The setting

- The Serialization tab of Project Settings has one field, `load_defaults_for_missing_fields` (`core.serialization_settings`, saved in `ProjectSettings/serialization.json`). It is on by default.
- The cost of on: a reset and a cleanup on a scratch copy for every loaded component or asset whose type has a `reset_T`.
- Off: every load is a plain unmarshal and a field missing from a file loads as zero. A field added to a type after a file was saved must then tolerate zero, or the files must be migrated by hand.
- The setting lives in core because every load path reads it. It loads at `SerializationInit`, before any value is loaded from data.

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
