---
title: "Animation component"
description: "The Animation component that owns a PlayableGraph and drives clip playback state and time on a transform hierarchy"
weight: 10
tags: ["animation", "components", "engine"]
---

Plays animation clips on a transform's hierarchy. One component owns one
PlayableGraph (plugins/animation/docs/PlayableGraph.md) and drives it: it holds the playback
state, restructures the graph between evaluations, and advances time. The graph
itself stays a pure evaluator.

There is no state machine. What follows what is ordinary gameplay code calling
this API. What the component holds is the LIST of things that can be played.

```
Animation
├── clip                one clip, played on the first tick if play_automatically
├── play_automatically
├── speed               scales time for every state on this component
└── layers              the states, as a tree per layer
```

## States

A layer holds a tree of ENTRIES. An entry is one state gameplay can play:

- **Clip** — plays one clip.
- **Blend1D** — blends its children along one axis by a value.

```
Layer 0
├── Locomotion   Blend1D, value 0.4
│   ├── Walk     at 0.0
│   └── Run      at 1.0
├── Idle         Clip
└── Death        Clip
```

Each entry carries:

| field     | meaning                                                     |
|-----------|-------------------------------------------------------------|
| `id`      | minted on add, never reused — what the play API takes        |
| `parent`  | another entry's id, 0 for a state directly on the layer      |
| `pos`     | placement in the PARENT's blend space (1D reads x)           |
| `name`    | what `animation_find` looks up                               |
| `wrap`    | Default defers to the clip, else Once or Loop                 |
| `kind` | `Animation_Entry_Clip` or `Animation_Entry_Blend1D`                              |

Ids rather than indices, because deleting a sibling shifts every index after it
and would silently repoint a play call at a different state. `TimelineAnimator`
follows the same rule — its `State_Id` is a minted `Timeline_State.id`, filled
in by `_ta_ensure_ids` for states added through the inspector's array rows.

`pos` lives on the CHILD, not as a threshold list on the parent. A child then
works under any blend kind without knowing which it is, and switching a blend
from one axis to two keeps every child's x.

### Why the tree is stored flat

`entries` is one array per layer and `parent` is an id, rather than each blend
holding its own children. A recursive union serializes and undoes badly here:
the JSON nests without bound, and an undo edit lands inside a union inside an
array inside a union, where a missing `register_pointer_type` makes it silently
no-op. One array is one undo edit and one JSON array, and it still draws as a
tree.

`Animation_Entry_Kind` is `#no_nil` with `Animation_Entry_Clip` first. A nil union marshals
to bare `null`, which the generic union reader cannot read back, and the whole
owning component is then preserved verbatim as an unknown one — the object reads
"Missing Component" and every field vanishes because one variant was unset. An
empty clip entry is the natural zero, and it is what an author gets when they
add a state before picking its clip.

Both variants carry a `@(typ_guid)`, and that is what gets the union
serialized: `union_gen` (a prebuild module) finds every hand-written union
whose variants all carry the tag and emits the guid-tagged marshaler
registration into that package's `unions_generated.odin`, so no package has to
remember it. Without the registration the default marshaler writes the active
variant's fields with no tag, which reads back as the zero variant: a blend
saved and loaded comes back a clip, quietly. A union with an untagged variant
is left alone and keeps the default marshaler.

### Wrap

**The clip is the default and the state overrides it.** A walk cycle is cyclic
and a death is one-shot, so the motion usually knows — `AnimationClip.wrap` is
the answer most of the time, and an entry left at `Default` takes it. The state
overrides for the case one clip is played both ways.

The override sits on the STATE rather than the component on purpose. A
component holds Idle and Death at once, so one wrap for both can never be
right: a component-wide `wrap_mode = Loop` is what made Death loop in this
package's own demo, and removing that field is what fixed it. A clip played by
guid has no entry and takes the clip's wrap.

A **blend** reads its own entry, not any child's clip. Children share one
phase, so no single child's wrap is the blend's — a child's clip is only the
fallback when the blend says Default.

Other systems answer this differently and it is worth knowing why. A legacy
clip player overrides at three levels (clip, component, playing state). A
mecanim-style controller has no wrap on a state at all — looping is a clip
import setting, because the motion owns it. A timeline adds a separate
EXTRAPOLATION concept (hold, loop, ping pong) for what a track does outside a
clip's extent, rather than reusing wrap for it. We sit between the first two:
the clip owns the default, one level above overrides, and the coarse
component-wide level is gone.

## API

