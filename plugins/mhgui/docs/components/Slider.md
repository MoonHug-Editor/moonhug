---
title: "Slider"
description: "A control that sets a number between two ends by dragging a handle along a track"
weight: 24
tags: ["mhgui", "components", "slider"]
---

A control that sets a number between two ends. GameObject, UI, Slider creates a track with a fill and a handle.

## Example

```
Volume      RectTransform 200 x 10, CanvasRenderer, UiShape, Slider min_value 0, max_value 100, whole_numbers, fill Fill, handle Handle
├── Fill    RectTransform, CanvasRenderer, UiShape
└── Handle  RectTransform 22 x 22, CanvasRenderer, UiShape
```

The Slider's node is the track. The fill covers it from its start up to the value, and the handle sits at the value.

## Properties

| Field | Default | What it does |
|---|---|---|
| `interactable`, `transition`, `target_graphic`, `colors` | | What every control has, as on a [Button](Button.md). The menu makes the handle the target graphic. |
| `fill` | none | The node that covers the track from its start to the value. |
| `handle` | none | The node that sits at the value. |
| `direction` | Left_To_Right | Where the least value is: the left, the right, the bottom or the top. |
| `min_value`, `max_value` | 0, 1 | The ends. |
| `whole_numbers` | off | The value is a whole number. |
| `value` | 0 | The number. |

## Behavior

- A press on the track or the handle brings the value to the pointer, and the drag follows it. Past an end the value is the end.
- The Slider keeps the drag from its press: a scrolling list around it does not scroll while the handle is dragged.
- While it is selected, the keys and the gamepad's directions along its axis change the value: by 1 with `whole_numbers`, else by a tenth of the range. The keys across it move the selection on.
- The Slider places the fill and the handle by their anchors along the track. Along the track their place is not their own to set. Across it they keep what they were given, and the handle keeps its size.
- The fill and the handle follow `value` while the game runs.
- A press has to land on something the pointer can hit: the track's graphic or the handle. A thin track is a small target. Make the Slider's node taller and give it a HitArea, with the visible track as a thinner child.

## From code

```odin
if mhgui.slider_changed(s) do audio_set_volume(s.value / 100)  // true on the frame it changed
mhgui.slider_set(s, 40)                                        // kept between the ends, whole when the slider says so
n := mhgui.slider_normalized(s)                                // 0 to 1 between the ends
```

Poll `slider_changed` from an `@(update)` proc at order 0 or later, after the pointer pass at order -100.
