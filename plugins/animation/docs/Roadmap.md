---
title: "Roadmap"
description: "What comes next for the animation plugin, its open questions and known concerns, and what is not planned"
weight: 900
tags: ["animation", "roadmap"]
---

What the animation plugin does not do yet, what is undecided, and what it will not do. How it works, and why, is on its concept pages: [Playable graph](concepts/PlayableGraph.md), [Clip format](concepts/ClipFormat.md), [Animation states](concepts/States.md) and [Playback levels](concepts/PlaybackLevels.md).

## Next

In the order need dictates:

1. Script and audio as real output kinds of the [playable graph](concepts/PlayableGraph.md), pulled like poses, so weight reaches them the same way. An audio output is designed, not built: frame-quantized play, stop and volume commands for the audio runtime.
2. A weight policy per track kind that is not a pose, once real content shows the rules (below, "Open questions").
3. A graph asset, with the node canvas grown into its editor (below).
4. Published properties for timelines, decided together with the graph asset's exposed parameters (below).
5. 2D blends. `pos` already holds two values and the state kind union takes another variant, so a Blend2D state adds a weight rule and a drawer, not new data.
6. Avatar masks, for a layer restricted to part of the hierarchy, and layer masks for a full-body timeline used in part. Each waits until content needs it.
7. A guard against two TimelineAnimators keying one Animation component.
8. A state-machine asset, only if authoring without code is ever needed. It would be an optional client of the Animation component's API, not a layer inside the graph.

## Graph assets

Graphs are built in code first, and the code API stays first class: a two-clip cross-fade is less friction in code than in any asset. An authored graph asset comes once the runtime settles, as a reusable rig, a locomotion blend tree shared by many characters for instance. The [Playable Graph window](windows/PlayableGraphWindow.md) grown into an editor is its authoring UI, and the asset loader is one more client of the graph construction API.

The asset is a template, which needs three designs code-built graphs never did:

- **Exposed parameters**: named inputs, `run_weight` for instance, that drivers write by name or handle instead of poking node indices.
- **Instancing**: the asset is a shared immutable template, and each component owns a runtime instance with its own times and weights, as the material cache shares a material.
- **Clip slots**: per-instance clip overrides, "this character's walk", or every character needs its own asset.

**The asset holds structure only**: nodes, connections and default weights and speeds. Every change comes from outside writes. No conditions, no transitions and no "activates when a parameter is above x" in the data, or a state machine assembles itself by accident.

Script nodes hold proc pointers, which do not serialize. An authored script node names a registered proc instead, as the ext component registry does.

## Additive blending

When additive blending is needed, the shape to copy is a per-input blend mode on the mixer, not a new node kind. Spine's apply takes a per-call blend mode (setup, first, replace, add): blending against the setup pose is its default, which agrees with the default pose rule here, and additive is a mode on an existing connection.

## Published properties

An idea, not adopted. Recorded so the choice is made once, not drifted into.

A shader graph holds many nodes, and only a few become properties in the material inspector: the author picks which values are public and names them. The same shape fits timelines: the timeline prefab is the graph, a TimelineAnimator state is the material, and the state inspector is the material inspector. A track's target becomes one property type among others: a clip's duration, a tween's endpoint and an audio volume are equally promotable.

```odin
// Declared on the timeline's director: its published interface.
Timeline_Property :: struct {
	name:          string,      // shown in the state inspector
	target:        engine.PPtr, // which node inside the prefab
	property_path: string,      // which field on it
}
```

A property is internal by not being listed. A listed property with a value inside the prefab is public with a default, so the timeline plays on its own and a state overrides only what it wants different. `Override{target, property_path, value}` and `nested_scene_apply_overrides` already are a state's value list. The idea adds the filter.

Two things to weigh first:

- Overrides land when the instance is created, so a state sets its timeline's published values then and cannot change them later. That covers targets, durations and volumes. It is not a runtime parameter system.
- It is a bigger authoring surface: a property editor on the director, a value editor on the state, and a type story for every promotable field.

It is the timeline-level twin of the graph asset's exposed parameters, and the two are decided together.

## Open questions

- **What fractional weight means for a track that is not a pose.** Every track kind gets the weight through its script node. The policy is open: audio scales volume, activation is a bool, so a threshold or last writer wins, and firing a marker at weight 0.02 is wrong. This wants two real timelines cross-faded before the rules are fixed.
- **Two animators on one component.** Two TimelineAnimators keying the same Animation clobber each other like overlapping pose outputs, but across components, where the build check cannot see it.
- **The TimelineAnimator's API is smaller than the Animation component's.** It has no queued cross-fade. A small API is the goal, and the older component's may be the overgrown one. Decided after both have been used.

## Known concerns

Known risks of the [TimelineAnimator](components/TimelineAnimator.md), recorded so they are not argued twice.

### A finished Once state stops posing

A timeline clip covers `[start, start + duration)`, so at its end its weight is 0. A Once state stops at the timeline's end, sets `done` and contributes nothing: the objects return toward their default pose instead of holding the last one. The Animation component holds its final pose in the same case, since a done clip node samples at its length and the sampler clamps to the last key. A timeline adds a clip weight underneath that the component does not have.

Clamping just under the length would work and is the kind of epsilon that rots. The likely answer is for a finished Once timeline to hold its last pose explicitly, decided together with what a finished state does in the play API.

### Channels only one state covers

Defaults are taken once at bind and never move at runtime, on purpose. So a state that animates a subset of channels leaves every other channel at the bind-time pose: fading out of an upper-body state returns the arms to the pose the object had when it bound, not to what the incoming state wants. The Animation component behaves the same way, so this is the model, not a regression, but timelines make it more likely to show, since their tracks differ by design. Shapes worth weighing:

- Take a state's defaults when it starts rather than at bind, accepting some drift for a correct fade-out target.
- Let a layer declare the channels it owns, so channels it does not cover are left alone.
- A per-state choice between the two, which is what other engines ship and what users find hardest to reason about.

### Timeline instances are scene objects

N states on M animators are N×M parked subtrees, each walked every frame and each carrying real transforms and components. Accepted while the feature is unproven: the scene tree gives overrides, variants and per-instance bindings. The later optimization is a graph template built straight into the animator's arena, with no scene subtree, since the subtree only holds authoring data and its graph contribution is already built into the arena.

## Not planned

- A fully general playables API: per-node prepare and process lifecycles, runtime sub-graph surgery, video playables and DSP graphs ([Playable graph](concepts/PlayableGraph.md), "A small node set").
- State machines inside the graph, which would break the rule that evaluation keeps no memory.
- Transitions, conditions and parameters on the Animation component. A blend reads one value that gameplay sets.
- Replacing the timeline. A timeline that drives the Animation component sets `timeline_driven`, and the component's own playback stands down.
- Audio while scrubbing in the editor.
- Merging with tweens. The tween system is procedural, not clip-based, and stays separate ([Tweens](/plugins/tween/docs/Tweens.md)).