```odin
animation_play(a)                       // the `clip` field, from the start
animation_play_clip(a, clip, layer)     // a clip by guid, cut
animation_cross_fade(a, clip, dur, layer)
animation_cross_fade_queued(a, clip, dur, layer)
animation_stop(a)

animation_find(a, name) -> (id, ok)     // a state by name
animation_play_entry(a, id, duration)   // a state by id: clip or blend
animation_blend_set(a, id, value)       // move a blend along its axis
animation_blend_get(a, id)
animation_entry(a, id) -> ^Animation_Entry
```

`animation_play_entry` with `duration` 0 cuts, above 0 cross-fades. Playback
always starts at the beginning: a state asked for is a state from the top.

A blend's value lives on the AUTHORED entry and the runtime reads it every
tick, rather than being copied into the playing state. One field, one source of
truth — an inspector slider and a gameplay call are then the same edit, and
setting it on a state that is not playing decides where it starts.

## What the graph looks like

The tree is the authored shape. The graph holds only what is PLAYING, so the
two are deliberately different:

| authored            | graph                                             |
|---------------------|---------------------------------------------------|
| layer               | one input of the layer mixer                      |
| Blend1D             | a mixer, built with ALL its children at once      |
| Clip                | a clip node, built only when it plays             |
| a state not playing | nothing at all                                    |

```
layer mixer
└── layer 0 mixer
    └── Locomotion mixer        weight = the state's fade weight
        ├── walk clip node      weight from the 1D rule
        └── run clip node
```

A blend is ONE state with one weight: its mixer takes the fade, and the parent
weight premultiplies down the subtree during evaluation, so fading a blend in
fades both children together.

That asymmetry is why the tree cannot be a view of the graph, and why the play
buttons in the inspector call the driver rather than touching graph nodes.

Every reader builds nodes through one primitive, `animation_entry_build`: the
driver for the states that play, and `animation_graph_build_authored` — which
the Playable Graph window draws, and which the editor preview evaluates for
both a clip scrub and a played state — for the whole tree at once. One builder,
so the window cannot show a shape the component would not play.

`animation_graph_build_authored` reports an `Animation_Authored_Leaf` per clip: the
`Animation_Blend_Child` the 1D rule needs, which top-level entry it belongs to, and
the chain it hangs from (`under`, `top`, `layer`). Lighting a clip inside a
blend means weighting that whole chain — the clip under the blend's mixer AND
that mixer under the layer — since a blend left at 0 reaches the pose with
nothing.

Nested blends are not built. A blend child that is itself a blend is skipped
rather than flattened, so the graph never silently means something other than
the tree.

## Blend1D

Children are sorted by `pos`. The two bracketing the value share the weight
linearly, and the ends clamp — past the last child the last child owns the pose,
rather than falling off toward the default pose.

**Children share one phase.** A blend does not run its children on their own
clocks. It holds a normalized `phase` in 0..1 and samples each child at
`phase * child_length`, so a 1.07s walk and a 0.77s run keep their footfalls
together. Sampling both at the same absolute seconds is what makes blended
locomotion slide.

The phase advances at the BLENDED cycle length:

```
cycle  = lerp(len_lo, len_hi, k)      // the same k the weights use
phase += dt * speed / cycle
```

so leaning toward the run speeds the cycle up on its own, which is what makes a
walk-to-run blend read as one gait rather than two.

Wrap follows the first child's clip, the same "defer to the clip" rule a single
clip state uses — a blend has no clip of its own to ask.

## The playing state

A playing state is `Animation_State_Runtime`: the fade fields and `done`, plus a
`kind` union of `Animation_State_Clip` (a clip and its clock in seconds) and `Animation_State_Blend`
(its children and a shared phase). Runtime only and never serialized, so unlike
the authored `Animation_Entry_Kind` it carries no guid and needs no marshaler —
but it is a union for the same reason, so neither kind holds the other's fields.

## Fades

Fades are weight-continuous, which is what makes interruption smooth with no
snapshot machinery. Cross-fading to C in the middle of an A to B fade just
retargets: A and B fade to 0 FROM THEIR CURRENT WEIGHTS while C fades in.
Weights on a layer sum to 1 whenever they summed to 1 before, and the first
fade-in on an empty layer blends up from the default pose.

Fades run on real time and ignore `speed`.

A Once state that runs past its end holds its final pose (`done`) until
everything is done or something replaces it. When every state is done the
component stops evaluating and freezes on that pose.

## Layers

The index in `layers` is the layer index, and a higher layer overrides a lower
one wherever it animates — the layer mixer stacks bottom-up over the default
pose.

