---
title: "Animation transition"
description: "A Button, Toggle or Slider with the Animation transition plays the Animation state named after its state"
weight: 10
tags: ["mhgui", "animation", "concepts"]
---

A control whose `transition` is Animation shows its state with the animation plugin's Animation component. The code is the plugin's `animation` subpackage, which builds only with the animation plugin installed.

## Setting it up

1. Put an Animation component on the control's object, or on its `target_graphic`.
2. Give it states named after the control's states: `Normal`, `Highlighted`, `Pressed`, `Selected`, `Disabled`. A clip in each: a scale up on Highlighted, a squash on Pressed.
3. Set the control's `transition` to Animation.

## Behavior

- When the control's state changes, the Animation plays the state of that name from its start, cross-fading from the one before over the control's `fade_duration`.
- A state the Animation has no entry for plays nothing: the Animation keeps what it was playing.
- The same state is not played again while it lasts, so a looping state loops and a one-shot plays once.
- It runs after the pointer pass of the frame, before the game's updates.
