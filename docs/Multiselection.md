# Multiselection

Unity-style multi-selection in the hierarchy, scene view and project view.
The inspector edits the whole selection (see [Multiedit](#multiedit)). The
header says "N selected".

State lives in `editor/selection.odin`: an ordered set per domain (scene
Transform_Handles, project paths) where the LAST item is the active one.
Dead handles are pruned each frame. `projectViewData.selectedFile` remains
the active project path, so single-target code paths are unchanged.

## Interactions

Everywhere (hierarchy rows, scene-view picking, project list rows):

- **click** — select only this
- **cmd/ctrl-click** — toggle in/out. The added item becomes active. Clicking
  empty scene space with cmd held does not clear
- **shift-click** — range from the active row over the visible rows, replacing
  the selection (hierarchy + project list, not scene picking)
- **shift + up/down** — extend row by row
- **LMB-drag** (scene view) — rubber-band box select. Live while dragging,
  cmd/ctrl adds to the set, Escape cancels, one selection-undo step per gesture
- **Escape** (scene view) — clear

The active row is outlined in the hierarchy when more than one is selected.
The project status line shows the count.

## Actions on the selection

- Hierarchy context menu: **Delete Selected** / **Duplicate Selected** act on
  every eligible object as one undo step. Children of selected ancestors are
  skipped — the ancestor's operation covers them
- **Edit/Toggle Transform Active** (Alt+Shift+A) toggles all selected, one step
- Right-click on a selected row keeps the selection. On an unselected row it
  selects that row first
- **Gizmo drags move the whole selection** (Unity): translate offsets every
  object, rotate orbits positions and spins orientations, scale scales offsets
  and local scales — one undo step per drag. The gizmo anchors at the active
  object's pivot or the selection center (Pivot/Center overlay toggle)
- **F** frames the selection (bounds union)
- Single-target actions use the active item: rename, Create Empty
  Child/Parent, project open/rename/Extract/Scene Variant, drag-drop payloads

## Multiedit

Editing a field writes it to every selected object as one undo step (an edit
session over all of them — see [Undo](Undo.md)). The inspector shows the
Transform plus the components every selected object has. A component only some
carry is hidden.

Fields the selection disagrees on show Unity's mixed indicator: a dash instead
of the number, an empty text box, a dash in the checkbox. Vectors mark each
axis separately. Editing a mixed field assigns the typed value to everything.

The dash is ASCII `-`: the font atlas has a limited glyph range and renders an
em dash as a `?` box.

### Arrays

Rows draw up to the **shortest** array in the selection, each an ordinary
field with its own dash. Rows past that length have no counterpart on some
object, so there is nothing to edit. When lengths differ the size row explains:
`Size: - this object N, showing M common`.

**Add and remove apply to the whole selection**, so lists converge as you work
and a new row is immediately editable everywhere. Drag reordering stays
single-object — a permutation of one array means nothing on a peer whose
contents differ (Unity suppresses it too).

A dynamic array's elements live in a separate allocation, so a peer's element
cannot be reached by offset from the component base. The peer list is rebased
onto each peer's element storage before the rows draw
(`multi_rebase_to_dynamic_array`), after which element i is at `i*elem_size`
on every object.

### Prefab instances

Instance content multi-edits like anything else (Unity). An edit records an
override against its own instance — each `Multi_Peer` carries the
host/local-id pair naming which one — so a selection mixing plain objects and
instance content works uniformly: overrides on the instances, plain writes on
the rest, one undo step for all of it.

### Not multi-edited

- **Union fields.** The variant can differ per object, so the same bytes mean
  different things.
- **The component overflow menu** (Reset, Copy, Paste). These act on the
  active object only.

### How it works

The inspector draws ONE object and knows nothing about selections. Multiedit
is two ambient facts set around each drawer call
(`editor/inspector/multiedit.odin`): the same field on the other selected
objects, and whether they agree with the drawn value. A drawer reads the mixed
flag if it wants the dash, writes the value as it always has, and never learns
a selection exists.

That keeps custom `@(property_drawer=...)` drawers working unchanged —
ignoring the flag shows the active object's value. Drawers built on
`field_row` / the `drag_*` helpers get the dash for free.

Properties to know when extending this:

- **The property-list intersection is `TypeKey` equality.** A component's
  fields come from its Odin struct type, so two objects with the same
  component type have identical fields by construction. Instances pair by
  (TypeKey, nth of that type).
- **Propagation serializes, it does not copy bytes.** A field can own heap
  memory (string, dynamic array, a Ref with a resolved handle), and a memcpy
  hands N objects the same backing pointer — the first cleanup frees it out
  from under the rest. Writes go through `undo.write_json_value`, the same
  capture / cleanup / unmarshal / rebind sequence undo applies.
- **Vector edits are fieldwise.** Dragging one axis writes only that axis to
  the peers. The touched components come from diffing against a pre-edit
  snapshot, captured when the gesture begins — a drawer writes through a
  pointer, so the new whole value alone does not say which part moved.
- **Rotation works in euler space, not on its stored value.** The field is a
  quaternion but the row is three euler boxes, and the two do not correspond:
  the quaternion is rebuilt from all three angles on every edit, so which axis
  moved is unrecoverable from it, and peers that agree on the edited axis
  still hold different quaternions. Rotation therefore keeps its own edit path
  (`_wrap_transform_rotation_override`): mixed flags compare displayed angles,
  and the edit gives each peer the active object's value on the moved axes
  only.

## Not yet

- Multi-path drag-drop from the project view