`play` and `cross_fade` called without a layer argument resolve the clip's layer
from the authored entries (a clip inside a blend counts: the blend is what
plays, but the layer is the same). An explicit layer argument overrides, and an
unlisted clip lands on layer 0.

## The States tree

`plugins/animation/editor/inspector_animation.odin` draws `layers` in the
inspector, and the field is `inspect:"-"` so the reflected field loop skips it —
a tree of arrays of unions is the shape those rows draw worst.

Each row carries what its kind actually has: a clip entry gets a clip picker, a
blend gets a value slider spanning its children's positions plus a row per
child with that child's position on the axis.

The play button never touches graph nodes. While simulating it calls
`animation_play_entry` and lets the next tick rebuild the graph. In edit mode
nothing ticks the component, so it drives the animation window's preview
instead — ONE preview in the editor, so a state and a clip scrub can never pose
the same object at once. Entering state mode ends a scrub, picking a clip in
the window ends the state, and the button turns into a stop while its state is
previewing.

A previewed blend runs exactly as a played one does: the same
`animation_blend1d_weights` and `animation_blend_sample`, on a graph built by
`animation_graph_build_authored`. So dragging a blend's value in the tree moves
the character in edit mode.

Removing a blend takes its children with it. A child whose parent is gone is
unreachable, unplayable, and invisible in the tree.

## The Animation window

`plugins/animation/editor/view_animation.odin` is the clip EDITOR: a dope sheet
and curve view over one clip's channels, with recording, add-property and
per-key editing.

It is component-bound, not asset-bound. `_pv_target` walks up from the selection
to the nearest `Animation`, so selecting a child bone keeps the window on the
animated root, and the clip dropdown lists every clip reachable from that
component — the `clip` field plus every clip entry on every layer, blend
children included. A clip appears there because something references it, not
because it exists in the project.

Edits go through an `inspector.Asset_Doc`: Save writes the document to the
`.anim` file, and unsaved edits revert. The scrub preview evaluates the
component's full authored graph with the scrubbed clip at weight 1 and
everything else at 0, so the preview path is the graph the component actually
plays and the Playable Graph window shows the real topology.

The sheet groups the rows by the transform they animate (`editor/sheet_rows.odin`). Each animated transform has an Object row, in the order its first channel appears in the clip, labelled with the transform's name (the animated object's own name for the object itself). Its property rows follow it, indented, labelled with the component and field or Position, Rotation and Scale.

- Object rows sit at the column's edge whatever their depth, their property rows one step in. The row shows the transform's name only. The tooltip shows the full path. A target that does not resolve under the animated object shows its name in the warning colour the unresolved property rows use.
- A click on an Object row's name pings the transform in the hierarchy, a double-click selects it. Neither changes the keys.
- Retargeting: Edit Path in an Object row's context menu opens a field holding the full target path, at the row's indent. Enter, or Escape as in every text field, sets the target of every channel of that object to the typed path, spaces trimmed, as one undo step (`animation_view_retarget`). A click elsewhere cancels. A clip inside a model has no field. An unresolved path shows in the warning colour and can be edited again. The collapsed state follows the row to its new path.
- The arrow on an Object row collapses it, hiding its property rows. Collapse state belongs to the window copy and is not saved. Adding a property under a collapsed object expands it.
- In the dope sheet an Object row shows an outlined summary key at every time where any of its property rows has a key, hidden rows included. Keys within half a frame after the first key of a run count as one.
- Clicking a summary key selects every key it stands for, the first of them becoming the primary key. Dragging it moves them together. A modifier click adds them to the selection or removes them. A box selection over an Object row selects its channels' keys in the band.
- A press on an Object row's name selects no key. Double-click on a key, Remove Property and Add Key act on property rows only, and the curve view plots only the selected property row.

### Lane rows

A vector row (Position, Scale, Euler, or a field of 2 to 4 float lanes, never Rotation) has an arrow before its label. It is collapsed by default. Expanded, a Lane row per enabled lane follows it, labelled x, y, z or w, one step further in (`Sheet_Row_Kind.Lane` in `editor/sheet_rows.odin`). A disabled lane has no row. The expanded state belongs to the window copy, like the Object rows' collapse, and is not saved.

- A Lane row shows the keys of the channel that animates its lane, in the lane's curve colour: the property row's keys for a joined row, the lane's own channel for a split row ("Split lanes" below).
- A Lane row is a view of the property row's keys: a click, a drag, a modifier click, a double-click and a box selection on it act as they do on the property row. A key caught by both a property row and its Lane rows in one box is selected once. A right-click on a key opens the key menu, as on the property row.
- The property row's context menu has a Lanes group above Remove Property: one checked item per lane of the row's width, checked when the lane is enabled. A click toggles the lane, one undo step. Unchecking the last enabled lane removes the whole row in that same step, without asking, as Remove Property does.
- The property row's value fields keep every lane in its column: an enabled lane shows its field, a disabled lane a dimmed dash. The selected key's footer does the same.
- The curve view plots, hit-tests and draws tangent handles for the enabled lanes only.

