---
title: "Animation window"
description: "The clip editor: a dope sheet and a curve view over one clip, with recording, Add Property and per-key editing"
weight: 10
tags: ["animation", "editor", "windows"]
---

Edits a clip of the selected object's [Animation](../components/Animation.md) component: a dope sheet and a curve view over the clip's channels, with recording, Add Property and per-key editing. It previews the clip on the object while you scrub or play.

## What it shows

- The Animation component of the selected object or its nearest ancestor, or of the object kept while an asset is selected. Selecting a bone keeps the window on the animated root. A locked Inspector does not change it.
- The clip list holds every clip the component references: its `clip` field and every Clip state on every layer, blend children included. A clip is listed because something references it, not because it exists in the project.
- The padlock in the tab bar is the shared window lock ([Windows](/docs/core/Windows.md), "Window locks"): every copy of the window shares one lock, as they share one preview. Locked, the window stays on its object when you select another, whether or not the object has an Animation component yet. An object locked before its component is added shows the editor once it has one.
- A locked object that is deleted, or whose scene closes, leaves the window saying it is missing. The lock stays, and the window shows the object again when it is back. The lock survives a restart.

## Editing and saving

- Edits go to the clip's document. Save writes it to the `.anim` file. Unsaved edits revert.
- Every edit, undo and redo refreshes the sheet at once and reaches the playing clip the same frame, so the preview and recording from the inspector always pose from the current keys.
- The preview evaluates the component's whole graph with the shown clip at weight 1 and everything else at 0, so the preview is the graph the component plays, and the [Playable Graph window](PlayableGraphWindow.md) shows the real shape.

## The sheet

The sheet groups its rows by the object they animate. Each animated object has an Object row, in the order its first channel appears in the clip, labelled with the object's name. Its property rows follow it, one step in, labelled with the component and field, or Position, Rotation, Scale or Euler.

- Object rows sit at the column's edge whatever their depth. The tooltip shows the full path. A target that does not resolve under the animated object shows its name in the warning colour.
- A click on an Object row's name pings the object in the hierarchy, a double-click selects it. Neither changes the keys.
- The arrow on an Object row collapses it, hiding its property rows. The collapse belongs to the window copy and is not saved. Adding a property under a collapsed object expands it.
- In the dope sheet an Object row shows an outlined summary key at every time where any of its property rows has a key, hidden rows included. Keys within half a frame after the first key of a run count as one.
- Clicking a summary key selects every key it stands for, the first becoming the primary key. Dragging it moves them together. A modifier click adds them to the selection or removes them. A box selection over an Object row selects its channels' keys in the band.
- Pressing an Object row's name selects no key. Double-click on a key, Remove Property and Add Key act on property rows only, and the curve view plots only the selected property row.
- The selection survives edits. A key whose row or index is gone drops out.

### Retargeting

Edit Path in an Object row's context menu opens a field with the full target path.

- Enter, or Escape as in every text field, sets the target of every channel of that object to the typed path, spaces trimmed, as one undo step. A click elsewhere cancels.
- A path that already animates a lane one of the moved rows animates is refused, so no lane gets two rows.
- An unresolved path shows in the warning colour and can be edited again. The collapse follows the row to its new path.
- A model clip has no field.

### Lane rows

A vector row has an arrow before its label: Position, Scale, Euler, or a field of 2 to 4 float lanes, never Rotation. It is collapsed by default. Expanded, a Lane row per enabled lane follows it, labelled x, y, z or w. A disabled lane has no row. The expansion belongs to the window copy and is not saved.

- A Lane row shows the keys of the channel that animates its lane, in the lane's curve colour.
- A click, drag, modifier click, double-click and box selection on a Lane row act as on its property row. A key caught by both in one box is selected once. A right-click on a key opens the key menu.
- The property row's context menu has a Lanes group above Remove Property: one checked item per lane, checked when the lane is enabled. A click toggles the lane, one undo step. Unchecking the last enabled lane removes the row in that same step, without asking, as Remove Property does.
- The value fields keep every lane in its column: an enabled lane shows its field, a disabled lane a dimmed dash. The selected key's footer does the same.
- The curve view plots, hit-tests and draws tangent handles for the enabled lanes only.

### Split lanes

A vector row is joined, one channel whose lanes share key times, or split, one channel per lane with its own key times ([Clip format](../concepts/ClipFormat.md), "Split lanes").

