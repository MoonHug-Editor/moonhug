---
title: "Animating a character"
description: "Play a model's clips as states, blend walk into run, and drive the states from gameplay code"
weight: 10
tags: ["animation", "guides"]
---

This guide builds what the `animation_sample` ships: an imported character with a locomotion blend and three single clips, played from a script. Open `animation_demo.scene` in the sample (`plugins/animation/samples/animation_sample`) to see the result.

## 1. Bring in the character

Import a glTF model that has animations, such as the essentials plugin's `meshes/characters/UAL1_Standard.glb`. In the Project window the model expands to its parts and its clips. The clips play from the model as they are, with nothing to extract.

Drag the model into the scene.

## 2. Add the Animation component

Select the model's root and Add Component, Animation/Animation. Leave `clip` empty: the states below are what plays. Turn `play_automatically` off, since the script decides what plays.

## 3. Add the states

In the component's States tree:

1. Add, Blend1D. Name it `Locomotion`.
2. On the blend, `+ Clip` twice. Pick the walk clip in the first and set its position to 0, and the run clip in the second with position 1.
3. Add, Clip three times: `Idle`, `Jump` and `Death`, each with its clip.
4. Set the wraps. The model's clips import as Once, so set Locomotion and Idle to Loop, and leave Jump and Death at Once.

## 4. Try it in edit mode

- Press a state's play button. The character plays the state in the Scene window without the game running.
- Play Locomotion and drag its value: the character moves from walking to running, with the footfalls kept together.

## 5. Drive it from code

A script component next to the Animation plays states by name and feeds the blend:

```odin
@(component={menu="Demo/AnimationDemo"})
AnimationDemo :: struct {
	using base: engine.CompData `inspect:"-"`,
	fade:  f32,                       // cross-fade seconds, 0 cuts
	blend: f32 `decor:range(0, 1)`,   // walk at 0, run at 1
}

_ad_play :: proc(d: ^AnimationDemo, name: string) {
	_, a := engine.transform_get_comp(d.owner, anim.Animation)
	if a == nil do return
	if id, ok := anim.animation_find(a, name); ok do anim.animation_play_entry(a, id, d.fade)
}
```

The sample also writes `blend` into the Locomotion state with `animation_blend_set` whenever it changes, the way a character controller feeds its speed. It writes only on change because the blend's value is the same field the States tree's slider edits.

## 6. Play

Press Play and use the sample's inspector buttons, Idle, Locomotion, Jump, Death and Stop. Each call cross-fades over `fade` seconds. Death stays on its last pose, since it plays Once.

## See also

- [Animation](../components/Animation.md), every property and rule of the component.
- [Animation clip](../assets/AnimationClip.md), "Clips inside a model".
