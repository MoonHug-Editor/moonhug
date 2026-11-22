---
title: "Button"
description: "A clickable UI control: tints a graphic as the pointer hovers and presses it, takes keyboard and gamepad input while selected, and reports clicks for game code to poll"
weight: 20
tags: ["mhgui", "components"]
---

A clickable control. It tints a graphic as the pointer hovers and presses it, and reports a click for game code to poll. GameObject, UI, Button creates an Image with a Button.

## Example

```
Canvas             Canvas, GraphicRaycaster
└── Play           RectTransform size_delta 160, 30, CanvasRenderer, Image, Button transition Color_Tint
    └── Label      RectTransform, CanvasRenderer, Text text "Play"
```

The button tints its Image as the pointer hovers and presses it. Game code polls `button_clicked` each frame, as in From code below.

## Properties

The first four fields are the ones every control has. Button, Toggle and Slider share them and what they do: the colour transition, the hover and the press, and being selected by keyboard and gamepad. In a scene file they are saved under `selectable`.

| Field | Default | What it does |
|---|---|---|
| `interactable` | on | Off, the button takes no input and shows the disabled colour. |
| `transition` | Color_Tint | How the control shows its state, below. |
| `target_graphic` | none | The object whose graphic the transition changes. None is this object. |
| `colors` | see below | Color_Tint: the tint per state, a multiplier and a fade time. |
| `sprites` | none | Sprite_Swap: the sprite per state. |
| `navigation` | Automatic | Where the direction keys take the selection from this control, below. |

| Transition | What it does |
|---|---|
| None | Nothing. |
| Color_Tint | Tints the target graphic with the state's colour, fading over `fade_duration`. |
| Sprite_Swap | The target Image shows the state's sprite: Highlighted, Pressed, Selected or Disabled. Normal, and a state with no sprite, show the Image's own. |
| Animation | The Animation component on the target object plays the state of the same name. With the animation plugin installed ([Animation transition](../extends/animation/concepts/AnimationTransition.md)). |

| Navigation `mode` | What the direction keys do on this control |
|---|---|
| Automatic | Select the nearest usable control in that direction. |
| Explicit | Select the control named for that direction: `up`, `down`, `left` or `right`. A direction with none named, or one whose control is disabled, hidden or not interactable, keeps the selection here. |
| None | Nothing: the selection stays here. Automatic moves from other controls pass over this one. The pointer still selects it. |

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

- The button takes its node's [pointer events](../concepts/Pointer.md) like any other component: it uses the left button's press, so it owns it, and the hover, the press and the click come from the events. A press selects the button, and so does `engine.ui_set_selected`.
- The pointer hits the button through a graphic on its node or on a node under it (an Image, a UiShape, a Text with `raycast_target` on), or through a HitArea. A press and a release on different parts of one button still click it.
- A parent that takes the drag, such as a scrolling list, cancels the press: no click follows.
- A press dragged off the button looks let go, and a release there does not click. Dragged back over it, the button is pressed again and a release clicks.
- The state's colour, times `color_multiplier`, multiplies the target graphic's own colour as a runtime tint on its CanvasRenderer, faded over `fade_duration`. The tint is never saved.
- Enter, Space and the gamepad's bottom face button click the selected button.
- The arrow keys, the d-pad and the left stick move the selection to the nearest button in that direction that is enabled and interactable. Near and straight ahead wins over far or off to the side. Buttons on overlay canvases are compared on the screen, so the selection crosses from one overlay canvas to another. A canvas in the world or before a camera keeps the selection inside it.
- A control's `navigation` replaces that for the moves that start on it. Explicit makes a fixed order: a ring that wraps from the last button to the first, a grid that skips a decoration, a move to a control on another canvas. A control named by an Explicit neighbour is reached whatever its own mode is.
- A control that reads the keyboard itself takes these keys while it is the selected node (`ui_keys_capture`): an [InputField](/plugins/text/docs/components/InputField.md) does while it is edited.
- With nothing selected the keys do nothing. A menu selects its first button when it opens, as in From code below.
- `ui_set_navigation(false)` turns keyboard and gamepad input off, for a game that uses those keys while buttons are on screen.
- `button_clicked` is true on the frame of a click. Poll it from an `@(update)` proc at order 0 or later, after the pointer pass at order -100.

## From code

```odin
import "moonhug:packages/mhgui"

@(update)
menu_update :: proc(dt: f32) {
	_, b := engine.transform_get_comp(play_row, mhgui.Button)
	if mhgui.button_clicked(b) do load_level()
}

// When the menu opens: the keyboard and the gamepad start from Play.
mhgui.ui_set_selected(play_row)

// While the game plays with the HUD's buttons on screen.
mhgui.ui_set_navigation(false)
```