- Split Lane Keys and Join Lane Keys are in the property row's context menu, each shown only when it applies. Split needs a joined vector row with two or more enabled lanes. Join needs a split float row. A model clip shows neither.
- A split row is still one property row. It shows summary keys like an Object row, and each of its Lane rows shows and edits its own channel's keys.
- The Lanes menu on a split row adds a channel for an enabled lane or removes the lane's channel.
- Join asks first when a lane holds where another interpolates, the one join that changes the animation.
- Split Lane Keys, Join Lane Keys, Convert to Euler and the Lanes menu keep the row selected.

### Rotation rows

- Recording and Add Property create Euler rows for a transform's rotation: angles in degrees, one lane per axis.
- Convert to Euler in a Rotation row's context menu turns its quaternion keys into an Euler row with unwound angles, so an extracted clip can be edited per axis. Keys that interpolated become Linear, Step keys stay Step. The motion between keys changes from one arc to per-axis interpolation where keys turn on more than one axis.

## Values in the rows

Each property row shows its value at the playhead after its name: one field per lane for a vector, a checkbox for a bool, an int field for an int or enum.

- A string row shows a text field. Enter, or Escape, keys the typed text at the playhead. A click elsewhere drops it.
- A reference row shows the asset picker the inspector uses, filtered by the field's `ext:` and `ref:` tags. A pick or a drop keys the new reference at the playhead.
- A Rotation row shows three euler angles in degrees, and an edit keys the quaternion built from them.
- Editing a field keys the row at the playhead: a key already there takes the value, else a key is added. One drag or typed value is one undo step.
- In the selected key's footer the same fields set that key's value instead.
- The dope sheet draws every kind of row's keys as diamonds. The curve view plots float rows only.
- A model clip shows the values read-only.

## Record

While Record is armed, an edit of an animatable field keys the clip at the playhead instead of changing the object.

- The key lands on the playhead's frame, the playhead snapped to the frame grid. A key within half a frame of it takes the value instead of a second key being added. The inspector's keyed mark and Delete Key use the same half-frame rule.
- Any edit that records undo counts: an inspector row, a gizmo drag, a multi-object edit.
- The field belongs to the animated object or an object under it: a component field of an animatable type, the kinds Add Property lists, or a transform's position, rotation or scale.
- A missing row is created the way Add Property creates one. Its key at the clip start holds the value from before the edit, and the key at the playhead holds the edited value.
- The object keeps its own value. The preview poses it from the clip, so the key shows at the playhead, and leaving the preview shows the object's own values again. The scene is not changed.
- The clip edit is the only undo step: one Ctrl+Z removes the key, and the row with it when the edit created the row.
- Each object of a multi-object edit is keyed or left alone on its own.
- Recording into a joined row keys the whole vector and enables every lane. A lane that was disabled is filled on the row's other keys with the value the object showed. Recording into a split row keys only the lanes the edit changed.

An edit that cannot be keyed stays an ordinary scene edit with its own undo step:

- The field type is not animatable: an array, a plain struct, a `Ref`, `Ref_Local` or `Owned` reference. The window shows a note under the toolbar naming the field and its type, until the next note or until Record is disarmed.
- The object is neither the animated object nor under it.
- The clip is a model clip, which is read-only. Record is off for it.

## Preview values in the inspector

While the window previews a clip, the inspector shows the clip's values for the fields the clip animates, on the animated object or under it.

- **Preview on, Record off:** the field shows the clip's value in green, with a bar in the inspector's gutter, and takes no edits. An edit there would change the object's own value, which the pose hides.
- **A lane the clip does not animate** shows the object's own value in the normal colours inside the green row. With Record off an edit of it changes the object as an ordinary edit, and the preview shows it at once.
- **Record armed:** the field shows the clip's value in red. A released drag or a typed value keys the edited value at the playhead, one undo step on the clip. The object's own value, the scene's undo, the prefab overrides and the other selected objects are untouched.
- A field without a row, an object outside the animated object, a state preview from the States tree, or the preview off: the field shows the object's own value as usual.
- Rotation shows euler angles in degrees.
- A string field is never driven: it shows the object's own value, and recording and Add Key still key it.
- A row drawn by a decorator, a colour swatch or a range slider, shows and keys the clip's value the same way.
- While the window shows a clip, a field the clip has a row for that the preview does not drive shows a dimmed green bar in the gutter.
- While recording, the field's context menu has Add Key, which keys the value the field shows at the playhead, creating the row when missing, in one undo step. When the playhead's frame already has a key, the item is Delete Key instead, and a row left without keys goes with it. On a driven field the menu has the key item alone, since Reset, Paste, Copy, Revert and Apply act on the object's own value, which the field hides.
- A driven field with a key on the playhead's frame shows a filled diamond in the gutter.
- In the gutter the prefab override bar comes first and the driven bar after it, so marks never cover each other. The key diamond sits at the gutter's right side. A prefab override stays visible while the preview drives the field.