### Record

While Record is armed, an edit of an animatable field keys the clip at the playhead instead of changing the object (`editor/record.odin`). Any edit that records undo counts: an inspector row, a gizmo drag, a multi-object edit.

- The field belongs to the animated object or an object under it: a component field whose type is animatable (the kinds Add Property lists) or a transform's position, rotation or scale.
- A missing row is created the way Add Property creates one. Its key at the clip start holds the value from before the edit, and the key at the playhead holds the edited value. An existing row gets a key at the playhead, or its key there takes the edited value.
- The object keeps its own value. The preview poses it from the clip, so the key shows at the playhead, and leaving the preview shows the object's own values again. The scene is not changed.
- The clip edit is the only undo step: one Ctrl+Z removes the key, and the row with it when the edit created the row.
- Each object of a multi-object edit is keyed or left alone on its own.

An edit that cannot be keyed stays an ordinary scene edit with its own undo step:

- the field type is not animatable (an array, a plain struct, a `Ref`, `Ref_Local` or `Owned` reference). The window shows a note under the toolbar naming the field and its type, until the next note or until Record is disarmed
- the object is neither the animated object nor under it
- the clip has no document (a clip inside a model is read-only, and Record is off for it)

An inspector edit of a field the inspector shows as driven (a field the shown clip has a row for) goes to `inspector.driven_commit` when the gesture ends (docs/core/Undo.md "Driven values"): `editor/record.odin` keys the edited value at the playhead in one undo step on the clip, and the live field is never written. Every other edit goes through the undo package's commit listener (docs/core/Undo.md "Commit listener"): the listener keys the clip and marks the entry consumed, and the undo package puts the object's old value back. Gizmo drags and multi-object edits take this path.

### Preview values in the inspector and the rows

The preview poses the object only around the scene and game render, so the live fields hold the object's own values. The inspector shows the preview's values anyway: `editor/record.odin` installs `inspector.driven_provider` (docs/core/Undo.md "Driven values"), which answers for a field the shown clip has a row for, on the animated object or under it, with the row's value at the playhead.

- Preview on, Record off: the field shows the clip's value in the theme's accent color, with a bar left of the label, and ignores edits. An edit there would change the object's own value, which the pose hides, so the field takes no edits.
- Record armed: the field shows the clip's value in red. When a drag is released or a typed value lands, the edited value is keyed at the playhead through `inspector.driven_commit`, one undo step on the clip. The object's own value, the scene undo stack, the prefab overrides and the other selected objects are not touched. A value equal to the object's own value is keyed like any other.
- A field without a row, an object outside the animated object, a state preview from the States tree, or the preview off: the field shows the object's own value as usual.
- Rotation shows euler angles in degrees: an Euler row's angles over the transform's own rotation, or the angles of a Rotation row's quaternion. An edit keys an Euler row's angles, or the quaternion built from the angles for a Rotation row.
- A string field is never driven: the inspector's string drawer frees the string it edits, and a driven string would be the clip's own. The field shows the object's own value, and recording and Add Key still key it.
- A row drawn by a decorator (a color swatch, a range slider) shows the clip's value the same way and keys an edit the same way.
- While the window shows a clip, preview on or off and Record armed or not, a field the clip has a row for and the preview does not drive now has a dimmed green bar left of its label (`inspector.driven_row_state`). A driven field shows the driven tint and bar instead.
- While recording, the field's context menu has "Add Key" (`inspector.driven_add_key`) for an animatable field on the animated object or under it, when the clip has a document. It keys the value the field shows at the playhead, creating the row when missing, in one undo step. On a driven field that is the clip's value, so the key pins the current pose. When the playhead's frame already has a key for the row, the item is "Delete Key" (`inspector.driven_delete_key`) instead, and a row left without keys goes with it. The transform rows have both too.
- A driven field whose row has a key on the playhead's frame shows a filled diamond beside its bar. No key, no diamond.

