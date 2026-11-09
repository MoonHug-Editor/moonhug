---
title: "Playable graph"
description: "How poses are sampled, blended and written: a graph of clip, mixer and script nodes evaluated at an explicit time"
weight: 10
tags: ["animation", "concepts"]
---

A playable graph samples clips, blends them by weight and writes the result to the objects it is bound to. Clip nodes sample at their own time, mixers blend their inputs, and each output writes one pose. Evaluation reads the graph at an explicit time and changes nothing until an output writes.

Everything that animates in this plugin plays through one: the [Animation](../components/Animation.md) component, the [TimelineAnimator](../components/TimelineAnimator.md), a timeline's animation tracks and the editor's preview. The code is `playable_graph.odin`.

## The graph evaluates, drivers decide

- **Evaluation keeps no memory.** The same graph at the same time gives the same pose, in any call order. A node computes from its own time and its inputs, and never changes the graph's structure, another node or anything that outlasts the evaluation.
- **Drivers change the graph between evaluations.** A cross-fade adds a clip node, a finished fade removes one. Every frame is change, then evaluate: drivers restructure and reweight first, then evaluation walks the result read-only.
- **Anything that remembers lives in a driver.** Times, fades, the queue and the authored states belong to the component that drives the graph, never to the graph.

This is what makes scrubbing exact, previews possible in edit mode and the evaluator testable without a window.

```
gameplay code         calls the drivers' API
  │
drivers               own time and decisions, write node times and weights
  ├─ Animation component
  ├─ TimelineAnimator
  ├─ a director's animation tracks
  └─ the editor preview
──────────────────────────────────────────────────────
graph                 nodes, time and weight propagation, outputs
```

## Nodes

| Kind | What it does |
|---|---|
| Clip | Samples a clip at the node's time. A leaf. |
| Mixer | Blends its inputs by weight. Weights summing below 1 blend the rest from the default pose, above 1 they are normalized. |
| Layer mixer | Stacks its inputs bottom-up over the default pose, each over the running result by its weight, so a higher layer overrides lower ones wherever it animates. |
| Script | Calls back with its time and weight. A timeline marker is a script node of zero duration. A leaf. |

- A node has a local time and a speed. Drivers set the times. Evaluation reads `time * speed`.
- Each input carries a weight from 0 to 1, written by drivers. A weight scales the whole subtree under it, so fading a blend fades every clip in it.
- A handle is any node, and any subtree is an input to another node. The graph is an arena of nodes, and graphs do not nest: something reusable is built into the host's arena.

## Outputs

- A graph holds a list of outputs, each a subtree root plus the binding it writes through.
- `playable_graph_tick` evaluates and writes every output, then calls the script callbacks collected across all of them, so a callback never sees a frame where some objects are posed and others are not.
- Several outputs is the normal case: one driver posing several objects. A binding covers only the clips reachable from its own root, so another output's channels neither size its pose nor resolve against the wrong object.
- `playable_graph_evaluate(g, root, binding)` is the pure step underneath: one subtree, one binding, no writes. `Playable_Output` wraps a graph with exactly one output.

## The pose

Sampling, blending and writing are separate steps with a pose in between:

- Clip nodes sample into poses, mixers blend poses, and the output writes the final pose to the objects once. Blending needs every candidate value before anything is written.
- A pose holds, per animated object, the values its channels set: position, rotation, scale and component fields, each optional.
- Each vector lane blends on its own. A lane's value blends only the clips whose row animates that lane ([Clip format](ClipFormat.md), "Lanes").
- Rotations blend as a weighted sum of quaternions, each flipped into the same hemisphere as the sum first, then normalized. Between keys of one Rotation row a clip slerps.

### The default pose

**A blend that does not reach full weight, or does not cover a channel, resolves against the default pose, the values taken when the output binds, never against the live object.** Blending against live values feeds back from frame to frame and drifts.

- The output keeps the default value of every channel it binds.
- One clip at weight 0.3 blends 0.3 of the clip against 0.7 of the default pose.
- Clip A animating only `child` position, mixed half and half with clip B animating only `child` rotation: the position blends A against the default, the rotation blends B against the default.
- At runtime the defaults are taken once, when the output binds. The editor preview takes them again every frame (below).

### Binding

- An output resolves each channel's object by its name path from the bound root, once, and caches it.
- A channel whose path does not resolve writes nothing. The Animation window shows its row in the warning colour.

### Component fields

A channel with a `component` animates a field of a component instead of a transform. It names the field by three parts: the object's path, the component's type and a dotted path to the field (`emission.rate.value_min`).

