---
title: "Reading actions"
description: "Resolving action names once, and reading the frame's and the tick's values: down, pressed, released and axis values"
weight: 10
tags: ["input", "concepts"]
---

How game code reads actions. The code is `input_actions.odin`.

## Resolve once, read every frame

```odin
import "moonhug:packages/input_actions"

jump, move: input_actions.Action_Id

@(phase={key=EngineInit, order=100})
my_init :: proc() {
	jump = input_actions.action_id("Player", "Jump")
	move = input_actions.action_id("Player", "Move")
	input_actions.context_push("Player")
}

@(comp_fixed_update={component=Hero})
comp_fixed_update_Hero :: proc(dt: f32, h: ^Hero) {
	if input_actions.pressed_fixed(jump) do hero_jump(h)
	dir := input_actions.value2_fixed(move)
}
```

`action_id` panics on a name the asset lacks, so a typo stops the game at launch instead of reading nothing.

## Frame and tick values

- `down`, `pressed`, `released`, `value` and `value2` are the frame's values, resolved before every `@(update)`.
- The `_fixed` twins are the tick's values, resolved before every `@(fixed_update)` from the input library's fixed view, so a tap between two ticks still reads as one press.
- `pressed` and `released` are edges of the action's own down state. A Digital action is down while any of its mappings is. An axis is down while its value is not zero.
- An action's dead zone zeroes small values: an Axis1D below it in size, an Axis2D below it in length.