Each property row in the window shows its value at the playhead after its name: one small field per lane (a vec3 three, a bool a checkbox, an int or enum an int field). A string row shows a text field: Enter (or Escape, as in every text field) keys the typed text at the playhead, and a click elsewhere drops it. A reference row shows the asset picker the inspector's `PPtr` fields use, filtered by the field's `ext:` and `ref:` tags: a pick or a drop keys the new reference at the playhead. In the selected key's footer the same fields set that key's value instead, and a key of an int row shows its value as text. The dope sheet draws the keys of these rows as diamonds like any other. The curve view plots float rows only. A Rotation row shows three euler angles in degrees, converted from the sampled quaternion as the inspector's Rotation row converts, and an edit keys the normalized quaternion built from them. Editing a field keys the row at the playhead with the edited value: a key already at the playhead takes it, else a key is added. One drag or typed value is one undo step. A clip inside a model shows the values read-only. The selected key's footer shows a rotation key as three euler angles too.

### Key modes and tangents

The key context menu (a right-click on a key, in the dope sheet or the curve view) starts with a Mode group, above Delete:

- Linear, Smooth, Step and Free, each checked when every selected key has that mode. A pick sets the mode on every selected key, one undo step.
- A row stored without `modes` gets them on the first pick: every key takes the mode it already plays with (Step for a row with `step` set, else Linear), `step` is cleared, and then the selected keys change.
- A key turning Free keeps the tangents it plays with (the Smooth or Linear slopes), so the curve does not move.
- A Rotation row offers Linear and Step only, since rotations slerp and ignore tangents. A key of an int, reference or string row always holds: the group shows Step, disabled.

Below the modes, the tangent presets turn every selected key into a Free key with these tangents (`editor/curve_tools.odin`):

- **Flat**: both tangents zero, an ease in and out
- **Ease In**: the in tangent zero, the out tangent the straight slope to the next key
- **Ease Out**: the out tangent zero, the in tangent the straight slope from the previous key
- **Auto**: the tangents a Smooth key has, stored on the key

The selected key's footer shows the primary key's mode as a combo next to its time field, with the same choices. A pick applies to every selected key, as in the menu.

In the curve view every Free key of the plotted row shows its tangent handles: a line from the key along each tangent to a small circle 40 px away, in the lane's colour, the hovered or dragged handle brighter. Smooth and Linear keys show none.

- Dragging a handle sets that side's tangent of that lane to the slope from the key to the pointer, one undo step per drag. The in handle changes only the in tangent and the out handle only the out tangent.
- Holding Shift while dragging sets both tangents to the same slope: a smooth joint.
- A press near both a handle and a key takes the handle.
- The value range of the view takes in the handle points, so a steep handle on a flat curve stays visible.

## Sample

`packages/animation/samples/animation_sample` (installed as the
`packages/animation_sample` symlink) ships `animation_demo.scene`: the essentials plugin's UAL1 character (`meshes/characters/UAL1_Standard.glb`), a skinned mesh posed by `SkinnedMeshRenderer`, and one layer holding a `Locomotion` blend over walk and run plus Idle, Jump and Death. The states play the model's own clips, referenced by the model's guid and the clip's id, so no clip is extracted.

`animation_demo.odin` is the part a game writes. It plays states BY NAME and
pushes its `blend` field into the Locomotion blend every frame, the way a
character controller would push its own speed. Writing it every frame rather
than on change is deliberate: it is the shape real gameplay has.

`test_animation_demo_scene_loads` loads the scene, checks the tree survived
serialization, and plays the blend through to a posed joint. The scene is
hand-generated JSON carrying hand-written union tags, which is exactly the kind
of asset that rots silently.

## Clip format

A `.anim` file, a baked clip artifact and a clip inside a model share one JSON shape: `length` and `channels`. A channel is one row of the sheet:

```json
{
  "target": "Body/Arm", "path": 0, "component": "", "field": "", "step": false,
  "times": [0.0, 0.5, 1.0],
  "values": [[0, 0, 0, 0], [0, 1, 0, 0], [0, 0, 0, 0]],
  "modes": [1, 3, 0],
  "tangents": [[[0, 0, 0, 0], [0, 0, 0, 0]], [[0, 2, 0, 0], [0, -1, 0, 0]]]
}
```

`times` and `values` are parallel. A row animates one field, so all its keys share one kind (`Channel_Values` in `clip.odin`):

| kind | fields | between keys | in the mixer |
|------|--------|--------------|--------------|
| floats, `[x, y, z, w]` | f32, `[2..4]f32`, colours, position, scale, rotation | interpolated | weighted sum, rotations nlerp |
| ints | ints, enums, bools | held | the highest weight wins |
| references, `PPtr` | `PPtr` and `Asset_GUID` fields (a bare guid reads as local id 0) | held | the highest weight wins |
| strings | `string` fields | held | the highest weight wins |

