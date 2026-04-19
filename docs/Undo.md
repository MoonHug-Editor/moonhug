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

Raw pointers are unsafe as undo targets: pools recycle slots and structural undo/redo destroys and recreates objects, so any cached `^T` can be stale.

`Property_Target` instead stores:

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

## Transactions

```odin
undo.begin_transaction(s, "Create Empty Parent")
// ... several structural + value commands ...
undo.end_transaction(s, "Create Empty Parent")
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

When you write editor UI outside the inspector field loop (hierarchy view, custom panels, header fields), use the recording helpers:

```odin
import undo_pkg "undo"

// value edit on a transform field
target := undo_pkg.make_transform_target(tH, offset_of(engine.Transform, name), typeid_of(string))
old_json := undo_pkg.capture_json(&t.name, typeid_of(string))
// ... mutate t.name ...
new_json := undo_pkg.capture_json(&t.name, typeid_of(string))
undo_pkg.push_value(undo_pkg.get(), target, old_json, new_json)

// value edit on a component field
target := undo_pkg.make_component_target(comp.handle, offset_of(MyComp, field), typeid_of(T))
undo_pkg.push_value(undo_pkg.get(), target, old_json, new_json)

// structural commands
undo_pkg.record_reparent(node, old_parent, new_parent, old_index, new_index)
undo_pkg.record_create(new_root, parent)
pre, ok := undo_pkg.record_delete_pre(root)   // capture subtree
engine.transform_destroy(root)
if ok do undo_pkg.record_delete_commit(pre)

undo_pkg.record_add_component(tH, comp.handle, list_index)
pre, ok := undo_pkg.record_remove_component_pre(tH, comp.handle, list_index)
engine.transform_remove_comp(tH, comp.handle)
if ok do undo_pkg.record_remove_component_commit(pre)
undo_pkg.record_reorder_components(tH, from, to)

// atomic multi-step
undo_pkg.begin_transaction(undo_pkg.get(), "Edit Position+Scale")
// ... push_value calls ...
undo_pkg.end_transaction(undo_pkg.get(), "Edit Position+Scale")
```

When drawing a component's fields in a custom inspector panel, push an `Inspector_Owner` so nested drawers can find it:

```odin
undo_pkg.push_component_owner(comp.handle)
defer undo_pkg.pop_owner()
drawer(comp_ptr, comp_tid, label)
```

Clear the stack when context changes (handled automatically for scene load/unload/save-as and inspector target change):

```odin
undo_pkg.clear(undo_pkg.get())
```

## App developer usage

App code doesn't use the undo stack. It is editor-only and compiled into the editor binary, not the app. The engine only exposes one hook:

```odin
UserContext :: struct {
    // ...
    undo: rawptr,   // filled by the editor, nil in the app
}
```

Any engine or app code that wants to be undo-aware can check `engine.ctx_get().undo != nil`, but practically this is never needed — recording happens at editor UI boundaries, not inside game logic.

For components to work cleanly with undo of value edits, the existing rules are sufficient:

- Register the component type (`@(component)` attribute handles this via the prebuild generator).
- Implement `reset_T` / `cleanup_T` following the [Concepts](Concepts.md) rules so defaults survive delete + undo round-trip.
- Implement `on_validate_T` when a value change needs to recompute derived state; `_value_apply` calls it after restoring a component field.

No per-component undo code is required.

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
- Playmode does not record; the pre-play stack is preserved.
- Non-scene inspector targets (import settings, asset inspectors) use `.Raw` targets and stop being valid when the inspector switches away — the stack is cleared on target change.
- Structural commands capture full subtree JSON on delete/remove; large subtrees produce large entries.
