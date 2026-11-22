---
title: "Toggle"
description: "A control that is on or off, with a check mark, and ToggleGroup, which keeps one toggle of a set on"
weight: 22
tags: ["mhgui", "components", "toggle", "checkbox", "radio"]
---

A control that is on or off. A click flips it. GameObject, UI, Toggle creates a box with a check mark.

## Example

```
Options        RectTransform, ToggleGroup
├── Easy       RectTransform, CanvasRenderer, UiShape, Toggle is_on, graphic Checkmark, group Options
│   └── Checkmark  RectTransform, CanvasRenderer, UiShape
├── Normal     ... Toggle graphic Checkmark, group Options
└── Hard       ... Toggle graphic Checkmark, group Options
```

One of the three is on. A click on another turns it on and the one that was on off.

## Properties

| Field | Default | What it does |
|---|---|---|
| `interactable`, `transition`, `target_graphic`, `colors`, `sprites`, `navigation` | | What every control has, as on a [Button](Button.md). |
| `is_on` | off | Whether it is on. |
| `graphic` | none | The node that shows only while the toggle is on: the check mark. |
| `group` | none | The node with the ToggleGroup this toggle belongs to. None stands alone. |

## Behavior

- A click flips it, and so do Enter, Space and the gamepad's bottom face button while it is selected.
- The check mark's CanvasRenderer is on while the toggle is on, and off while it is off. This follows `is_on` while the game runs.
- The click may land on the check mark or any other graphic under the toggle's node: it is the toggle's.
- A parent that takes the drag, a scrolling list, cancels the press: nothing flips.

## ToggleGroup

A component with one field, on any node. The toggles that name it are a set.

| Field | Default | What it does |
|---|---|---|
| `allow_switch_off` | off | A click on the toggle that is on turns it off, leaving none on. Off, one stays on. |

- Turning a toggle on turns the others of its group off.
- With `allow_switch_off` off, the toggle that is on cannot be turned off by a click: another has to be turned on.
- The group does not turn one on by itself: author one toggle of the set with `is_on`.

## From code

```odin
if mhgui.toggle_changed(t) do apply(t.is_on)  // true on the frame it flipped
mhgui.toggle_set(t, true)                     // as a click does, the group's rule included
```

Poll `toggle_changed` from an `@(update)` proc at order 0 or later, after the pointer pass at order -100.
