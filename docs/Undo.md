# Undo

Editor-only undo/redo for value edits and hierarchy changes.  

> A stack of commands that restore before(undo) or after(redo) state when executed.

# App code usage

App code doesn't use the undo feature. It is editor-only package (`moonhug/editor/undo`) compiled into the editor binary, not the app.

But for components to work cleanly with undo during authoring stage existing rules are sufficient:

- Implement `cleanup_T` so defaults survive delete + undo round-trip.
  - cleanup_T should deallocate type's data, and call comp_zero(self)
- Implement `on_validate_T` when a value change needs to recompute derived state, it is called after restoring a component field.

## History view

`View → History` opens a panel that lists every entry in the stack with its label and a marker for the current `top`. Entries above `top` are "done", entries below are "redo". Double-click a row to jump to that step (walks `apply_undo`/`apply_redo` until the stack's `top` matches). The bottom subview shows details for the selected entry: `Property_Target` breakdown, old/new JSON for value commands, or the parameters of structural commands (similar to Unity's console detail panel).

## Keyboard shortcuts

Installed in `editor/main.odin` with `RouteGlobal` so they work regardless of focused panel.

```
Ctrl+Z         — undo
Ctrl+Y         — redo
Ctrl+Shift+Z   — redo

view_history focused:
 - up
 - down
 - enter - restore state up to selected step
```

# Implementation details

WIP: API and implementation are subject to change

## Core concepts

- Undo_Stack        — ordered history of commands with top for redo. The stack is scoped to the editor 
- Command           — union of other undo commands
  - Value_Command   — change to a single field (old_json / new_json payloads)
  - Structural_Command — hierarchy mutation (reparent, create, delete, add/remove/reorder component)
  - Group_Command   — multiple sub-commands under one undo step (multi-field edits)
- Property_Target   — robust identifier for a field (Owner_Kind + Scene + Local_ID + Handle + offset + typeid)
- Inspector_Owner   — current Transform/Component frame the inspector is drawing; pushed by the inspector before drawing a component/transform so nested drawers can resolve it

## `Property_Target` for targets to survive pool reallocation

> Raw pointers are unsafe as undo targets. Pools recycle slots and structural undo/redo destroys and recreates objects.

`Property_Target` stores robust identifier that works even after destroy/recreate object.
- `kind` — `Pooled` (anything in the `World` pool table) or `Raw` (non-pooled memory).
- `scene` + `local_id` — persistent, file-stable identity used when a `Handle` is stale.
  - `handle` — fast path; falls back to `local_id` scan when invalid.
- `offset` + `type_id` — where and what inside the resolved struct.
- `raw_ptr` — used only for `.Raw` (non-scene data like import settings).

## Value payloads are JSON

Fields can be any size or type (strings, `[dynamic]T`, `[4]f32`, components with nested unions). Instead of fixed-size memcpy, `Value_Command` stores `old_json` and `new_json` byte slices. Apply unmarshals into the live pointer. This reuses the same JSON path as scene save/load and the inspector clipboard.

Because of this, every field `T` that can be undone needs a pointer typeid registered via `engine.register_pointer_type(T)`. All generated component types register automatically; primitives (`bool`, `int`, `i8..i64`, `u8..u64`, `f32`, `f64`, `string`) are registered in `editor/main.odin`.

## Stack behavior

```
push        — appends to stack; drops redo tail; FIFO-evicts at MAX_ENTRIES (32)
apply_undo  — walks back one entry, reverts it, decrements top
apply_redo  — walks forward one entry, applies it, increments top
clear       — wipes stack (used on scene load/unload, inspector target change)
```

`applying` flag blocks re-entrant recording during undo/redo. `recording` flag is false in playmode.

## Group Command

```odin
undo.begin_group_command(s, "Create Empty Parent")
// ... several structural + value commands ...
undo.end_group_command(s, "Create Empty Parent")
```

Sub-commands collect into a `Group_Command` and push as one undo step. Used for "Create Empty Parent" and for Euler rotation (three float edits → one quaternion change).

## Inspector integration