- The live field's type at bind time decides how the channel applies: how many lanes, whether it interpolates, and how the value converts.
- Animatable kinds: `f32`, `[2..4]f32`, bools, ints, enums, `PPtr` and `Asset_GUID`, and strings. Other references and whole structs are not animatable.
- Float kinds blend like transform channels, defaults included. Discrete kinds, bools, ints, enums, references and strings, cannot blend: the strongest contributor wins at every blend, the highest weight in a mixer and the majority against the default when written.
- The binding caches where the field is, its type and offset, and fetches the component again on every write, since pools move when they grow.
- A field a component reads only when it starts does not visibly respond to animation.

## Script nodes

```odin
Playable_Script :: struct {
	user_data: rawptr,
	on_play:   proc(data: rawptr),
	on_pause:  proc(data: rawptr),
	process:   proc(data: rawptr, time: f32, weight: f32),
}
```

- The weight passes through, and the callback decides what it means.
- **Callbacks run after evaluation, never during it.** Evaluation collects `(node, time, weight)` and the calls happen once every output has written. A callback may change the world and still never sees a half-evaluated frame.

## Who owns a graph

Several things own a graph: an Animation component, a TimelineAnimator, a director's animation tracks and the Animation window's preview. A viewer names none of them. Owners register a provider with `playable_graph_register_provider(order, proc)`, and a viewer asks `playable_graph_for_object(owner)`. The lowest order wins, so the most concrete driver is reported:

| Order | Source |
|---|---|
| 10 | a TimelineAnimator's runtime graph |
| 20 | an Animation component's runtime graph |
| 30 | a director's animation tracks, or the animator that adopted them |
| 40 | the Animation window's preview |
| 50 | the shape an Animation component builds when it plays, from its states |

The more concrete driver is the one posing, so it is the one worth showing. A caller searching up a hierarchy compares the order across objects instead of stopping at the first ancestor that answers: an object can carry an empty Animation while a TimelineAnimator further up poses it.

## Previews in the editor

Nothing ticks in edit mode, so a preview runs the graph around the render, every frame:

1. Take the defaults again from the live objects.
2. Evaluate at the preview's time and write the pose for the scene and game render.
3. Write the defaults back.

The world holds its own values whenever saves, undo or the inspector run, so a preview cannot leak into files, and there is nothing to revert when it ends.

## Scrubbing

- Animation scrubs exactly: evaluation keeps no memory, so any time is valid.
- Markers and other crossings fire only during playback. A timeline scrub jumps to a time without firing what it passes, and tracks that keep state reset and replay to that time instead ([Sequencer](/plugins/sequencer/docs/Sequencer.md)).
- Audio plays only during playback, never while scrubbing.

## Why it is built this way

The model is a playables graph of the kind several engines use. The API is this codebase's own: pooled structs addressed by handle, a union for the closed set of node kinds, and parallel arrays.

### One evaluator for every consumer

- **Scrubbing in edit mode** is "evaluate this graph at time t while stopped", the same code path as play, with no special case.
- **Blending** needs every candidate value before anything is written. Writing each sampled channel straight into the transform cannot blend.
- **Timelines and animators** are drivers of a graph, not second animation runtimes.

### No controller layer

There is no state-machine layer between gameplay and the component. Triggers and parameters are the price of making a state machine a data asset: data cannot call functions, so a controller needs a string-keyed mailbox for code to poke. With animation logic in gameplay code, the interface is calling a proc.

What does not go away with the controller is playback bookkeeping: cross-fades, interruption and the queue. That lives in the Animation component, so gameplay files do not each reimplement it.

### Outputs are pulled per kind

Evaluation pulls per output kind rather than returning a pose. If the evaluator's result were a pose, script and audio would be bolted on later as side channels.

- Pose outputs exist. Script callbacks leave evaluation through a collection that runs after every output has written.
- The audio track does not play through an output. It plays through `Track_Desc.tick`, driving the AudioSource its own `source` names.

### The pose buffer

Sampling into a pose and writing once costs a little memory and makes blending independent of order. A runtime that blends each track straight into the skeleton in track order, as Spine does, needs mixing machinery to patch the ordering artifacts that come with it.

### Graphs do not nest

`Playable_Graph` is an arena: node storage, a free list and outputs. The graph itself lives in the nodes' inputs, so any handle is a subtree root and any subtree is an input to another node. A handle is an offset into one arena, not an identity, so two arenas cannot name each other's nodes, and an output terminates in a write. Anything reusable is built into the host arena, the way a prefab instantiates into a scene.

### A small node set

Four node kinds in a union cover what the plugin plays. A fully general playables API, with per-node prepare and process lifecycles, runtime sub-graph surgery, video playables and DSP graphs, is what makes such APIs clumsy. A handful of variants that covers years of features is success, not under-engineering.

## See also

- [Clip format](ClipFormat.md), what a clip node samples.
- [Playback levels](PlaybackLevels.md), who owns the graph when an Animation, a track and an animator all pose one object.
- [Roadmap](../Roadmap.md), for audio outputs, graph assets and additive blending.
