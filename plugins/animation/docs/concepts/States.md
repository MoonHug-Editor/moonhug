---
title: "Animation states"
description: "How the Animation component stores its states, where the wrap setting and the blend value live, how the tree differs from the graph, and why"
weight: 30
tags: ["animation", "concepts"]
---

How the [Animation](../components/Animation.md) component stores and plays its states, and why it is built this way. The code is `component_Animation.odin`.

## States have ids, not indices

An id is given when a state is added and never reused. Deleting a sibling shifts every index after it and would silently repoint a play call at a different state. The TimelineAnimator follows the same rule with its `State_Id`.

## A child holds its position

`pos` lives on the child, not as a threshold list on the parent blend. A child then works under any blend kind without knowing which it is, and switching a blend from one axis to two keeps every child's x.

## The tree is stored flat

`entries` is one array per layer, and `parent` is an id. Blends do not hold their own children.

- A recursive union serializes and undoes badly. The JSON nests without bound, and an undo edit lands inside a union inside an array inside a union, where a type the pointer registry misses makes it silently do nothing.
- One array is one undo edit and one JSON array, and it still draws as a tree.
- The inspector draws `layers` with its own States tree. The field is `inspect:"-"`, so the reflected field loop skips it: a tree of arrays of unions is the shape those rows draw worst.

## The state kind union

- `Animation_Entry_Kind` is `#no_nil` with `Animation_Entry_Clip` first. A nil union marshals to bare `null`, which the generic union reader cannot read back. The whole component would then be kept verbatim as an unknown one, reading "Missing Component" with every field gone. An empty clip state is the natural zero, and it is what an author gets when they add a state before picking its clip.
- Both variants carry a `@(typ_guid)`, which is what gets the union serialized: `union_gen` finds every union whose variants all carry the tag and registers the guid-tagged marshaler in that package's `unions_generated.odin`. Without it the default marshaler writes the active variant's fields with no tag, which reads back as the zero variant: a blend saved and loaded would come back a clip.
- The playing state, `Animation_State_Runtime`, is a union too, so neither kind holds the other's fields. It is never serialized, so it needs no guid.

## Where the wrap setting lives

The clip is the default and the state overrides it.

- A walk cycle is cyclic and a death is one-shot, so the motion usually knows. The clip's import setting is the answer most of the time, and a state left at Default takes it. The state overrides it for a clip played both ways.
- The override sits on the state, not on the component. A component holds Idle and Death at once, so one wrap for both can never be right.
- A blend reads its own setting rather than a child's: its children share one phase, so no single child's wrap is the blend's.

Other systems answer this at different levels. A classic clip player overrides at three: clip, component and playing state. A state-machine controller has no wrap on a state at all: looping is a clip import setting, because the motion owns it. A timeline adds a separate extrapolation setting for what a track does outside a clip. This component sits between the first two: the clip owns the default, one level above overrides it, and there is no component-wide level.

## The blend value lives on the authored state

The runtime reads a blend's value from the authored state every tick instead of copying it into the playing state. One field is one source of truth: an inspector slider and a gameplay call are the same edit, and setting it on a state that is not playing decides where it starts.

## The tree is not a view of the graph

The authored tree holds every state. The graph holds only what plays, and a blend is one state with one weight. That asymmetry is why the inspector's play buttons call the component's API instead of touching graph nodes.

- Every reader builds nodes through one function, `animation_entry_build`: the component for the states that play, and `animation_graph_build_authored` for the whole tree at once, which the Playable Graph window draws and the editor preview evaluates. One builder, so the window cannot show a shape the component would not play.
- `animation_graph_build_authored` reports an `Animation_Authored_Leaf` per clip: the `Animation_Blend_Child` the 1D rule needs, the top-level state it belongs to, and the chain it hangs from. Lighting a clip inside a blend means weighting that whole chain, the clip under the blend's mixer and that mixer under the layer, since a blend left at 0 reaches the pose with nothing.
- A blend inside a blend is skipped rather than flattened, so the graph never silently means something other than the tree.

## Testing

`animation_demo.scene` is generated JSON with hand-written union tags, the kind of asset that breaks silently. `test_animation_demo_scene_loads` loads it, checks that the tree survived, and plays the blend through to a posed joint.

## See also

- [Animation](../components/Animation.md), the component's properties and API.
- [Playable graph](PlayableGraph.md), what the states build into.
- [Roadmap](../Roadmap.md), for 2D blends.
