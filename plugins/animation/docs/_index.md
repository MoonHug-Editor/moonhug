---
title: "animation"
description: "Clip-based animation: the Animation component, animation clips, the Animation window and timeline states"
tags: ["animation", "plugin"]
---

The animation plugin plays keyframed clips on a transform hierarchy. A clip animates transforms and component fields, the Animation component plays clips and 1D blends of clips through a playable graph, and the Animation window edits clips with a dope sheet, curves and recording.

## What it adds

**Components**

- [Animation](components/Animation.md) plays clips and blends on the object it sits on and the objects under it.
- [TimelineAnimator](components/TimelineAnimator.md) plays whole timelines as states and cross-fades between them. Needs the sequencer plugin.
- [TrackAnimation](components/TrackAnimation.md) and [ClipAnimation](components/ClipAnimation.md) put clips on a timeline. Need the sequencer plugin.

**Assets**

- [Animation clip](assets/AnimationClip.md): a `.anim` file, or a clip inside a glTF model, with its import settings.

**Windows**

- [Animation](windows/AnimationWindow.md): the clip editor, a dope sheet and a curve view with recording.
- [Playable Graph](windows/PlayableGraphWindow.md): a read-only view of the graph that poses the selected object.

**Guides**

- [Animating a character](guides/AnimatingACharacter.md)
- [Timelines as states](guides/TimelineStates.md)

**Concepts**

- [Playable graph](concepts/PlayableGraph.md): how poses are sampled, blended and written.
- [Clip format](concepts/ClipFormat.md): what a clip stores and how its keys interpolate.
- [Animation states](concepts/States.md): how the Animation component stores and plays its states.
- [Playback levels](concepts/PlaybackLevels.md): how an Animation, a timeline track and a TimelineAnimator stack.

[Roadmap](Roadmap.md): what comes next, open questions, known concerns and what is not planned.

## What it needs

- The engine plugin.
- Optional, the sequencer plugin. It adds TrackAnimation and ClipAnimation, which put clips on a timeline, and the TimelineAnimator, which plays timelines as states. The Playable Graph window then also shows a director's animation tracks and an animator's graph. These parts live in the plugin's `sequencer` subpackage, which builds only when the sequencer plugin is enabled ([Plugins](/docs/core/Plugins.md)). Without it the rest of the plugin works the same.

## Quick start

1. Select the root of a model that has animations, or any object.
2. Add Component, Animation/Animation.
3. Pick a clip in the `clip` field: a `.anim` file, or a clip inside a model (it shows as `Model / Clip`).
4. Press Play. `play_automatically` is on, so the clip plays from the first frame.

To make a clip of your own: Assets, Create, Animation makes a `.anim` file. Put it in the component's `clip` field, open Window, Animation, Animation, arm Record and edit the object.

## Limits

- No state machine: no transitions, conditions or parameters. What plays next is gameplay code calling the API.
- No 2D blends and no nested blends.
- No root motion, mirroring, additive layers or avatar masks.

## Extending

The plugin declares no attributes. Code extends it through the graph:

- **Your own driver.** Build clip, mixer and layer mixer nodes, add an output bound to an object, and tick the graph. The Animation component, the TimelineAnimator and the editor preview are drivers built this way ([Playable graph](concepts/PlayableGraph.md), "The graph evaluates, drivers decide").
- **Script nodes.** A `Playable_Script` node calls your procs with its time and weight after every output has written ([Playable graph](concepts/PlayableGraph.md), "Script nodes").
- **Graph providers.** A driver that owns a graph registers a provider with `playable_graph_register_provider(order, proc)`, and the Playable Graph window shows that graph for the objects the driver poses ([Playable graph](concepts/PlayableGraph.md), "Who owns a graph").
- **Animatable fields.** A field of your own component is animatable with no registration when its type is one of the animatable kinds ([Playable graph](concepts/PlayableGraph.md), "Component fields").

## Reference

- [API reference](/docs/reference/packages/animation/animation.md) of the `animation` package, and of its [sequencer integration](/docs/reference/packages/animation/sequencer.md).
- Samples: `animation_sample` ([Animating a character](guides/AnimatingACharacter.md)) and `timeline_sample` ([Timelines as states](guides/TimelineStates.md)).
