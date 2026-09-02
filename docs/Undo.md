# Undo

Editor-only undo/redo for value edits, hierarchy changes, asset (.mat/.asset) edits, and selection changes.

> A stack of commands that restore before(undo) or after(redo) state when executed.

# App code usage

App code doesn't use the undo feature. It is an editor-only package (`moonhug/editor/undo`) compiled into the editor binary, not the app.

For components to work cleanly with undo during authoring, the existing rules are sufficient:

- Implement `cleanup_T` so defaults survive a delete + undo round trip.
  - `cleanup_T` deallocates the type's data and calls `comp_zero(self)`.
- Implement `on_validate_T` when a value change needs to recompute derived state. It is called after restoring a component field.

## History view

`View → History` opens a panel that lists every entry in the stack with its label and a marker for the current `top`. Entries above `top` are "done", entries below are "redo". Double-click a row to jump to that step (walks `apply_undo`/`apply_redo` until the stack's `top` matches). The bottom subview shows selectable, copyable details for the selected entry: `Property_Target` breakdown, old/new JSON for value commands, or the parameters of structural commands.

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

## Core concepts

- Undo_Stack        — ordered history of commands with top for redo. ONE stack for the whole editor: scene edits, asset edits and selection changes share the timeline
- Command           — union of the command kinds below
  - Value_Command   — change to a single field (old_json / new_json payloads). An `.Asset`-kind target holds a whole asset document
  - Structural_Command — hierarchy mutation (reparent, create, delete, add/remove/reorder component)
  - Group_Command   — multiple sub-commands under one undo step (multi-field edits)
  - Selection_Command — a selection change (before/after states), Unity's "Selection Change" steps
- Property_Target   — robust identifier for a field (Owner_Kind + Scene_Ref + Local_ID + Handle + offset + typeid, or asset guid for `.Asset`)
- Edit_Session      — a bracketed transaction over N targets: before-state captured at open, one grouped action recorded at close (see "Edit sessions")
- Scene_Ref         — scene identity that survives reloads: live pointer fast path + asset guid fallback (`resolve_scene`)
- Inspector_Owner   — current Transform/Component/Asset-document frame the inspector is drawing. Pushed by the inspector before drawing so nested drawers can resolve it

## `Property_Target` for targets to survive pool reallocation

> Raw pointers are unsafe as undo targets. Pools recycle slots and structural undo/redo destroys and recreates objects.

`Property_Target` stores a robust identifier that works even after destroy/recreate.
- `kind` — `Pooled` (anything in the `World` pool table), `Raw` (non-pooled memory) or `Asset` (serialized asset document).
- `scene` (a `Scene_Ref`) + `local_id` — persistent, file-stable identity used when a `Handle` is stale. The scene re-resolves by asset guid after a reload.
  - `handle` — fast path, with a `local_id` scan as the fallback when invalid.
- `offset` + `type_id` — where and what inside the resolved struct.
- `raw_ptr` — used only for `.Raw` (non-scene data like import settings).
- `asset_guid` — used only for `.Asset`. Applied through the inspector's asset-document hook, never via pointer.

## Value payloads are JSON

Fields can be any size or type (strings, `[dynamic]T`, `[4]f32`, components with nested unions). Instead of a fixed-size memcpy, `Value_Command` stores `old_json` and `new_json` byte slices. Apply unmarshals into the live pointer. This reuses the same JSON path as scene save/load and the inspector clipboard.

Because of this, every field `T` that can be undone needs a pointer typeid registered via `engine.register_pointer_type(T)`. All generated component types register automatically. Primitives (`bool`, `int`, `i8..i64`, `u8..u64`, `f32`, `f64`, `string`) are registered in `editor/main.odin`. A type that is not registered records the command but the restore does nothing beyond a logged error — check this first when undo appears to record but not revert.

## Stack behavior

```
push          — appends to stack, drops redo tail, FIFO-evicts at MAX_ENTRIES (128)
apply_undo    — walks back one entry, reverts it, decrements top
apply_redo    — walks forward one entry, applies it, increments top
purge_scene   — drops entries referencing ONE scene (call before unloading it)
purge_scenes  — drops entries referencing ANY scene (single-scene loads). Asset
                edits and project-only selection steps survive
clear         — wipes stack (History view's Clear button only)
```

Scene navigation purges instead of clearing: opening a scene, entering/exiting
a nested scene (edit stack) or unloading calls `purge_scenes`/`purge_scene`,
so `.mat` edits and project selection steps outlive scene trips. Clicking an
asset in the project view touches nothing at all. A group is purged whole if
ANY sub-command touches the purged scene — groups are atomic, a partial group
would corrupt the timeline.

The `applying` flag blocks re-entrant recording during undo/redo. The `recording` flag is false in playmode. `activity` is set by every stack mutation and consumed once per frame by the selection tracker (see below).

Behavior examples:

- Edit transform → click a .mat → tweak color → Ctrl+Z three times: undo 1
  reverts the color, undo 2 reverts the "Select .mat" step, undo 3 reverts
  the transform.
- Delete 3 selected objects → Ctrl+Z: objects return AND all three are
  selected again with the same active one.
- Enter nested scene (edit stack) → edit a .mat → exit: scene entries purge
  on each swap. The .mat edit survives and stays undoable.
- Click through 5 objects → Ctrl+Z walks back through the selections,
  Unity-style.

## Edit sessions

An edit is a *gesture*: it begins, runs for some number of frames, and ends.
Undo needs the value from before the gesture and the value after it. The
session makes the gesture an object — nothing infers "has this edit started"
from per-frame widget state.

```odin
// One thing being edited. Constructors: edit_target_pooled, edit_target_transform,
// edit_target_whole, edit_target_asset.
Edit_Target :: struct {
    kind: Owner_Kind, // .Pooled | .Raw | .Asset

    handle:     engine.Handle,     // .Pooled — a component or transform in a world pool
    raw_ptr:    rawptr,            // .Raw — a struct the editor owns
    raw_tid:    typeid,
    asset_guid: engine.Asset_GUID, // .Asset — a document in the asset registry
    asset_tid:  typeid,

    // The field within it. nil field_ptr means "the whole target", which is
    // what a structural change (array add/remove) needs.
    field_ptr: rawptr,
    field_tid: typeid,
}

// Opens the transaction and captures every target's before-state AT THE SAME
// INSTANT. restore_before/restore_after roll the field back around that
// capture, for edits that can only be bracketed after they happened (see
// "Pickers" below).
edit_session_begin :: proc(targets: []Edit_Target, label := "", ...) -> Edit_Session

// Captures after-state, records ONE grouped action, closes the session.
// Targets whose value did not change contribute nothing, so a gesture that
// ends where it started records nothing at all.
edit_session_end :: proc(s: ^Edit_Session)

// Abandons without recording. Values the caller already wrote stay written.
edit_session_abort :: proc(s: ^Edit_Session)
```

### Granularity is decided by the API, not the caller

Per target, at open:

- `field_ptr` lies **inside** the target's own storage → record that field
  (a `Value_Command` at its offset). Covers position, scale, scalars, enums,
  refs — the large majority, ~17 bytes for a `[3]f32`.
- `field_ptr` is **outside** it, or nil → record the **whole target**. Required
  for dynamic-array elements, whose storage is a separate allocation an offset
  cannot address.

Putting the rule in one place makes it impossible for two call sites to
disagree on it.

### Multi-object is not a special case

A selection-wide edit is the same transaction with more targets:

```odin
targets := make([dynamic]undo.Edit_Target, context.temp_allocator)
for h in selection do append(&targets, undo.edit_target_transform(h, &t.position, typeid_of([3]f32)))
s := undo.edit_session_begin(targets[:], "Position")
for h in selection do write(h, v)
undo.edit_session_end(&s)
```

One session yields one undo step covering every target. This is what the
gizmo, the inspector rows and the structural operations all do — multiedit is
not a parallel mechanism (see [Multiselection](Multiselection.md)).

### Gestures spanning frames

The inspector holds one open session, keyed by the row's field pointer
(`editor/inspector/field_edit.odin`), so a per-frame drawer needs no state of
its own:

```odin
// Every frame the row draws:
if field_edit_row_started() { field_edit_begin(field_ptr, tid, offset, label) }
drawer(...)                                    // writes freely, records nothing
if field_edit_in_flight(field_ptr) { field_edit_apply_to_peers(...) }
if field_edit_row_finished() { field_edit_end() }
```

The session captures once at open and holds until close, so the pre-image
cannot be clobbered by a later frame.

Two imgui facts shape the row helpers:

- A multi-component row (`drag_float3`) draws N separate items, so item-state
  queries after the drawer describe only the LAST component. The `drag_*`
  helpers latch activation/deactivation from inside the row
  (`drag_row_activated`/`drag_row_deactivated`), and
  `field_edit_row_started/finished` read those latches.
- imgui reports activation only AFTER a widget draws, so on the frame a drag
  begins the drawer has already written the first frame's value. Every row
  takes a pre-drawer snapshot and hands it to the late-opened session as the
  before-state.

### Pickers

A picker (mesh, material, any reference) writes from inside a popup: no drag,
no focus, so its gesture has no observable start. Its row snapshots the value
before the draw, compares after, and opens the session **retroactively** only
if it moved — temporarily writing the old value back while the session
captures, via `restore_before`/`restore_after`.

Rolling back rather than handing the session a payload is what makes it
correct at any granularity: an entry records a field or a whole component
depending on where the field lives, and a payload captured at one granularity
written into an entry expecting the other corrupts the record.

### Structural operations

Add and remove an array element, switch a union variant, invoke an inspector
button or a decorator: these have no gesture to bracket, and what changed
cannot be named by a field offset — a union's payload type differs, an
array's elements move. They bracket themselves in `structural_edit_begin` /
`structural_edit_end` (`editor/inspector/field_edit.odin`), which builds a
session over the active owner and every multi-selected peer with a nil
`field_ptr`, so each entry records the whole target. One click is one undo
step covering the selection.

### Sessions and groups are different things

- A **group** (`group_begin` / `group_end`) bundles several *finished* actions
  into one Ctrl+Z. "Create Empty Parent" is one create plus two reparents —
  three complete operations, one undo step.
- A **session** brackets one *unfinished* edit: before-state now, after-state
  later, possibly many frames apart. It produces exactly one grouped action
  when it closes.

Sessions do not nest. A component never contains another component, and
`draw_inspector`'s recursion is into nested structs, arrays and unions — all
within one component, hence one target. Opening a session for a key that
already has one open is a no-op, which is what makes per-frame calling safe.

### Testing rows

`tests/field_row_harness.odin` replays a SEQUENCE of frames through the real
`field_edit_row`, substituting the three imgui item-state queries a row
observes. Frame builders name the cases: `frame_idle`, `frame_press`,
`frame_drag`, `frame_release`, `frame_popup_write`, `frame_button_click`.
Rotation has its own driver (`rotation_row_drive_for_test`), because its row
edits an euler cache rather than the stored quaternion.

The harness exists because gesture bugs are multi-frame sequencing mistakes —
none are reachable from a test that calls the procs once. When changing
`field_edit.odin`, add a frame sequence and **verify it discriminates** by
reverting the fix and watching it fail.

## Group Command

```odin
undo.begin_group_command(s, "Create Empty Parent")
// ... several structural + value commands ...
undo.end_group_command(s, "Create Empty Parent")
```

Sub-commands collect into a `Group_Command` and push as one undo step. Used for "Create Empty Parent" and for Euler rotation (three float edits → one quaternion change).

## Asset edits (project inspector)

`.mat`/`.asset` files open into an **asset document registry**
(`inspector/asset_docs.odin`): one in-memory doc per asset GUID that outlives
the inspector's current selection. The project inspector shows the doc for
the selected file, and clicking away and back keeps unsaved edits.

Every field edit records a whole-document `Value_Command` with an `.Asset`
target — asset documents have no field-level form
(`_draw_asset_inspector` pushes `undo.push_asset_owner(guid, ptr, tid)`
around `draw_inspector`, so all drawers get asset undo for free). Undo/redo
replaces the document payload through the hook installed by
`inspector.init()` (`undo.set_asset_apply`), marks it dirty (`*` next to the
file path) and re-pushes material live preview. Undo edits the doc, not the
disk — Save persists, like unsaved live-preview edits always worked.

## Selection undo (Unity model)

Selection changes are undo steps. A per-frame tracker
(`editor/selection_undo.odin`, called at the end of the main loop) diffs the
selection against a baseline and records one `Selection_Command` per changed
frame — "Select Cube", "Select 3 Items", "Clear Selection". Frames where the
stack itself mutated (data edit, undo/redo, purge) only re-baseline, so data
operations never double-record.

Delete/duplicate groups embed `undo.record_selection_snapshot()` as their
first sub-command: undoing a delete restores the objects first, then
re-selects them.

Snapshots store scene items as `(Scene_Ref, local_id)` and project items as
paths, so they survive object recreation and scene reloads. Whatever no
longer resolves is silently pruned on restore. The undo package reaches the
editor's selection through hooks (`undo.set_selection_hooks`, installed by
`selection_undo_install` in `main.odin`) — unset hooks (tests) make selection
commands no-ops.

