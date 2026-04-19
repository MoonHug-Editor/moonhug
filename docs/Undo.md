# Undo

Editor-only undo/redo for value edits and hierarchy changes.

## Core concepts

- Undo_Stack        — ordered history of commands with top for redo. The stack is scoped to the editor (`moonhug/editor/undo`)
- Command           — union of other undo commands
  - Value_Command — change to a single field (old_json / new_json payloads)
  - Structural_Command — hierarchy mutation (reparent, create, delete, add/remove/reorder component)
  - Group_Command — atomic bundle of sub-commands (multi-field edits)
- Property_Target   — robust identifier for a field (Owner_Kind + Scene + Local_ID + Handle + offset + typeid)
- Inspector_Owner   — current Transform/Component frame the inspector is drawing
- Pending_Edit      — cross-frame snapshot for drag widgets (DragFloat etc.)

## Targets survive pool reallocation

`Property_Target` stores robust identifier that works even after destroy/recreate object.
> Raw pointers are unsafe as undo targets: pools recycle slots and structural undo/redo destroys and recreates objects, so any cached `^T` can be stale.

- `kind` — `Transform`, `Component`, or `Raw`.
- `scene` + `local_id` — persistent, file-stable identity used when a `Handle` is stale.
- `handle` — fast path; falls back to `local_id` scan when invalid.
- `offset` + `type_id` — where and what inside the resolved struct.
- `raw_ptr` — used only for `.Raw` (non-scene data like import settings).

On apply/revert, the target is re-resolved to a live `rawptr`; this is the reason add/remove/delete-subtree undo works even though objects are destroyed and re-created.

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

The inspector uses `imgui` widgets. For drag widgets (`DragFloat`, etc.) the value changes over many frames but the user expects one undo step per drag. The system tracks two snapshots:

- **Field snapshot** (`begin_field` / `end_field`) — per-frame, used for simple one-shot widgets.
- **Pending edit** (`promote_to_pending` / `pending_commit`) — cross-frame, used when `IsItemActivated` fires.

Frame flow for a drag:

```
frame 0 (click):    IsItemActivated       → promote_to_pending snapshots old value
frame 1..N-1:       (dragging)            → value changes, pending stays
frame N (release):  IsItemDeactivatedAfterEdit → pending_commit pushes Value_Command
```

For instant widgets (checkbox, color-picker finish) activation and deactivation-after-edit fire the same frame, and the same path produces one command.

## Editor developer usage

Most editor code doesn't need to touch the undo API directly. The inspector field loop already wraps every registered property drawer, array, union, and enum with `begin_field` / `end_field` and finalizes with the pending protocol, so **drawers written to the standard contract get undo for free**.

When writing editor UI outside the inspector field loop (hierarchy view, custom panels, header fields, viewport gizmos), use the ergonomic scope helpers. These collapse the capture → mutate → push flow into one call and handle JSON cleanup on every path.

### Value edits

```odin
import undo_pkg "undo"

// transform field: arbitrary mutation between begin and commit
e := undo_pkg.edit_begin(tH, &t.name, typeid_of(string))
delete(t.name)
t.name = strings.clone(new_name)
undo_pkg.edit_commit(&e)

// component field
e := undo_pkg.edit_begin(comp.handle, &sr.color, typeid_of([4]f32))
sr.color = new_color
undo_pkg.edit_commit(&e)

// whole component (for Reset / Paste Values)
e := undo_pkg.edit_component_base(comp.handle, comp_tid)
engine.type_reset(comp.handle.type_key, comp_ptr)
undo_pkg.edit_commit(&e)

// abandon the edit without pushing (e.g. user cancelled mid-frame)
undo_pkg.edit_cancel(&e)

// non-scene data (import settings, asset inspectors)
e := undo_pkg.edit_begin(base_ptr, &settings.quality, typeid_of(int))
settings.quality = 3
undo_pkg.edit_commit(&e)
```

A zero `Edit_Scope` (from begin-failure — e.g. invalid handle) is safe to pass to `edit_commit` / `edit_cancel`; they no-op. The suffixed procs (`edit_transform_begin`, `edit_component_begin`, `edit_raw_begin`) remain callable directly when you want to be explicit.

### Structural commands