Ints are i64, so an id or a bitmask keys exactly. A string belongs to its row. On a string field the write frees the field's old string and stores a clone, and an equal value writes nothing.

The variant is told by the element type of `values`, so the key stays `values` for every kind:

- an array (`[x, y, z, w]`): floats
- a number: ints
- a string: strings
- an object (`{"local_id": 7, "guid": "..."}`): references
- an empty array: floats

A float row is the array of 4-lane arrays it has always been, so every `.anim`, artifact and model clip reads as it is. The rule lives in a JSON marshaler and unmarshaler for `Channel_Values`, registered on SerializationInit with the marshaler maps every load and save goes through (the artifact load, asset documents, undo).

`path` is a number on disk (`Animation_Path` in `clip.odin`): `0` Position, `1` Rotation, `2` Scale, `3` Euler. A property row ignores it.

- A Rotation row (`"path": 1`) holds unit quaternions `[x, y, z, w]` and slerps between keys. Model clips and baked glTF clips keep Rotation rows.
- An Euler row (`"path": 3`) is the same rotation as euler angles in degrees, `[x, y, z, 0]` in the inspector's order (`engine.quat_to_euler_xyz`, `animation_quat_from_euler`).
- An Euler row is a 3-lane vector row: each lane interpolates on its own by the key modes, with no slerp, and the row can mask lanes and split like a Position row.
- Recording and Add Property create Euler rows for a transform's rotation.
- A clip can hold a Rotation row and an Euler row for one transform. The Rotation row gives the quaternion, then the Euler row's enabled lanes replace those angles of it. Without a Rotation row the Euler lanes replace angles of the transform's own rotation.
- The direct apply (`animation_clip_apply`) and the mixer both write a rotation this way. The mixer blends the bound Rotation rows' quaternions first (`Binding_Slot.rot_quat`), then the Euler lanes on top (`_finalize_rot` in `playable_graph.odin`).

### Lanes

A float row of 2, 3 or 4 lanes can animate only some of them. Animating `position.y` alone leaves x and z to the object.

```json
{ "target": "", "path": 0, "times": [0.0, 1.0], "values": [[0, 0, 0, 0], [0, 2, 0, 0]], "lanes": [false, true, false, true] }
```

- `lanes` holds one bool per lane, x to w, true for a lane the row animates. A lane the array does not reach animates. The key is absent when every lane animates, so every file without it reads as it always has.
- In memory the row holds the disabled lanes, `Animation_Channel.lanes_off`, so the zero value is "every lane". A JSON marshaler and unmarshaler for `Channel_Lanes_Off` turn it into `lanes` and back, registered with the `Channel_Values` ones.
- The width comes from the field: Position, Scale and Euler are 3 lanes, a property row as many as its field's type (`animation_channel_lane_count`, `animation_channel_lanes_off` in `clip_property.odin`). A lane past the width never counts as disabled.
- A Rotation row and a scalar row ignore the mask: every lane animates.
- A mask with every lane disabled is valid but nothing writes one: the Animation window removes the row with its last lane.

How a mask applies:

- A write of the row reads the field, replaces the enabled lanes and writes it back (`_prop_write_value` with the lanes to keep). The other lanes keep what the field holds.
- In the mixer a disabled lane contributes nothing. When the pose is written, a lane no bound row animates keeps the field's value at that moment, not the value captured at bind time, so an edit of that lane holds.
- Each lane blends on its own (`Lane_Acc` in `playable_graph.odin`): a lane's value is the blend of only the clips whose row enables it, and the row's weight across every clip that animates the field decides how much of the default shows. Two clips at 0.5, one animating x and the other y, give x the first clip's full value and y the second's.
- Several channels of one clip on one property merge per lane the same way (`_lane_acc_leaf` accumulates into the slot), so each lane of a split row takes its own channel's value.
- The inspector's driven value fills the disabled lanes from the live field, so it shows the clip's lanes and the object's own lanes together.
- Recording into a joined row keys the whole vector and enables every lane of the row. Recording into a split row is below.

The live field's type decides how a row applies. A float row on an int or bool field writes its first lane rounded, an int row on a float field writes the int. A row of any other kind than the field's writes nothing, like a row whose field does not resolve.

#### Split lanes

A vector row (Position, Scale, Euler, a vector field) is joined or split (`editor/lane_split.odin`).