## Inspector integration

### Component inspector — whole-owner serialization

The component field loop (`editor/inspector/view_inspector.odin`) does **not** track per-field targets. Every edit inside a component — top-level field, nested struct field, dynamic-array element, union variant — produces a `Value_Command` whose target is the entire component (offset `0`, component typeid). `old_json` and `new_json` hold the full component payload.

This is driven by an edit session (see above), opened when the row's gesture starts and closed when it ends.

Why whole-owner for the component inspector:

- `Property_Target` identifies a field as `owner_base_ptr + offset + typeid`. That works for fixed-layout fields, but **not** for elements inside a `[dynamic]T` or through a union tag switch — those live on the heap at addresses that have no stable offset from the component base and can move on reallocation.
- Components are already round-trippable through JSON (scene save/load, clipboard). Capturing `capture_json(comp_ptr, comp_tid)` and unmarshalling it back on undo is always safe for anything nested in the component, no matter how deep.
- The component inspector is the only place that routinely recurses through arrays/unions/structs, so the extra bytes per entry (vs a leaf field) are a good trade for correctness.

`field_edit_row` (`editor/inspector/field_edit.odin`) draws each leaf and brackets
it in one place, so the imgui item state queried is the row's own. Both the main
field loop and `draw_array_element` save/restore `inspector_changed` around each
element so a change in one element doesn't trigger a premature commit in the next.