The inspector uses `imgui` widgets. For drag widgets (`DragFloat`, etc.) the value changes over many frames but the user expects one undo step per drag.  
This relies on ImGui's `IsItemActivated` / `IsItemDeactivatedAfterEdit` / `IsItemActive` to decide when to snapshot and when to commit.

### Component inspector — whole-owner serialization

The component field loop (`editor/inspector/view_inspector.odin`) does **not** track per-field targets. Every edit inside a component — top-level field, nested struct field, dynamic-array element, union variant — produces a `Value_Command` whose target is the entire component (offset `0`, component typeid). `old_json` and `new_json` hold the full component payload.

This is driven by `comp_snapshot` / `comp_commit` (`undo_inspector.odin`):

```
frame 0 (click):       IsItemActivated            → comp_snapshot captures full component JSON
frame 1..N-1 (drag):   value changes              → pending stays
frame N (release):     IsItemDeactivatedAfterEdit → comp_commit pushes one Value_Command
instant widgets:       activate + deactivate same frame → one command
```

Why whole-owner for the component inspector:

- `Property_Target` identifies a field as `owner_base_ptr + offset + typeid`. That works for fixed-layout fields, but **not** for elements inside a `[dynamic]T` or through a union tag switch — those live on the heap at addresses that have no stable offset from the component base and can move on reallocation.
- Components are already round-trippable through JSON (scene save/load, clipboard). Capturing `capture_json(comp_ptr, comp_tid)` and unmarshalling it back on undo is always safe for anything nested in the component, no matter how deep.
- The component inspector is the only place that routinely recurses through arrays/unions/structs, so the extra bytes per entry (vs a leaf field) are a good trade for correctness.

`_undo_finalize_widget` in `view_inspector.odin` is called immediately after each leaf drawer (property drawer, enum drawer, or inside `draw_array_element`) so `IsItemActivated` / `IsItemDeactivatedAfterEdit` / `IsItemActive` query the correct widget. Both the main field loop and `draw_array_element` save/restore `inspector_changed` around each element so a change in one element doesn't trigger a premature commit in the next.

Structural array/union mutations (Add, Remove, variant tag switch) wrap their mutation in `comp_snapshot` + `comp_commit`, producing one command that captures the structural change along with any cleared fields.

### Transform inspector — per-field targets

Transform fields (`name`, `position`, `rotation`, `scale`) are fixed-layout primitives with stable offsets, so `_wrap_transform_field` (`editor/view_hierarchy_inspector.odin`) still uses the lighter per-field protocol:

- **Field_Snapshot** (`begin_field` / `end_field`) — per-frame, simple one-shot widgets.
- **Pending_Edit** (`promote_to_pending` / `pending_commit`) — cross-frame, drag widgets.

```
frame 0 (click):    IsItemActivated       → promote_to_pending snapshots old value
frame 1..N-1:       (dragging)            → value changes, pending stays
frame N (release):  IsItemDeactivatedAfterEdit → pending_commit pushes Value_Command
```

For custom inspector UI outside the field loop (e.g. the `enabled` checkbox on the component header), use the ergonomic `edit_begin` / `edit_end` scopes which wrap the same mechanism.

## Editor code usage

Most editor code doesn't need to touch the undo API directly:

- The **component field loop** wraps every registered property drawer, array element, union variant, and enum with `comp_snapshot` / `comp_commit` so **drawers written to the standard contract get undo for free** — one step per drag, one step per Add/Remove, one step per tag switch.
- The **transform field loop** wraps its three rows (`position`, `rotation`, `scale`) and the `name` row with `begin_field` / `end_field` + pending-edit finalize.

When writing editor UI outside these loops (hierarchy view, custom panels, component header checkbox/menus, viewport gizmos), use the ergonomic scope helpers. These collapse the capture → mutate → push flow into one call and handle JSON cleanup on every path.

### Value edits