```odin
// create: returns the new transform handle and records the create step
newH := undo_pkg.record_create_child("Transform", parent_tH)

// delete: capture + destroy + push, single call
undo_pkg.record_delete(tH)

// reparent to a new parent, optionally at an explicit index
undo_pkg.record_reparent_to(node, new_parent)
undo_pkg.record_reparent_to(node, new_parent, sibling_index)

// add/remove component on a transform
engine.transform_add_comp(tH, .MyComp)
undo_pkg.record_add_component(tH, comp.handle, list_index)

undo_pkg.record_remove_component(tH, comp.handle)     // fused remove

undo_pkg.record_reorder_components(tH, from, to)
```

The low-level `record_delete_pre` / `record_cleanup` / `record_commit` and `record_remove_component_pre` still exist for the rare case where the destroy and the record must be split across non-adjacent code (e.g. the destroy happens inside a callback you don't control). Prefer the fused forms when possible.

### Group commands

```odin
g := undo_pkg.group_begin("Create Empty Parent")
defer undo_pkg.group_end(&g)

new_parent := undo_pkg.record_create_child("Transform", old_parent)
if new_parent == {} do return   // scope auto-aborts on early return
undo_pkg.record_reparent_to(new_parent, old_parent, sibling_idx)
undo_pkg.record_reparent_to(tH, new_parent)

undo_pkg.group_commit(&g)       // opt-in: only finalize if we made it here
```

`group_end` aborts the in-progress group unless `group_commit` was called first. Any `record_*` or `edit_*` calls made while a group is active collect into that group.

### Cross-frame drag outside the inspector

The inspector field loop handles drag widgets automatically (see "Pending edit" above). For widgets outside the inspector (e.g. viewport gizmos spanning many frames), use the `Field_Drag` scope:

```odin
// on mouse-down
d := undo_pkg.field_drag_begin(tH, &t.position, typeid_of([3]f32), "Gizmo Move")
// ... on each frame, mutate t.position freely ...
// on mouse-up
undo_pkg.field_drag_end(&d)    // single undo step covering the whole drag
```

### Custom inspector panels

When drawing a component's fields in a custom inspector panel, push an `Inspector_Owner` so nested drawers can find it:

```odin
undo_pkg.push_component_owner(comp.handle)
defer undo_pkg.pop_owner()
drawer(comp_ptr, comp_tid, label)
```

### Low-level API

The underlying primitives (`make_transform_target`, `make_component_target`, `capture_json`, `push_value`, `begin_group_command` / `end_group_command` / `abort_group_command`, `record_reparent`, `record_create`, `record_delete_pre`, `record_add_component`, `record_remove_component_pre`, `record_cleanup`, `record_commit`) remain available and are what the ergonomic helpers call internally.  
Reach for them only when the scope helpers can't express what you need.

Clear the stack when context changes (handled automatically for scene load/unload/save-as and inspector target change):

```odin
undo_pkg.clear(undo_pkg.get())
```

## App developer usage

App code doesn't use the undo stack. It is editor-only and compiled into the editor binary, not the app.

For components to work cleanly with undo of value edits, the existing rules are sufficient:

- Implement `reset_T` / `cleanup_T` so defaults survive delete + undo round-trip.
  - cleanup_T should deallocate type's data
  - reset_T should cleanup_T then set values
- Implement `on_validate_T` when a value change needs to recompute derived state, it is called after restoring a component field.

## History view

`View → History` opens a panel that lists every entry in the stack with its label and a marker for the current `top`. Entries above `top` are "done", entries below are "redo". Double-click a row to jump to that step (walks `apply_undo`/`apply_redo` until the stack's `top` matches). The bottom subview shows details for the selected entry: `Property_Target` breakdown, old/new JSON for value commands, or the parameters of structural commands (similar to Unity's console detail panel).

## Keyboard shortcuts

Installed in `editor/main.odin` with `RouteGlobal` so they work regardless of focused panel.

```
Ctrl+Z         — undo
Ctrl+Y         — redo
Ctrl+Shift+Z   — redo
```

## Limitations

- Capacity is 32 entries; overflow drops the oldest.
- Non-scene inspector targets (import settings, asset inspectors) use `.Raw` targets and stop being valid when the inspector switches away — the stack is cleared on target change.
- Structural commands capture full subtree JSON on delete/remove; large subtrees produce large entries.