## Key modes and tangents

The key context menu, a right-click on a key in the dope sheet or the curve view, starts with a Mode group above Delete:

- Linear, Smooth, Step and Free, each checked when every selected key has that mode. A pick sets it on every selected key, one undo step.
- A row without modes gets them on the first pick: every key takes the mode it already plays with, and then the selected keys change.
- A key turning Free keeps the tangents it plays with, so the curve does not move.
- A Rotation row offers Linear and Step only, since rotations ignore tangents. A key of an int, reference or string row always holds: the group shows Step, disabled.

Below the modes, the tangent presets turn every selected key into a Free key:

- **Flat**: both tangents zero, an ease in and out.
- **Ease In**: the in tangent zero, the out tangent the straight slope to the next key.
- **Ease Out**: the out tangent zero, the in tangent the straight slope from the previous key.
- **Auto**: the tangents a Smooth key has, stored on the key.

The selected key's footer shows the primary key's mode as a combo next to its time, with the same choices, applied to every selected key.

In the curve view every Free key of the plotted row shows its tangent handles: a line along each tangent to a small circle 40 px away, in the lane's colour.

- Dragging a handle sets that side's tangent of that lane, one undo step per drag.
- Holding Shift while dragging sets both tangents to the same slope: a smooth joint.
- A press near both a handle and a key takes the handle.
- The window's value range takes in the handle points, so a steep handle stays visible.

## Model clips

A clip inside a model opens read-only: the window shows its keys and curves, previews, plays and scrubs it, and selects keys to show their values, but adds, moves and deletes nothing, and Record is off. The toolbar shows Read-Only and the clip list marks such clips. Assets, Extract Assets makes an editable `.anim`.

A missing or unreadable `.anim` edits nothing either, but is not marked Read-Only: the sheet says the clip is missing.

## Playback

- By default playback follows the clip's `wrap`: a Once clip plays through and stops, a Loop clip cycles. The window reads the imported clip for that, since the setting lives in the `.meta`.
- The playback toggle after the transport buttons overrides it. A click steps through: **Match the clip's wrap setting**, **Play once** to look at a loop's end pose, and **Loop** to watch a one-shot over and over.
- Play Ends on Last Frame, in the window's menu, decides where a Once playback comes to rest: on the last frame or back at the first.
- Keys snap to frames while dragging. Hold Alt to drag freely.
- The ruler over the time canvas is a choice in the window's menu: Frames and Time, two rulers sharing the band, Frames, or Time.

## Preferences

Saved per developer in `UserSettings/animation.json`:

| Preference | Default | Set from |
|---|---|---|
| Playback | Match the clip's wrap setting | the toolbar's playback toggle |
| Play Ends on Last Frame | off | the window's menu |
| Ruler | Frames and Time | the window's menu |

A saved value the window does not know reads as the default.

## Internals

- The sheet is built from the clip once per change, not every frame: the rows, each property's channels and what each channel resolves to. It rebuilds when the document's edit count changes, when the clip changes, or when an Object row collapses or a vector row expands (`editor/sheet_cache.odin`).
- A sheet replaced during a frame stays readable until the next frame, so code that read the rows before a menu edited the clip never reads freed memory.
- The selection is kept as stable keys, each channel's key plus a key index, and restored after a rebuild.
- Recording goes two ways (`editor/record.odin`): an inspector edit of a driven field reaches the window through `inspector.driven_commit` and the live field is never written, and every other edit through the undo package's commit listener, which keys the clip and puts the object's old value back ([Undo](/docs/core/Undo.md), "Driven values" and "Commit listener").

## See also

- [Animation clip](../assets/AnimationClip.md), the asset this window edits.
- [Clip format](../concepts/ClipFormat.md), what a key and a lane store.
