---
title: "Animation"
description: "Plays clips and 1D blends of clips on a transform and the objects under it"
weight: 10
tags: ["animation", "components"]
---

Plays animation clips on the object it sits on and the objects under it. It holds the states that can play, the playback state of what is playing, and one [playable graph](../concepts/PlayableGraph.md) that samples and blends the clips.

There is no state machine. The component holds the list of states. What plays next is gameplay code calling the API below.

## Example

A character with a locomotion blend and three single clips, as the `animation_sample` sets it up. Its clips import as Once, so the looping states say Loop:

```
Animation
├── clip                 (empty)
├── play_automatically   false
├── speed                1
└── layers
    └── Layer 0
        ├── Locomotion   Blend1D, wrap Loop
        │   ├── Walk     Clip, at 0.0
        │   └── Run      Clip, at 1.0
        ├── Idle         Clip, wrap Loop
        ├── Jump         Clip, wrap Once
        └── Death        Clip, wrap Once
```

```odin
a := /* the character's Animation */
if id, ok := animation_find(a, "Locomotion"); ok {
	animation_play_entry(a, id, 0.25) // cross-fade over 0.25 s
	animation_blend_set(a, id, speed / max_speed)
}
```

## Properties

| Field | Default | What it does |
|---|---|---|
| `clip` | none | A clip to play without authoring states: a `.anim` or a clip inside a model. `animation_play` plays it. |
| `play_automatically` | on | Plays `clip` on the first tick of the running game. |
| `speed` | 1 | Scales time for every state on this component. Fades ignore it. |
| `layers` | none | The states, a tree per layer, drawn by the States tree in the inspector. |

Each state, an entry of a layer, has:

| Field | What it does |
|---|---|
| `id` | Given when the state is added, never reused. The play API takes it. |
| `parent` | The id of the blend it belongs to, 0 for a state directly on the layer. |
| `pos` | Its place on its parent blend's axis. A 1D blend reads `x`. |
| `name` | What `animation_find` looks up. |
| `wrap` | Default plays as the clip's own wrap setting says. Once or Loop overrides it. |
| `kind` | A Clip state holds a clip. A Blend1D state holds the value it blends at. |

## Behavior

### States

- A Clip state plays one clip.
- A Blend1D state blends the states under it along one axis by its `value`.
- Playing a state always starts it from the beginning.

### Wrap

- A clip's import settings say whether it plays Once or Loop ([Animation clip](../assets/AnimationClip.md)). A state left at Default takes that.
- A state set to Once or Loop overrides the clip, for a clip played both ways.
- A blend reads its own `wrap`. Left at Default it takes its first child's clip setting.
- A clip played by its guid, with no state, takes the clip's setting.
- A Once state that reaches its end holds its last pose. When every state is done, the component stops evaluating and keeps that pose.

### Blend1D

- The children are sorted by `pos.x`. The two around the value share the weight linearly. Past the first or the last child, that child has the whole pose.
- The children share one phase from 0 to 1, and each child samples at `phase * its length`. A 1.07 s walk and a 0.77 s run keep their footfalls together.
- The phase advances at the blended cycle length: `cycle = lerp(walk length, run length, k)`, with the same `k` as the weights. Leaning toward the run speeds the cycle up, so a walk-to-run blend reads as one gait.
- A blend fades in and out as one state: its weight scales every child.
- The value lives on the authored state, and the playing blend reads it every tick. Setting it on a state that is not playing decides where that state starts.
- A blend inside a blend is not built: the inner one is skipped.

### Fades

- `duration` 0 cuts. Above 0 the new state fades in while the others fade out.
- A fade starts from the current weights. Fading to C in the middle of an A to B fade takes A and B down from where they are while C comes up, so an interruption never jumps.
- The weights on a layer keep summing to 1. The first state faded in on an empty layer blends up from the default pose.
- Fades run on real time and ignore `speed`.

### Layers

- A state's layer is the index of its layer in `layers`.
- A higher layer overrides a lower one wherever it animates. The layers stack bottom-up over the default pose.
- `animation_play_clip` and `animation_cross_fade` without a layer use the layer of the state that holds the clip, a clip inside a blend included. A clip no state holds plays on layer 0. A layer argument overrides both.

### The graph it builds

The graph holds only what is playing:

| Authored | In the graph |
|---|---|
| a layer | one input of the layer mixer |
| a Blend1D state | a mixer holding all its children |
| a Clip state | a clip node, built while it plays |
| a state not playing | nothing |

```
layer mixer
└── layer 0 mixer
    └── Locomotion mixer       weight = the state's fade weight
        ├── walk clip node     weight from the 1D rule
        └── run clip node
```

### Driven by a timeline

A timeline's [TrackAnimation](TrackAnimation.md) that targets this component drives it, and the component's own playback stands down while it does, so the two never write the same transforms in one frame.

## In the editor

The inspector draws `layers` as the **States tree**:

- One section per layer. A Clip state shows a clip picker. A Blend1D state shows a value slider across its children's positions, and a row per child with its position on the axis.
- The play button on a state plays it. While the game runs it calls `animation_play_entry`. In edit mode it starts the [Animation window](../windows/AnimationWindow.md)'s preview with that state, and turns into a stop button while that state previews. The editor has one preview, so starting a state preview ends a clip scrub, and picking a clip in the Animation window ends the state preview.
- A previewed blend plays exactly as in the game, so dragging its value moves the character in edit mode.
- Removing a blend removes its children with it.

The [Animation window](../windows/AnimationWindow.md) edits the clips this component references, and the [Playable Graph window](../windows/PlayableGraphWindow.md) shows the graph it builds.

## From code

```odin
animation_play(a)                                // the `clip` field, from the start
animation_play_clip(a, clip, layer = -1)         // a clip by reference, a cut
animation_cross_fade(a, clip, duration = 0.3, layer = -1)
animation_cross_fade_queued(a, clip, duration = 0.3, layer = -1)
animation_stop(a)

animation_find(a, name) -> (id, ok)              // a state by name
animation_play_entry(a, id, duration = 0)        // a state by id: a clip or a blend
animation_blend_set(a, id, value)                // move a blend along its axis
animation_blend_get(a, id) -> f32
animation_entry(a, id) -> ^Animation_Entry
```

Find a state by name once and keep its id: ids do not change when other states are added or removed. The full list is in the [API reference](/docs/reference/packages/animation/animation.md).

## Limits

- No transitions, conditions or parameters. One value that feeds several blends is several `animation_blend_set` calls.
- No 2D blends. `pos` already holds two values, so a 2D blend adds a weight rule and a drawer, not new data.
- No nested blends.
- No root motion, mirroring or additive layers ([Animation clip](../assets/AnimationClip.md), "Settings it does not have").

## See also

- [Playable graph](../concepts/PlayableGraph.md), how the pose is sampled and blended.
- [Animation states](../concepts/States.md), how the states are stored and why: ids, the flat tree, where the wrap setting lives.
- [TimelineAnimator](TimelineAnimator.md), for states that play whole timelines.