```odin
import "undo"

// transform field: arbitrary mutation between begin and commit
e := undo.edit_begin(tH, &t.name, typeid_of(string))
delete(t.name)
t.name = strings.clone(new_name)
undo.edit_end(&e)

// component field
e := undo.edit_begin(comp.handle, &sr.color, typeid_of([4]f32))
sr.color = new_color
undo.edit_end(&e)

// whole component (for Reset / Paste Values)
e := undo.edit_begin(comp.handle, comp_tid)
engine.type_reset(comp.handle.type_key, comp_ptr)
undo.edit_end(&e)

// enabled checkbox (same whole-component form)
if im.Checkbox("##enabled", &enabled) {
    e := undo.edit_begin(comp.handle, comp_tid)
    comp_base.enabled = enabled
    undo.edit_end(&e)
}

// abandon the edit without pushing (e.g. user cancelled mid-frame)
undo.edit_cancel(&e)

// non-scene data (import settings, asset inspectors)
e := undo.edit_begin(base_ptr, &settings.quality, typeid_of(int))
settings.quality = 3
undo.edit_end(&e)
```

A zero `Edit_Scope` (from begin-failure — e.g. invalid handle) is safe to pass to `edit_end` / `edit_cancel`; they no-op. The suffixed procs (`edit_transform_begin`, `edit_component_begin`, `edit_raw_begin`) remain callable directly when you want to be explicit.

### Structural commands

```odin
// create: returns the new transform handle and records the create step
newH := undo.record_create_child("Transform", parent_tH)

// delete: capture + destroy + push, single call
undo.record_delete(tH)

// reparent to a new parent
undo.record_reparent_to(node, new_parent)
// optionally at an explicit index
undo.record_reparent_to(node, new_parent, sibling_index)

// add/remove component on a transform
engine.transform_add_comp(tH, .MyComp)
undo.record_add_component(tH, comp.handle, list_index)

undo.record_remove_component(tH, comp.handle)

undo.record_reorder_components(tH, from, to)
```

The low-level `record_delete_pre` / `record_cleanup` / `record_commit` and `record_remove_component_pre` still exist for the rare case where the destroy and the record must be split across non-adjacent code (e.g. the destroy happens inside a callback you don't control). Prefer the "fused" forms when possible.

### Group commands

```odin
g := undo.group_begin("Create Empty Parent")
defer undo.group_end(&g)

new_parent := undo.record_create_child("Transform", old_parent)
if new_parent == {} do return   // scope auto-aborts on early return
undo.record_reparent_to(new_parent, old_parent, sibling_idx)
undo.record_reparent_to(tH, new_parent)

undo.group_commit(&g)       // only finalize if we made it here
```

`group_end` aborts the in-progress group unless `group_commit` was called first. Any `record_*` or `edit_*` calls made while a group is active collect into that group.

### Cross-frame drag outside the inspector

The inspector field loop handles drag widgets automatically (see "Pending edit" above). For widgets outside the inspector (e.g. viewport gizmos spanning many frames), use the `Field_Drag` scope:

```odin
// on mouse-down
d := undo.field_drag_begin(tH, &t.position, typeid_of([3]f32), "Gizmo Move")
// ... on each frame, mutate t.position freely ...
// on mouse-up
undo.field_drag_end(&d)    // single undo step covering the whole drag
```

### Custom inspector panels

When drawing a component's fields in a custom inspector panel, push an `Inspector_Owner` so nested drawers can find it:

```odin
undo.push_component_owner(comp.handle)
defer undo.pop_owner()
drawer(comp_ptr, comp_tid, label)
```

### Low-level API

The underlying primitives (`make_transform_target`, `make_component_target`, `capture_json`, `push_value`, `begin_group_command` / `end_group_command` / `abort_group_command`, `record_reparent`, `record_create`, `record_delete_pre`, `record_add_component`, `record_remove_component_pre`, `record_cleanup`, `record_commit`) remain available and are what the ergonomic helpers call internally.  
Reach for them only when the scope helpers can't express what you need.

Clear the stack when context changes (handled automatically for scene load/unload/save-as and inspector target change):

```odin
undo.clear(undo.get())
```

## Limitations

- Capacity is 32 entries; overflow drops the oldest.
- Non-scene inspector targets (import settings, asset inspectors) use `.Raw` targets and stop being valid when the inspector switches away — the stack is cleared on target change.
- Structural commands capture full subtree JSON on delete/remove; large subtrees produce large entries.
- Component inspector edits serialize the whole component per step. Components with large dynamic arrays produce correspondingly large entries; in practice the inspector is not the hot path so this is acceptable.