- A joined row is one channel: every lane shares the key times. Joined is the default.
- A split row is several channels with the same target and property, one per lane, each masked to its lane through `lanes` and each with its own key times. A lane can have keys on frames the other lanes have none.
- On disk a split row is just those channels. There is no new field: the shared target and property group them, and each channel's `lanes` says which lane it animates.
- Joined is cheaper: one time and one value per key instead of one per lane, and one curve evaluation per sample instead of one per channel.
- Split Lanes and Join Lanes are in the property row's context menu. Split Lanes needs a vector row with two or more enabled lanes that is not split yet. Join Lanes needs a split float row.
- Split copies the row once per enabled lane, times, values, modes and tangents included, and masks each copy to its lane.
- Join puts the union of the channels' key times into the first channel. Times within half a frame of an earlier one fold into it.
- Join samples each lane from its own channel at every time and gives the keys Free tangents from each lane's slopes, so the lanes keep their curves.
- A joined key is Step only where every lane steps there. Otherwise it is Free.
- A lane no channel animates is disabled in the joined row. Join frees the other channels.
- In the sheet a split row is one property row. It shows summary keys like an Object row, one per time where any of its lanes has a key, and its Lane rows own their keys: each Lane row shows and edits the keys of its lane's channel.
- The Lanes menu on a split row adds a channel for an enabled lane (a copy of the first channel masked to that lane, after the group) or removes the lane's channel.
- Recording into a split row keys only the lanes the edit changed, each in its own channel. An undo-recorded edit compares with the value before the edit, an inspector edit of a driven field with the value the rows show at the playhead.
- Add Key keys every lane of a split row. Delete Key removes the playhead key in every channel of the field.

### Interpolation

A float row carries per-key interpolation in two optional arrays parallel to `times`:

- `modes`: one `Key_Mode` per key, `0` Linear, `1` Smooth, `2` Step, `3` Free. A key past the end of `modes` is Linear. A channel with no `modes` and `step` set holds on every key, which is how STEP clips are stored.
- `tangents`: in and out slopes per lane, in value units per second, read by Free keys only. A Free key past the end of `tangents` has flat tangents.

Between key A and key B:

- A is Step: A's value holds until B
- A and B are Linear (or B is Step): lerp
- otherwise a cubic Hermite curve with A's out slope and B's in slope. A Linear key uses the slope toward that neighbour, a Smooth key the slope between its two neighbours (flat at the first and last key), computed when sampled, so nothing is stored for it. A Free key uses its tangents

Rotation rows slerp and ignore tangents. Step still holds. Int, reference and string rows always hold.

Adding a key keeps the parallel arrays in step: when the row has `modes` the new key takes the mode of the key before it, and a Free key gets the curve's slope at its time on both sides, so the curve keeps its shape. Deleting a key removes its mode and tangents. The trim setting keeps curves too: kept keys become Free with the slopes they had, and the edge keys are Free with the slope at the cut.

glTF samplers bake as follows:

- LINEAR: Linear keys, no `modes`
- STEP: `step` set
- CUBICSPLINE: every key Free, with the sampler's in and out tangents. glTF tangents are already in value units per second, so the clip plays the exact curve

The Animation window sets modes, applies tangent presets and drags tangent handles ("Key modes and tangents" above), and keeps `modes` and `tangents` in step as it adds, moves and deletes keys.

## Clip settings live in the meta

A clip is an IMPORTED asset, like audio and textures. Its settings are authored
in the `.meta` and baked into the artifact at import, so the runtime loads one
file and never opens a meta.

```json
{
  "guid": "5de156d5-...",
  "importer": "animation",
  "settings": {
    "__type_guid": "6b1f9d3a-...",
    "wrap": 1, "frame_rate": 60.0,
    "cycle_offset": 0.0, "trim_start": 0.0, "trim_stop": 0.0
  }
}
```

| setting        | effect                                                        |
|----------------|---------------------------------------------------------------|
| `wrap`         | Once holds the final pose, Loop restarts. Every state's default |
| `frame_rate`   | the editor's key and playhead grid. Authoring only              |
| `cycle_offset` | where in a loop sampling starts, as a fraction of the clip      |
| `trim_start` / `trim_stop` | the sub-range to keep, in source seconds          |

They live there rather than in the `.anim` because a clip extracted from a model
is a GENERATED file: extraction rewrites it so a re-exported model can refresh
its curves, and anything authored has to survive that. The meta is a separate
file, so it does. A source `.anim` therefore carries only `length` and
`channels`.

`cycle_offset` is honoured in `animation_clip_sample_time`, called at the one
place a clip is evaluated — so the driver, the editor preview and a timeline's
animation track all get it without cooperating. The trim is BAKED instead: the
importer drops keys outside the range, rebases the times and keeps an
interpolated key at each edge, so a cut between keys starts on the value the
clip actually had there and nothing pays for it at runtime.

## Clips inside a model

