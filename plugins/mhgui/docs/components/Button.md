---
title: "Button"
description: "A clickable UI control: tints a graphic as the pointer hovers and presses it, and reports clicks for game code to poll"
weight: 20
tags: ["mhgui", "components"]
---

A clickable control. It tints a graphic as the pointer hovers and presses it, and reports a click for game code to poll. GameObject, UI, Button creates an Image with a Button.

## Properties

| Field | Default | What it does |
|---|---|---|
| `interactable` | on | Off, the button takes no input and shows the disabled colour. |
| `transition` | Color_Tint | Color_Tint tints the target graphic by state. None leaves it alone. |
| `target_graphic` | none | The object whose graphic takes the tint. None is this object. |
| `colors` | see below | The tint per state, a multiplier and a fade time. |

| Colour | Default |
|---|---|
| `normal` | white |
| `highlighted` | 0.96 grey |
| `pressed` | 0.78 grey |
| `selected` | 0.96 grey |
| `disabled` | 0.78 grey at half alpha |
| `color_multiplier` | 1 |
| `fade_duration` | 0.1 s |

## Behavior

- The state comes from the engine's pointer: hovered, pressed, selected by the last press, or disabled.
- The state's colour, times `color_multiplier`, multiplies the target graphic's own colour as a runtime tint on its CanvasRenderer, faded over `fade_duration`. The tint is never saved.
- `button_clicked` is true on the frame of a click. Poll it from an `@(update)` proc at order 0 or later, after the pointer pass at order -100.

## From code

```odin
import "moonhug:packages/mhgui"

@(update)
menu_update :: proc(dt: f32) {
	_, b := engine.transform_get_comp(play_row, mhgui.Button)
	if mhgui.button_clicked(b) do load_level()
}
```
