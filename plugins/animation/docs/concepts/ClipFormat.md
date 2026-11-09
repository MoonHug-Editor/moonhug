---
title: "Clip format"
description: "What a clip stores: channels of typed keys, rotation rows, lane masks, split lanes and per-key interpolation"
weight: 20
tags: ["animation", "concepts", "assets"]
---

A `.anim` file, a baked clip artifact and a clip inside a model share one JSON shape: a `length` in seconds and a list of `channels`. A channel is one row of the Animation window's sheet. The code is `clip.odin`, `clip_trs.odin` and `clip_property.odin`.

```json
{
  "target": "Body/Arm", "path": 0, "component": "", "field": "", "step": false,
  "times": [0.0, 0.5, 1.0],
  "values": [[0, 0, 0, 0], [0, 1, 0, 0], [0, 0, 0, 0]],
  "modes": [1, 3, 0],
  "tangents": [[[0, 0, 0, 0], [0, 0, 0, 0]], [[0, 2, 0, 0], [0, -1, 0, 0]]]
}
```

| Key | What it holds |
|---|---|
| `target` | The animated object's name path from the Animation's object. Empty is the object itself. |
| `path` | For a transform row: `0` Position, `1` Rotation, `2` Scale, `3` Euler. A property row ignores it. |
| `component`, `field` | For a property row: the component's type guid and a dotted path to the field. |
| `times`, `values` | The keys, parallel arrays. |
| `modes`, `tangents` | Optional per-key interpolation (below). |
| `step` | Every key holds, for a row without `modes`. |
| `lanes` | Optional lane mask (below). |

## Value kinds

A row animates one field, so all its keys share one kind:

| Kind | Fields | Between keys | In a blend |
|---|---|---|---|
| floats, `[x, y, z, w]` | `f32`, `[2..4]f32`, colours, position, scale, rotation | interpolated | weighted, rotations as quaternions |
| ints | ints, enums, bools | held | the highest weight wins |
| references | `PPtr` and `Asset_GUID` fields | held | the highest weight wins |
| strings | `string` fields | held | the highest weight wins |

- The kind is read from the element type of `values`: an array is floats, a number ints, a string strings, an object (`{"local_id": 7, "guid": "..."}`) a reference. An empty array is floats.
- A float row is an array of 4-lane arrays.
- Ints are i64, so an id or a bitmask keys exactly. A bare guid reads as a reference with local id 0.
- The live field's type decides how a row applies. A float row on an int or bool field writes its first lane rounded, an int row on a float field writes the int. A row of another kind than the field's writes nothing, like a row whose field does not resolve.
- On a string field a write frees the field's old string and stores a copy. An equal value writes nothing.

## Rotation rows

- A Rotation row (`"path": 1`) holds unit quaternions `[x, y, z, w]` and slerps between keys. Model clips and baked glTF clips keep Rotation rows.
- An Euler row (`"path": 3`) is the same rotation as angles in degrees, `[x, y, z, 0]` in the inspector's order. Each lane interpolates on its own by the key modes, with no slerp, and the row can mask lanes and split like a Position row.
- The keys hold the angles as typed, so a two-key row from 0 to 720 spins twice, which quaternion keys cannot say.
- A clip's transform rows combine per object by one rule, used by playback, the graph and the inspector's preview: split rows each set their own lanes, the rotation starts from the clip's Rotation row when it has one, else from a base, then the Euler rows' enabled lanes replace their angles. A lane no row sets keeps the base.
- The base is the object's own rotation when a clip is applied directly and in the inspector, and the rotation at bind time in the graph, where blending happens before anything is written. Above the clip the rotation blends as a quaternion.

## Properties

- A property is what a channel animates on a target: Position, Rotation, Scale or Euler of a transform, or one field of one component. Its channels are its lanes.
- Two channels of one property never animate the same lane. A file that breaks this does not load, and the Animation window refuses an edit that would break it.

## Lanes

A float row of 2, 3 or 4 lanes can animate some of them. Animating `position.y` alone leaves x and z to the object.

```json
{ "target": "", "path": 0, "times": [0.0, 1.0], "values": [[0, 0, 0, 0], [0, 2, 0, 0]], "lanes": [false, true, false, true] }
```

- `lanes` holds one bool per lane, x to w, true for a lane the row animates. A lane past the end of the array animates. The key is absent when every lane animates.
- The width comes from the field: Position, Scale and Euler are 3 lanes, a property row as many as its field. A lane past the width never counts as disabled.
- A Rotation row and a single-value row ignore the mask.
- A write of the row reads the field, replaces the enabled lanes and writes it back. The other lanes keep what the field holds.
- In a blend a disabled lane contributes nothing. A lane's value blends only the clips whose row enables it, and a lane no bound row animates keeps the field's value at that moment, so an edit of that lane holds. Two clips at 0.5, one animating x and the other y, give x the first clip's full value and y the second's.
- A mask with every lane disabled is valid, but the Animation window removes the row with its last lane instead of writing one.

## Split lanes

A vector row is joined or split.

- A joined row is one channel: every lane shares the key times. Joined is the default and the cheaper form: one time per key, one curve evaluation per sample.
- A split row is several channels with the same target and property, one per lane, each masked to its lane and each with its own key times. A lane can have keys on frames the other lanes have none.
- The format has no split flag: the shared target and property group the channels, and each channel's `lanes` names its lane.
- Splitting copies the row once per enabled lane, keys, modes and tangents included, and masks each copy to its lane.
- Joining puts the union of the channels' key times into the first channel. Times within half a frame of an earlier one fold into it. Each lane is sampled from its own channel at every time. A joined key keeps the lanes' mode where they agree, Linear or Step, and is Free with each lane's slopes where they differ, which rebuilds a Linear, Smooth or Free lane exactly.
- A Smooth lane comes back as Free keys with frozen tangents: the same curve, which later edits do not smooth again.
- The one join that changes the animation is a lane that holds where another interpolates: the hold becomes a ramp.
- A lane no channel animates is disabled in the joined row.

## Interpolation

A float row carries per-key interpolation in two optional arrays parallel to `times`:

- `modes`: one per key, `0` Linear, `1` Smooth, `2` Step, `3` Free. A key past the end of `modes` is Linear. A row with no `modes` and `step` set holds on every key.
- `tangents`: in and out slopes per lane, in value units per second, read by Free keys only. A Free key past the end of `tangents` has flat tangents.

Between key A and key B:

- A is Step: A's value holds until B.
- A and B are Linear, or B is Step: a straight line.
- Otherwise a cubic Hermite curve with A's out slope and B's in slope. A Linear key uses the slope toward that neighbour, a Smooth key the slope between its two neighbours, flat at the first and last key, computed when sampled. A Free key uses its tangents.

Rotation rows slerp and ignore tangents, and Step still holds. Int, reference and string rows always hold.

- A key added to a row with `modes` takes the mode of the key before it. A Free key added gets the curve's slope at its time on both sides, so the curve keeps its shape.
- Deleting a key removes its mode and tangents.
- The trim import setting keeps curves: kept keys become Free with the slopes they had, and the keys at the cuts are Free with the slope there.

glTF samplers bake as follows:

- LINEAR: Linear keys, no `modes`.
- STEP: `step` set.
- CUBICSPLINE: every key Free, with the sampler's in and out tangents. glTF tangents are already in value units per second, so the clip plays the exact curve.

## See also

- [Animation clip](../assets/AnimationClip.md), the asset and its import settings.
- [Animation window](../windows/AnimationWindow.md), which edits all of this.