A glTF file's animations play without being extracted. The mesh importer bakes each one to its own sub-asset file beside the model's artifact, `<key>_s<clip id>.bin` (see [Sub-asset files](../../../docs/core/AssetPipeline.md#sub-asset-files)), and lists it in the model's settings:

```json
"clips": [
  { "id": 2, "name": "Walk_Loop" },
  { "id": 3, "name": "Idle_Loop" }
]
```

A clip is a sub-asset of its model, named as `{model guid, clip id}`: that is what a `clip: PPtr` field stores, and a standalone `.anim` is `{its guid, 0}`, so one field takes both. The id is minted at first import and kept across reimports by matching the clip's name, the way part ids are. The runtime reads the clip's file by its id, once the clip list the model's settings carry confirms the clip (`mesh_clip_index`), so a build and an export resolve it the same way. An export ships only the clips something references: the animation sample plays 5 of UAL1's 43 clips and ships those 5. A model under a `resources` folder ships every clip. Parts, clips and convex decompositions share one id space, since a sub-asset id must be unique within its model.

What lands in the repository is the model and a few lines of its `.meta`. The curve data stays in `library/`, rebuilt from the model on any machine.

In the project view a model expands to its parts and its clips. A clip row drags onto a clip field, and the picker lists clips as `Model / Clip` under their owner. Assets / Extract Assets remains the way to get an editable standalone `.anim`, the "duplicate to edit" step, and a hand-authored clip is still a standalone `.anim`.

Selecting a clip under a model shows the model's import settings and, below them, that clip's own `Animation_Clip_Settings`. They live in the clip's entry in the model's meta and bake on Apply, the same rule a standalone `.anim` follows. The Preview pane poses the model's skeleton with the clip, playing or scrubbed by a slider, and the grid shows each clip at its midpoint. A clip that disappears from the model, renamed in the DCC tool for instance, stays in the list as an orphan so its guid keeps resolving, and its section offers a remap onto one of the model's current clips, which then takes over the guid. The clip section and the sampler that poses the preview rig belong to this plugin (`editor/model_clips.odin`): the editor lists a model's clips without it, but draws no clip section, preview or thumbnail (`subassets.clip_sampler`). Extract Assets writes clips through `asset_pipeline.gltf_clip_extractor`, which this plugin installs next to the clip baker.

### Settings deliberately absent

A knob that does nothing is worse than a missing one, so these wait for the
system behind them:

- **Mirror** needs a left/right bone mapping. There is no avatar.
- **Root motion** — bake into pose, orientation and Y/XZ offsets, height from feet — needs a root-motion system.
- **Additive reference pose** needs additive layers. Layers here override rather than add.

### The Animation window

A clip inside a model opens read-only: the window shows its keys and curves, previews, plays and scrubs it, and selects keys to show their values, but adds, moves and deletes nothing, and Record is off. The clip has no document to edit. The model's file is its source, and the clip is rebuilt from it on every import. The toolbar shows Read-Only and the clip list marks such clips. Assets/Extract Assets makes an editable standalone `.anim`. A missing or unreadable `.anim` edits nothing either, but it is not marked Read-Only: the sheet says the clip is missing.

By default playback respects the clip's `wrap`: a Once clip plays through and stops, a Loop clip cycles. The window reads the IMPORTED clip for that, not the document it is editing — the document holds keys, the meta holds wrap.

The playback toggle after the transport buttons overrides it. A click steps through three states:

- **Match the clip's wrap setting** (the default): plays as described above.
- **Play once**: plays through and stops, even a Loop clip, to look at its end pose.
- **Loop**: cycles, even a Once clip, to watch its motion over and over.

The state is a per-developer preference in `UserSettings/animation.json`, next to Play Ends on Last Frame, which decides where a Once playback comes to rest in every state. A saved value outside the three states reads as Match the clip's wrap setting.

The ruler over the time canvas is a three-way choice in the view's ⋮ menu, saved in the same file: Frames and Time (two rulers sharing the band, time above, frames below), Frames, or Time. Keys snap to frames while dragging, and Alt held drags freely.

## Non-goals

- No transitions, conditions or parameters. A blend reads one value that
  gameplay sets by id. One value feeding several blends is two calls.
- No 2D blends yet. `pos` is already a `[2]f32` and the union takes another
  variant, so adding `Blend2D_Entry` touches the weight rule and the drawer,
  not the data model.
- No nested blends. The data allows the shape, the graph builder refuses it.
- No replacement for the timeline. A timeline that drives this component sets
  `timeline_driven`, and the component's own playback stands down so the two
  never write the same transforms in one frame.