### Transform inspector — per-field targets

Transform fields (`name`, `position`, `rotation`, `scale`) are fixed-layout
primitives with stable offsets, so their session records the field rather than
the whole transform. `_wrap_transform_field_override`
(`editor/view_hierarchy_inspector.odin`) is the bracket, because transform rows
bypass the generic field loop and also record prefab-instance overrides.

For custom inspector UI outside the field loop (e.g. the `enabled` checkbox on the component header), use the ergonomic `edit_begin` / `edit_end` — an `Edit_Scope` IS a one-target `Edit_Session`, so it is the same mechanism with a two-line spelling.

## Editor code usage

Most editor code doesn't need to touch the undo API directly:

- The **component field loop** brackets every registered property drawer, array element, union variant, and enum in a session, so **drawers written to the standard contract get undo for free** — one step per drag, one step per Add/Remove, one step per tag switch, covering every selected object.
- The **transform field loop** brackets its three rows (`position`, `rotation`, `scale`) the same way. The `name` row uses `edit_begin` / `edit_end`.

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

// abandon the edit without pushing (e.g. user cancelled mid-frame)
undo.edit_cancel(&e)

// non-scene data (import settings, asset inspectors)
e := undo.edit_begin(base_ptr, typeid_of(Settings), &settings.quality, typeid_of(int))
settings.quality = 3
undo.edit_end(&e)
```

A zero `Edit_Scope` (from begin-failure — e.g. invalid handle) is safe to pass to `edit_end` / `edit_cancel`, they no-op. The suffixed procs (`edit_transform_begin`, `edit_component_begin`, `edit_raw_begin`) remain callable directly when you want to be explicit; `edit_raw_begin` takes the struct's typeid as well as the field's, because the session decides field-vs-whole granularity by whether the field lies inside the struct.

`edit_end` records nothing when the value did not change, and a field that lives outside its owner's storage (a dynamic-array element) is recorded as the whole owner — both are the session's rules, inherited rather than reimplemented.

Multi-target and cross-frame edits use an `Edit_Session` directly — see "Edit
sessions" above.

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

A single-target drag outside the inspector's row path (the rotation row's euler
cache is the remaining user) is the same `edit_begin` / `edit_end` pair held
across frames — open on mouse-down, close on mouse-up, one undo step covering
the whole drag:

```odin
// on mouse-down
d := undo.edit_begin(tH, &t.position, typeid_of([3]f32), "Gizmo Move")
// ... on each frame, mutate freely ...
// on mouse-up
undo.edit_end(&d)
```

Multi-target drags (the gizmo) use an `Edit_Session` opened at grab and closed
at release.

### Custom inspector panels

When drawing a component's fields in a custom inspector panel, push an `Inspector_Owner` so nested drawers can find it:

```odin
undo.push_component_owner(comp.handle)
defer undo.pop_owner()
drawer(comp_ptr, comp_tid, label)
```

Without an owner the inspector's rows open no session at all — the edit writes
memory and records nothing. The Tween Graph's side panel
(`packages/app/editor/tween_view.odin`) is the reference example.

### Low-level API

The underlying primitives (`make_transform_target`, `make_component_target`, `capture_json`, `push_value`, `begin_group_command` / `end_group_command` / `abort_group_command`, `record_reparent`, `record_create`, `record_delete_pre`, `record_add_component`, `record_remove_component_pre`, `record_cleanup`, `record_commit`) remain available and are what the ergonomic helpers call internally.
Reach for them only when the scope helpers can't express what you need.

Purge scene entries before unloading a scene (handled automatically for
scene open/unload/save-as and nested-scene edit-stack navigation):

```odin
undo.purge_scene(undo.get(), scene) // one scene, before sm_scene_unload
undo.purge_scenes(undo.get())       // all scenes, before a single-scene load
```

## Limitations

- Capacity is 128 entries. Overflow drops the oldest.
- Import settings edits are not recorded (the Apply+reimport button is already an explicit transaction).
- Undoing an asset edit replaces the whole document instance. The old instance's nested allocations live until editor shutdown (same lifetime the pre-registry reload-on-click had). Asset docs have no eviction — `.mat`-scale files only.
- File operations in the project view (rename/move/delete files) are not undoable — Unity doesn't undo these either.
- Structural commands capture full subtree JSON on delete/remove. Large subtrees produce large entries.
- Component inspector edits serialize the whole component per step. Components with large dynamic arrays produce correspondingly large entries. In practice the inspector is not the hot path, so this is acceptable.
