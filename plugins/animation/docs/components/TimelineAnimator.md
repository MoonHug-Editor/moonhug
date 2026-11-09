---
title: "TimelineAnimator"
description: "Plays whole timelines as states and cross-fades between them"
weight: 20
tags: ["animation", "sequencer", "components"]
---

Plays timelines as states. A state names a timeline, and playing it plays every track of that timeline: several animated objects, audio, activation and markers, as one performance that cross-fades against another state. Needs the sequencer plugin.

Use the [Animation](Animation.md) component when a state is one motion on one object. Use a TimelineAnimator when a state is a small performance across several objects.

## Example

The `timeline_sample`'s hero swings an arm and a sword from one state:

```
TimelineAnimatorDemo    TimelineAnimator
├── Hero
│   ├── Body            Animation      targeted by the Body tracks
│   └── Sword           Animation      targeted by the Prop track
├── idle                PlayableDirector: one animation track, target Body
└── swing               PlayableDirector: two animation tracks, targets Body and Sword
```

```
layers
└── Base
    ├── Idle    timeline idle,  wrap Loop, fade 0.35
    └── Swing   timeline swing, wrap Once, fade 0.15
```

```odin
if s, ok := animator_find(a, "Swing"); ok do animator_play(a, s) // fades over Swing's own 0.15 s
```

## Properties

| Field | Default | What it does |
|---|---|---|
| `speed` | 1 | Playback speed for every state. 0 runs at 1. |
| `layers` | none | The layers and their states, drawn by the States tree in the inspector. |

Each layer has a `name`, a `weight` and its `states`. Each state has:

| Field | What it does |
|---|---|
| `id` | Given when the state is added, never reused. A `State_Id` keeps naming the same state when others are added or removed. |
| `name` | What `animator_find` looks up. |
| `timeline` | The PlayableDirector the state plays, in the same file as the animator. |
| `speed` | Multiplies the animator's speed. 0 runs at 1. |
| `wrap` | Once plays to the end and stops there. Loop restarts. |
| `fade` | The cross-fade duration into this state when the caller passes none. |

## Behavior

- **Bindings stay on the tracks.** What a timeline drives is each track's own target, as when the timeline plays on its own. The animator adds no bindings. It only builds the tracks into its own graph, so several states can blend.
- **One graph, one write.** The animator owns one [playable graph](../concepts/PlayableGraph.md). Every state's tracks build into it, and only the animator writes the pose. Two timelines that each wrote their own pose at half weight would not blend: the second write would replace the first.
- **One output per object.** When the graph is built, the animator reads every state's animation tracks and makes one pose output per distinct object they target. Every output takes its default pose at that one moment.
- **One weight per state.** A cross-fade moves a state's weight, and that weight scales every track and clip of the state in every output.
- **Fades start from the current weights**, the same rule as the Animation component, so interrupting a fade never jumps.
- **Play starts at time 0.** `fade` -1 uses the state's own `fade`, 0 or less cuts.
- **Only states with weight play.** An animator with no state carrying weight writes nothing and releases its targets, so another driver can pose them.
- **The highest driver wins.** An Animation component plays on its own. A timeline track driving it overrides that. An animator driving the timeline overrides that. The directors its states name are parked: their tracks build into the animator's graph and do not play on their own.
- **Authoring problems are reported when the graph is built**, not fatal: `timeline_animator_problems` lists two animation tracks posing objects whose hierarchies overlap.

## In the editor

The inspector draws `layers` as the **States tree**:

```
States
├─ Layer 0  [name]                          [Add State]
│    Weight  ──●────
│    ├─ Idle                            [▶] [x]
│    │    Timeline  <picker of PlayableDirectors>
│    │    Speed / Wrap / Fade
│    │    tracks: Body track  target  <Animation picker>
│    └─ Swing ...
└─ [Add Layer] [Remove Layer]
```

- Under each state sit its timeline's tracks, one row each, showing the track's binding field: an animation track's `target`, an audio track's `source`. Every object the character depends on is read and edited in one place.
- Those rows edit the tracks' own fields. Undo lands on the track, a prefab override records against the track, and the Sequencer window shows the same value. The timeline still plays on its own unchanged.
- Each value row is one undo step and records prefab overrides, with the override marker and Revert and Apply in its context menu.
- Alt-click a layer to collapse or expand every state under it.
- The play button works in both modes. While the game runs it plays the state. In edit mode it starts a preview that poses the world for the render and puts it back after, so saves, undo and the inspector never see the pose. The preview advances exactly as the game does, with audio and marker crossings, and game scripts stay silent. Starting it ends the Animation window's clip preview.

## From code

```odin
animator_find(a, name) -> (State_Id, bool)
animator_play(a, s, fade = -1)                   // -1: the state's fade, <= 0: a cut
animator_stop(a)
animator_state(a, layer = 0) -> (s: State_Id, normalized: f32, done: bool)
animator_layer_weight(a, layer, w)
```

Find states by name once and keep the ids. A state's layer is known from its id, so `animator_play` takes none. The full list is in the [API reference](/docs/reference/packages/animation/sequencer.md).

## Limits

- No transitions, conditions or parameters. Switching is gameplay code: the sample polls `animator_state`'s `done` and hands Swing back to Idle.
- No blend trees. A timeline blends its own clips through its tracks' ease ramps.
- A Once state that reaches its end stops posing: its objects return toward their default pose unless gameplay plays another state. Hand back on `done`.
- When two states animate different objects, an object only the outgoing state animates returns toward its default pose, not to a pose of the incoming state.

## See also

- [Playback levels](../concepts/PlaybackLevels.md), how an Animation, a track and the animator stack, and why bindings stay on the tracks.
- [Timelines as states](../guides/TimelineStates.md), the sample step by step.
- [Roadmap](../Roadmap.md), for the open questions and known concerns.
