---
title: "Timelines as states"
description: "Play two timelines as states of a TimelineAnimator, one posing a body and a sword together, and hand back from a one-shot"
weight: 20
tags: ["animation", "sequencer", "guides"]
---

This guide walks through the `timeline_sample`: a hero whose idle poses the body only and whose swing poses the body and a sword together, played as two states of a [TimelineAnimator](../components/TimelineAnimator.md). It needs the sequencer plugin. Open `timeline_animator_demo.scene` in the sample (`plugins/animation/samples/timeline_sample`) to see the result.

## 1. The objects the timelines drive

```
Hero
├── Body        Animation
│   ├── Torso
│   ├── Head
│   ├── ArmL
│   └── ArmR
└── Sword       Animation
    └── Blade
```

Every part is the built-in cube, so the scene needs no imported asset. Each object a timeline poses carries an Animation component, and the clips address the parts under it by name path, `ArmR` under `Body` for instance.

## 2. The timelines

Each timeline is an object with a PlayableDirector, and its tracks are the objects under it ([Sequencer](/plugins/sequencer/docs/Sequencer.md)):

```
idle            PlayableDirector
└── Body        TrackAnimation, target Body
swing           PlayableDirector
├── Body        TrackAnimation, target Body
└── Prop        TrackAnimation, target Sword
```

Each track's `target` is the only binding. The timelines play on their own the same way.

## 3. The animator

Put a TimelineAnimator on the scene's root and add the states in its States tree:

| State | Timeline | Wrap | Fade |
|---|---|---|---|
| Idle | idle | Loop | 0.35 |
| Swing | swing | Once | 0.15 |

Under each state the tree shows its timeline's tracks with their targets, so every object the hero depends on is edited in one place. Press a state's play button to preview it in edit mode.

## 4. The script

A script component next to the animator plays states by name. Passing no fade lets each state's own `fade` decide:

```odin
_tad_play :: proc(d: ^TimelineAnimatorDemo, name: string) {
	_, a := engine.transform_get_comp(d.owner, anim_seq.TimelineAnimator)
	if a == nil do return
	if id, ok := anim_seq.animator_find(a, name); ok do anim_seq.animator_play(a, id, d.fade) // fade -1: the state's own
}
```

There are no transitions. The script hands Swing back to Idle when it finishes:

```odin
cur, _, done := anim_seq.animator_state(a)
if cur != idle && done && !d.returning {
	d.returning = true          // start the fade once, not every frame
	anim_seq.animator_play(a, idle)
}
```

## 5. Play

Press Play. The hero idles, and the Swing button moves the arm and the sword together from one state, then returns to Idle.

Two things to notice:

- Swing drives two objects from one state: one weight and one fade move the arm and the sword together.
- Idle does not animate the sword, so returning to Idle leaves the sword to settle toward its default pose instead of holding the swing's end.

## See also

- [TimelineAnimator](../components/TimelineAnimator.md), every property and rule of the component.
- [Playback levels](../concepts/PlaybackLevels.md), how the animator, its timelines' tracks and the Animation components stack.
