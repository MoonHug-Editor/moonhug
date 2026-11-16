---
title: "Animation events"
description: "Named moments of a clip that playback crosses, and the components that act on them"
weight: 50
tags: ["animation", "events"]
---

An event is a named moment of a clip: a footstep, the frame a sword connects. When playback crosses it, the components of the playing object that take animation events get its name, and each decides what to do.

## In the clip

An event is a time and a name, in the clip's import settings (`events`), so a clip inside a model has them as a `.anim` does ([Animation clip](../assets/AnimationClip.md)). Each is one row in the Project Inspector: its time in seconds of the source clip, then its name. Apply bakes them into the clip.

- The trim moves them with the clip: an event inside the kept range keeps its place in the motion, one outside it is dropped.
- An event without a name is dropped.
- The clip names a moment and nothing else: no code, no component.

## In code

A component takes every event of the Animation on its object with one proc and checks the name:

```odin
import animation "moonhug:packages/animation"

@(comp_on_animation_event={component = Footsteps})
comp_on_animation_event_Footsteps :: proc(f: ^Footsteps, ev: animation.Animation_Event) {
	switch ev.name {
	case "footstep_l", "footstep_r":
		audio.play_clip_at_point(f.step, engine.transform_world_position(f.owner), ev.weight)
	}
}
```

- `component = T` names a component of the proc's package, and the proc is named `comp_on_animation_event_<T>`. A type has at most one. The build stops otherwise.
- The package's generated `animation_events_generated.odin` registers it. The package imports the animation plugin for `Animation_Event`, so taking events adds no dependency it does not have.

`Animation_Event` holds:

| Field | What it is |
|---|---|
| `name` | the event's name, valid during the call |
| `time` | where in the clip, in seconds |
| `clip` | the clip it comes from |
| `weight` | how much of the pose the clip gave, 0 to 1: the state's weight, times the child's in a blend |

## When it fires

- Each event the Animation's playback steps over fires once: an event at the time a step reaches fires, at the time it leaves it fired the step before. A state's first step also fires an event at its start.
- A looping clip fires each event once a cycle, several times in one frame if the frame covers several cycles. A clip played once fires up to its end, then stops. Played backwards, events fire in the order they are met.
- A cycle offset shifts where a loop starts, and its events with it.
- Clip states and each child of a blend fire. A blend's children all fire, each with its weight, so a proc can ignore a clip barely blended in. A clip fading in or out fires too, with its fading weight.
- The procs run after every Animation has ticked, in the order the events were crossed, so a proc may play, stop or destroy anything.
- Only while the game runs: scrubbing, previews and edit mode fire nothing.
- A clip a timeline plays fires nothing: timelines have their own instant events, a script clip of zero length.
